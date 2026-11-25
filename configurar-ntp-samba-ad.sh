#!/usr/bin/env bash
# Configura Chrony e GPO-NTP em um controlador de domínio Samba AD no Debian.
set +x
set -Eeuo pipefail
export LC_ALL=C
umask 077

die() { printf 'Erro: %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || die 'Execute como root no controlador de domínio.'
[[ -r /etc/os-release ]] || die 'Sistema operacional não identificado.'
. /etc/os-release
[[ ${ID:-} == debian ]] || die 'Este script foi preparado para Debian.'
for cmd in samba-tool testparm python3 flock; do
    command -v "$cmd" >/dev/null || die "Comando ausente: $cmd."
done
samba-tool gpo load --help >/dev/null 2>&1 ||
    die 'Este Samba não oferece gpo load. Use Samba 4.23 ou superior com esse comando disponível.'

exec 9>/run/lock/configurar-ntp-samba-ad.lock
flock -n 9 || die 'Já existe outra execução neste servidor.'
exec 3<>/dev/tty || die 'Abra uma sessão interativa no console ou por SSH.'

workdir=$(mktemp -d /run/configurar-ntp-samba-ad.XXXXXXXX)
trap 'rm -rf -- "$workdir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "Falha na linha %s. Confira a mensagem acima e execute novamente após corrigir.\n" "$LINENO" >&2' ERR

role=$(testparm -s --parameter-name='server role' 2>/dev/null)
[[ ${role,,} == 'active directory domain controller' ]] ||
    die 'O Samba deste servidor não está no papel de controlador de domínio AD.'
realm=$(testparm -s --parameter-name=realm 2>/dev/null)
netbios=$(testparm -s --parameter-name='netbios name' 2>/dev/null)
socket_dir=$(testparm -s --parameter-name='ntp signd socket directory' 2>/dev/null)
[[ -n $realm && -n $netbios ]] || die 'Não foi possível descobrir o domínio ou o nome do DC.'
[[ $socket_dir == /* && $socket_dir != *[[:space:]]* && -S $socket_dir/socket ]] ||
    die "Socket NTP assinado indisponível: $socket_dir/socket. Confira se o Samba AD está ativo."

dc="${netbios,,}.${realm,,}"
domain_dn=$(awk -F. '{for(i=1;i<=NF;i++) printf "%sDC=%s", (i==1?"":","), $i}' <<< "${realm,,}")
gpo_name=GPO-NTP

printf 'DC: %s | Raiz do domínio: %s\n' "$dc" "$domain_dn" >&3
printf 'Redes das estações em CIDR, separadas por espaço ou vírgula: ' >&3
IFS= read -r subnet_input <&3 || die 'Leitura das redes interrompida.'
subnets=$(python3 - "$subnet_input" <<'PY'
import ipaddress
import sys

try:
    networks = dict.fromkeys(ipaddress.ip_network(cidr)
                             for cidr in sys.argv[1].replace(",", " ").split())
    if not networks or any(net.prefixlen == 0 for net in networks):
        raise ValueError("informe redes específicas, como 192.168.10.0/24, sem usar /0")
except ValueError as exc:
    sys.exit(f"Redes inválidas: {exc}")

print(*networks, sep="\n")
PY
)
printf 'Usuário administrador do AD [Administrator]: ' >&3
IFS= read -r ad_user <&3 || die 'Leitura do usuário interrompida.'
ad_user=${ad_user:-Administrator}
[[ $ad_user == *@* ]] || ad_user="$ad_user@${realm^^}"

packages=()
command -v chronyd >/dev/null || packages+=(chrony)
command -v kinit >/dev/null || packages+=(krb5-user)
if (( ${#packages[@]} )); then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
fi

# Use o KDC local e mantenha o ticket em um cache temporário privado.
cat > "$workdir/krb5.conf" <<KRB
[libdefaults]
    default_realm = ${realm^^}
    dns_lookup_kdc = false
[realms]
    ${realm^^} = {
        kdc = $dc
    }
KRB
export KRB5_CONFIG="$workdir/krb5.conf"
ccache="FILE:$workdir/krb5cc"
printf 'Informe a senha do administrador do AD quando solicitado.\n' >&3
kinit -c "$ccache" "$ad_user" <&3 >&3 || die 'Falha na autenticação Kerberos.'
samba_gpo() {
    samba-tool gpo "$@" -H "ldap://$dc" --use-krb5-ccache="$ccache" <&3
}

# Descobre GPO existente antes de alterar o Chrony.
gpos=$(samba_gpo listall)
gpo_guid=$(awk -v wanted="$gpo_name" '
    /^GPO[[:space:]]*:/ { guid=$NF }
    /^display name[[:space:]]*:/ {
        sub(/^[^:]*:[[:space:]]*/, "")
        if (tolower($0)==tolower(wanted)) print guid
    }' <<< "$gpos")
guid_pattern='^\{[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}\}$'
[[ -z $gpo_guid || $gpo_guid =~ $guid_pattern ]] ||
    die 'Há mais de uma GPO com esse nome ou o GUID retornado é inválido.'

chrony_config=/etc/chrony/chrony.conf
chrony_fragment=/etc/chrony/conf.d/samba-ad.conf
[[ -d /etc/chrony/conf.d && -f $chrony_config ]] ||
    die 'Estrutura de configuração padrão do Chrony não encontrada.'
[[ ! -L $chrony_fragment ]] || die "$chrony_fragment é um link simbólico."

{
    printf 'ntpsigndsocket %s\n' "$socket_dir"
    while IFS= read -r subnet; do
        printf 'allow %s\n' "$subnet"
    done <<< "$subnets"
} > "$workdir/chrony.conf"

chrony_changed=0
if ! cmp -s "$workdir/chrony.conf" "$chrony_fragment"; then
    if [[ -f $chrony_fragment ]]; then
        cp -p -- "$chrony_fragment" "$workdir/chrony-anterior.conf"
    fi
    install -m 0644 "$workdir/chrony.conf" "$chrony_fragment"
    chrony_changed=1
fi
restore_chrony_fragment() {
    if (( chrony_changed )); then
        if [[ -f $workdir/chrony-anterior.conf ]]; then
            cp -p -- "$workdir/chrony-anterior.conf" "$chrony_fragment"
        else
            rm -f -- "$chrony_fragment"
        fi
    fi
}
if ! chronyd -p -f "$chrony_config" > "$workdir/chrony-efetivo.conf" ||
   ! grep -Fxq "ntpsigndsocket $socket_dir" "$workdir/chrony-efetivo.conf" ||
   grep -Eq '^port[[:space:]]+0([[:space:]]|$)' "$workdir/chrony-efetivo.conf"; then
    restore_chrony_fragment
    die 'Configuração do Chrony inválida, fragmento não carregado ou porta NTP desativada.'
fi
while IFS= read -r subnet; do
    if ! grep -Fxq "allow $subnet" "$workdir/chrony-efetivo.conf"; then
        restore_chrony_fragment
        die "A rede $subnet não entrou na configuração do Chrony."
    fi
done <<< "$subnets"

chown root:_chrony "$socket_dir"
chmod 750 "$socket_dir"
systemctl enable chrony.service
if (( chrony_changed )); then
    if ! systemctl restart chrony.service; then
        restore_chrony_fragment
        systemctl restart chrony.service || true
        die 'Falha ao reiniciar o Chrony. A configuração anterior foi restaurada.'
    fi
else
    systemctl start chrony.service
fi
printf 'Aguardando a sincronização do Chrony (até cerca de 60 segundos).\n'
chronyc waitsync 12 0 0 5 ||
    die 'O Chrony ainda não sincronizou. Confira chronyc sources -v antes de repetir.'

if [[ -z $gpo_guid ]]; then
    created=$(samba_gpo create "$gpo_name" --tmpdir "$workdir")
    printf '%s\n' "$created"
    gpo_guid=$(awk '/^GPO .* created as / {print $NF}' <<< "$created")
    [[ $gpo_guid =~ $guid_pattern ]] || die 'GPO criada, mas o GUID retornado não foi reconhecido.'
fi

cat > "$workdir/gpo.json" <<'JSON'
[
  {"keyname":"Software\\Policies\\Microsoft\\W32Time\\TimeProviders\\NtpClient","valuename":"Enabled","class":"MACHINE","type":"REG_DWORD","data":1},
  {"keyname":"Software\\Policies\\Microsoft\\W32Time\\Parameters","valuename":"Type","class":"MACHINE","type":"REG_SZ","data":"NT5DS"}
]
JSON
samba_gpo load "$gpo_guid" --content "$workdir/gpo.json"
policy=$(samba_gpo show "$gpo_guid")
python3 - "$workdir/gpo.json" "$policy" <<'PYVERIFY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    expected = json.load(source)
settings = json.loads(sys.argv[2].split("Policies :", 1)[1].strip())
for item in expected:
    if not any(setting["class"] == item["class"]
               and setting["keyname"].lower() == item["keyname"].lower()
               and setting["valuename"].lower() == item["valuename"].lower()
               and setting["type"] == item["type"]
               and setting["data"] == item["data"] for setting in settings):
        sys.exit(f"Valor não confirmado na GPO: {item['valuename']}")
PYVERIFY

links=$(samba_gpo getlink "$domain_dn")
link_options=$(awk -v guid="$gpo_guid" '
    $1=="GPO" && $2==":" {matched=(tolower($3)==tolower(guid))}
    matched && $1=="Options" {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' <<< "$links")
if [[ ${link_options^^} == *DISABL* ]]; then
    die 'O vínculo na raiz existe, mas está desabilitado. Habilite-o no Gerenciamento de Política de Grupo.'
elif [[ -z $link_options ]]; then
    samba_gpo setlink "$domain_dn" "$gpo_guid"
fi
printf '\nVínculos na raiz do domínio:\n'
samba_gpo getlink "$domain_dn"
printf '\nChrony sincronizado e %s processada (%s).\n' "$gpo_name" "$gpo_guid"
printf 'Em uma estação Windows: gpupdate /target:computer /force, w32tm /resync /rediscover e w32tm /query /source.\n'
