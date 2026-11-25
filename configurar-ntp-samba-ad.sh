#!/usr/bin/env bash
# Configura Chrony e GPO-NTP em um controlador de domínio Samba AD no Debian.
set +x
set -Eeuo pipefail
export LC_ALL=C
umask 077

die() { printf 'Erro: %s\n' "$*" >&2; exit 1; }

# A atualização de versão é opt-in. O modo sem argumentos configura apenas o NTP.
atualizar_sistema() {
    local modo=$1 estado=/var/lib/samba-ntp-atualizacao
    local servico=samba-ntp-atualizacao.service
    local unidade=/etc/systemd/system/$servico
    local versao=${VERSION_CODENAME:-} proxima fase destino boot_anterior boot_atual
    local arquivo ad realm dc papel redes auditoria plano
    local -a fontes apt_opcoes componentes

    [[ -d /run/systemd/system ]] || die 'A atualização requer Debian com systemd.'
    [[ $(dpkg --print-architecture) == amd64 ]] || die 'Migração testável somente em Debian amd64.'
    [[ $versao == bullseye || $versao == bookworm || $versao == trixie ]] ||
        die "Release Debian fora da sequência prevista: $versao."
    [[ $(systemd-detect-virt --container) == none ]] ||
        die 'A atualização com reinicialização requer uma VM ou servidor físico.'
    papel=$(testparm -s --parameter-name='server role' 2>/dev/null)
    [[ ${papel,,} == 'active directory domain controller' ]] ||
        die 'Este servidor não é um controlador de domínio Samba.'
    [[ $(command -v samba-tool) == /usr/bin/samba-tool &&
       $(dpkg-query -W -f='${Status}' samba 2>/dev/null) == 'install ok installed' ]] ||
        die 'A atualização requer Samba instalado pelos pacotes Debian.'
    systemctl is-active --quiet samba-ad-dc.service ||
        die 'O serviço samba-ad-dc precisa estar ativo antes de avançar.'
    auditoria=$(dpkg --audit)
    [[ -z $auditoria ]] || die "Há pendências no dpkg: $auditoria"
    [[ -z $(apt-mark showhold) ]] || die 'Há pacotes retidos. Revise apt-mark showhold antes de executar.'
    [[ -z $(find /etc/apt/preferences.d -maxdepth 1 -type f -print -quit) &&
       ! -s /etc/apt/preferences ]] || die 'Há pinning no APT. Revise as prioridades antes de migrar.'

    exec 8>/run/lock/samba-ntp-atualizacao.lock
    if [[ $modo == --retomar ]]; then
        flock -w 30 8 || die 'Outra execução não liberou o bloqueio da atualização.'
    else
        flock -n 8 || die 'Já existe uma atualização em andamento.'
    fi
    export DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a
    apt_opcoes=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
    boot_atual=$(</proc/sys/kernel/random/boot_id)
    printf 'Debian %s (%s). ' "$VERSION_ID" "$versao"
    /usr/sbin/samba --version

    if [[ $modo == --atualizar ]]; then
        [[ ! -e $estado/fase && ! -e $unidade ]] ||
            die "Já existe uma execução registrada. Consulte journalctl -u $servico."
        [[ -f ${BASH_SOURCE[0]} ]] || die 'Baixe o arquivo antes de executar. O script é copiado para retomar após o reboot.'
        exec 4<>/dev/tty || die 'Abra uma sessão interativa para informar as redes e a credencial do AD.'

        # Identifica fontes de terceiros antes de alterar pacotes ou arquivos.
        shopt -s nullglob
        fontes=(/etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources)
        shopt -u nullglob
        for arquivo in "${fontes[@]}"; do
            [[ -e $arquivo ]] || continue
            [[ ! -L $arquivo ]] || die "Fonte APT por link simbólico: $arquivo."
            if [[ $arquivo == *.sources ]]; then
                [[ $versao == trixie ]] || die "Revise a fonte Deb822 antes da migração: $arquivo."
                awk -v suite="$versao" '
                    /^URIs:/ {for(i=2;i<=NF;i++) if($i !~ /^https?:\/\/(deb\.debian\.org|security\.debian\.org)\/debian(-security)?\/?$/) exit 1}
                    /^Suites:/ {for(i=2;i<=NF;i++) if($i !~ ("^" suite "(-updates|-security|-backports)?$")) exit 1}
                    /^[[:space:]]/ && !/^[[:space:]]*$/ {exit 1}
                ' "$arquivo" || die "Fonte APT fora dos repositórios Debian previstos: $arquivo."
            else
                validar_fonte_apt "$arquivo" "$versao"
            fi
        done
        printf 'Redes das estações em CIDR, separadas por espaço ou vírgula: ' >&4
        IFS= read -r redes <&4 || die 'Leitura das redes interrompida.'
        validar_redes "$redes" >/dev/null
        printf 'Usuário administrador do AD [Administrator]: ' >&4
        IFS= read -r ad <&4 || die 'Leitura do usuário interrompida.'
        realm=$(testparm -s --parameter-name=realm 2>/dev/null)
        dc=$(testparm -s --parameter-name='netbios name' 2>/dev/null)
        [[ -n $dc && -n $realm ]] || die 'Não foi possível identificar o domínio do AD.'
        dc="${dc,,}.${realm,,}"
        ad=${ad:-Administrator}
        [[ $ad == *@* ]] || ad="$ad@${realm^^}"

        install -d -m 0700 "$estado" "$estado/backup"
        [[ -f /usr/share/keyrings/debian-archive-keyring.gpg ]] || die 'Chaveiro oficial Debian indisponível.'
        # Usa o arquivo oficial para buscar kinit no Bullseye sem depender dos .deb removidos do CDN.
        if ! command -v kinit >/dev/null; then
            if [[ $versao == bullseye ]]; then
                printf '%s\n' 'deb https://archive.debian.org/debian bullseye main' \
                    'deb https://archive.debian.org/debian-security bullseye-security main' > "$estado/bullseye.list"
                local -a fonte_bullseye=(-o "Dir::Etc::SourceList=$estado/bullseye.list" -o Dir::Etc::SourceParts=- -o APT::Get::List-Cleanup=false)
                apt-get "${fonte_bullseye[@]}" update
                apt-get "${fonte_bullseye[@]}" "${apt_opcoes[@]}" install krb5-user
            else
                apt-get -o APT::Update::Error-Mode=any update
                apt-get "${apt_opcoes[@]}" install krb5-user
            fi
        fi
        cat > "$estado/krb5.conf" <<KRB
[libdefaults]
    default_realm = ${realm^^}
    dns_lookup_kdc = false
[realms]
    ${realm^^} = {
        kdc = $dc
    }
KRB
        trap "rm -f -- '$estado/krb5cc'" EXIT
        KRB5_CONFIG="$estado/krb5.conf" kinit -c "FILE:$estado/krb5cc" "$ad" <&4 >&4 ||
            die 'Falha no login Kerberos. Nenhuma migração foi iniciada.'
        verificar_ad
        samba-tool domain backup offline --targetdir="$estado/backup"
        compgen -G "$estado/backup/samba-backup-*.tar*" >/dev/null ||
            die 'O arquivo de backup do domínio não foi encontrado. Migração cancelada.'
        cp -a /etc/apt/sources.list.d "$estado/backup/"
        [[ ! -f /etc/apt/sources.list ]] || cp -a /etc/apt/sources.list "$estado/backup/"
        printf '%s\n' "$redes" > "$estado/redes"
        install -m 0700 "${BASH_SOURCE[0]}" "$estado/configurar.sh"
        gravar_fase "$estado" "pronto:$versao:"
        cat > "$unidade" <<UNIT
[Unit]
Description=Atualizar Debian e Samba AD e configurar horário do domínio
After=network-online.target samba-ad-dc.service
Wants=network-online.target
ConditionPathExists=$estado/fase

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=/bin/bash $estado/configurar.sh --retomar

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable "$servico"
        systemctl start --no-block "$servico"
        trap - EXIT
        printf '%s\n' "Atualização iniciada. Acompanhe com journalctl -fu $servico." \
            "Backup do AD e do APT em $estado/backup. O servidor reiniciará entre versões."
        return
    fi

    [[ -f $estado/fase && -f $unidade ]] || die 'Não há uma atualização registrada.'
    IFS=: read -r fase destino boot_anterior < "$estado/fase"
    case "$fase" in
        apos-reboot)
            [[ $boot_atual != "$boot_anterior" && $destino == "$versao" ]] ||
                die 'O reboot ou a mudança de release ainda não foi confirmada.'
            ;;
        pronto) [[ $destino == "$versao" ]] || die 'O Debian mudou desde o agendamento.' ;;
        *) die "A execução anterior parou na etapa $fase ($destino). Revise o journal antes de retomar." ;;
    esac
    trap "rm -f -- '$estado/krb5cc'" EXIT

    if [[ $versao == trixie ]]; then
        gravar_fase "$estado" "em-andamento:trixie-backports:$boot_atual"
        local backports_existente=0
        shopt -s nullglob
        fontes=(/etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources)
        shopt -u nullglob
        for arquivo in "${fontes[@]}"; do
            [[ -f $arquivo ]] || continue
            if awk 'BEGIN {RS=""; FS="\n"}
                /(^|[[:space:]])trixie-backports([[:space:]]|$)/ &&
                !/(^|\n)[Ee]nabled:[[:space:]]*[Nn][Oo]([[:space:]]|$)/ {
                    for (i=1;i<=NF;i++) if ($i ~ /^(deb |Suites:).*trixie-backports([[:space:]]|$)/) found=1
                }
                END {exit !found}
            ' "$arquivo"; then
                backports_existente=1
                break
            fi
        done
        if (( ! backports_existente )); then
            printf '%s\n' 'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian trixie-backports main' \
                > /etc/apt/sources.list.d/samba-ntp-backports.list
        fi
        apt-get -o APT::Update::Error-Mode=any update
        plano=$(apt-get -s dist-upgrade)
        validar_plano "$plano"
        apt-get "${apt_opcoes[@]}" dist-upgrade
        apt-cache -t trixie-backports policy samba
        plano=$(apt-get -s -t trixie-backports install samba samba-ad-dc)
        validar_plano "$plano"
        apt-get "${apt_opcoes[@]}" -t trixie-backports install samba samba-ad-dc
        verificar_ad
        samba-tool gpo load --help >/dev/null 2>&1 || die 'O Samba instalado ainda não oferece gpo load.'
        if [[ -f /run/reboot-required ]]; then
            gravar_fase "$estado" "apos-reboot:trixie:$boot_atual"
            trap - EXIT
            if ! systemctl --no-block reboot; then
                rm -f -- "$estado/krb5cc"
                die 'O reboot não pôde ser agendado.'
            fi
            return
        fi
        /bin/bash "$estado/configurar.sh" --pos-atualizacao
        systemctl disable "$servico"
        rm -f -- "$unidade" "$estado/fase" "$estado/redes" "$estado/krb5.conf"
        systemctl daemon-reload
        printf 'Concluído. Debian %s. ' "$VERSION_ID"
        /usr/sbin/samba --version
        return
    fi

    if [[ $versao == bullseye ]]; then proxima=bookworm; else proxima=trixie; fi
    gravar_fase "$estado" "em-andamento:$proxima:$boot_atual"
    componentes=(main)
    if grep -qsE '^[[:space:]]*deb(-src)?[[:space:]].*[[:space:]]contrib([[:space:]]|$)' /etc/apt/sources.list /etc/apt/sources.list.d/*.list; then componentes+=(contrib); fi
    if grep -qsE '^[[:space:]]*deb(-src)?[[:space:]].*[[:space:]]non-free([[:space:]]|$)' /etc/apt/sources.list /etc/apt/sources.list.d/*.list; then
        componentes+=(non-free non-free-firmware)
    elif grep -qsE '^[[:space:]]*deb(-src)?[[:space:]].*[[:space:]]non-free-firmware([[:space:]]|$)' /etc/apt/sources.list /etc/apt/sources.list.d/*.list; then
        componentes+=(non-free-firmware)
    fi
    if [[ $versao == bullseye ]]; then
        fontes_migracao "$estado" bullseye "${componentes[@]}"
    fi
    apt-get -o APT::Update::Error-Mode=any update
    plano=$(apt-get -s dist-upgrade)
    validar_plano "$plano"
    apt-get "${apt_opcoes[@]}" dist-upgrade
    fontes_migracao "$estado" "$proxima" "${componentes[@]}"
    apt-get -o APT::Update::Error-Mode=any update
    apt-get "${apt_opcoes[@]}" upgrade
    plano=$(apt-get -s dist-upgrade)
    validar_plano "$plano"
    apt-get "${apt_opcoes[@]}" dist-upgrade
    (
        unset VERSION_CODENAME
        . /etc/os-release
        [[ ${VERSION_CODENAME:-} == "$proxima" ]]
    ) || die "O Debian ainda não reporta $proxima."
    dpkg --audit > "$estado/dpkg-audit"
    [[ ! -s $estado/dpkg-audit ]] || die 'O upgrade terminou com pendências no dpkg.'
    verificar_ad
    gravar_fase "$estado" "apos-reboot:$proxima:$boot_atual"
    trap - EXIT
    if ! systemctl --no-block reboot; then
        rm -f -- "$estado/krb5cc"
        die 'O reboot não pôde ser agendado.'
    fi
}

validar_fonte_apt() {
    local arquivo=$1 versao=$2 linha suite numero=0
    local formato='^[[:space:]]*(deb|deb-src)[[:space:]]+(\[[^]]+\][[:space:]]+)?https?://((deb|security|archive|cdn-fastly|ftp)\.debian\.org|ftp\.[[:alpha:]]{2}\.debian\.org)/debian(-security)?/?[[:space:]]+([^[:space:]#]+)([[:space:]]|$)'
    while IFS= read -r linha || [[ -n $linha ]]; do
        numero=$((numero + 1))
        linha=${linha%%#*}
        [[ $linha =~ ^[[:space:]]*$ ]] && continue
        [[ $linha =~ $formato ]] ||
            die "Fonte APT não reconhecida em $arquivo:$numero. Confira a linha antes de migrar."
        suite=${BASH_REMATCH[6]}
        [[ $suite == "$versao" || $suite == "$versao"-updates ||
           $suite == "$versao"-security || $suite == "$versao"-backports ]] ||
            die "Suite APT inesperada em $arquivo:$numero: $suite."
    done < "$arquivo"
}

gravar_fase() {
    printf '%s\n' "$2" > "$1/fase.nova"
    mv -f -- "$1/fase.nova" "$1/fase"
}

validar_plano() {
    if grep -Eq '^Remv (samba(:|[[:space:]])|samba-ad-dc(:|[[:space:]])|samba-common-bin(:|[[:space:]])|python3-samba(:|[[:space:]])|openssh-server(:|[[:space:]])|grub[^[:space:]]*|linux-image-amd64(:|[[:space:]]))' <<< "$1"; then
        printf '%s\n' "$1"
        die 'O APT planejou remover um pacote necessário ao AD, SSH ou boot.'
    fi
}

verificar_ad() {
    systemctl is-active --quiet samba-ad-dc.service || die 'O serviço samba-ad-dc não está ativo.'
    samba-tool dbcheck --cross-ncs
}

fontes_migracao() {
    local estado=$1 release=$2 arquivo base security tipo
    shift 2
    local -a componentes=("$@") tipos=(deb)
    if grep -qsE '^[[:space:]]*deb-src[[:space:]]' /etc/apt/sources.list /etc/apt/sources.list.d/*.list; then
        tipos+=(deb-src)
    fi
    mkdir -p "$estado/fontes-desativadas"
    for arquivo in /etc/apt/sources.list.d/*.list; do
        [[ -f $arquivo ]] || continue
        mv -- "$arquivo" "$estado/fontes-desativadas/"
    done
    if [[ $release == bullseye ]]; then
        base=https://archive.debian.org/debian
        security=https://archive.debian.org/debian-security
        local -a bullseye=()
        for arquivo in "${componentes[@]}"; do
            [[ $arquivo == non-free-firmware ]] || bullseye+=("$arquivo")
        done
        componentes=("${bullseye[@]}")
    else
        base=https://deb.debian.org/debian
        security=https://deb.debian.org/debian-security
    fi
    {
        for tipo in "${tipos[@]}"; do
            printf '%s %s %s %s\n' "$tipo" "$base" "$release" "${componentes[*]}"
            printf '%s %s %s-security %s\n' "$tipo" "$security" "$release" "${componentes[*]}"
            if [[ $release != bullseye ]]; then
                printf '%s %s %s-updates %s\n' "$tipo" "$base" "$release" "${componentes[*]}"
            fi
        done
    } > /etc/apt/sources.list
}

validar_redes() {
    python3 - "$1" <<'PYNET'
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
PYNET
}

(( EUID == 0 )) || die 'Execute como root no controlador de domínio.'
[[ -r /etc/os-release ]] || die 'Sistema operacional não identificado.'
. /etc/os-release
[[ ${ID:-} == debian ]] || die 'Este script foi preparado para Debian.'
for cmd in samba-tool testparm python3 flock; do
    command -v "$cmd" >/dev/null || die "Comando ausente: $cmd."
done
if [[ ${1:-} == --atualizar || ${1:-} == --retomar ]]; then
    [[ $# -eq 1 ]] || die 'Uso: configurar-ntp-samba-ad.sh [--atualizar]'
    atualizar_sistema "$1"
    exit
fi
[[ $# -eq 0 || ( $# -eq 1 && $1 == --pos-atualizacao ) ]] ||
    die 'Uso: configurar-ntp-samba-ad.sh [--atualizar]'
samba-tool gpo load --help >/dev/null 2>&1 ||
    die 'Este Samba não tem gpo load. Use --atualizar para executar a migração validada pelo script.'

exec 9>/run/lock/configurar-ntp-samba-ad.lock
flock -n 9 || die 'Já existe outra execução neste servidor.'
estado=/var/lib/samba-ntp-atualizacao
if [[ ${1:-} == --pos-atualizacao ]]; then
    [[ -r $estado/redes && -r $estado/krb5cc ]] || die 'Dados da atualização indisponíveis.'
    exec 3<>/dev/null
else
    exec 3<>/dev/tty || die 'Abra uma sessão interativa no console ou por SSH.'
fi

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
if [[ ${1:-} == --pos-atualizacao ]]; then
    subnet_input=$(<"$estado/redes")
else
    printf 'Redes das estações em CIDR, separadas por espaço ou vírgula: ' >&3
    IFS= read -r subnet_input <&3 || die 'Leitura das redes interrompida.'
fi
subnets=$(validar_redes "$subnet_input")
if [[ ${1:-} != --pos-atualizacao ]]; then
    printf 'Usuário administrador do AD [Administrator]: ' >&3
    IFS= read -r ad_user <&3 || die 'Leitura do usuário interrompida.'
    ad_user=${ad_user:-Administrator}
    [[ $ad_user == *@* ]] || ad_user="$ad_user@${realm^^}"
fi

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
if [[ ${1:-} == --pos-atualizacao ]]; then
    ccache="FILE:$estado/krb5cc"
    klist -s -c "$ccache" || die 'Ticket do AD expirado. Execute o script sem --atualizar para concluir o NTP e a GPO.'
else
    printf 'Informe a senha do administrador do AD quando solicitado.\n' >&3
    kinit -c "$ccache" "$ad_user" <&3 >&3 || die 'Falha na autenticação Kerberos.'
fi
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

