#!/bin/bash
rpath="$(readlink ${BASH_SOURCE})"
if [ -z "$rpath" ];then
    rpath=${BASH_SOURCE}
fi
pwd=${PWD}
this="$(cd $(dirname $rpath) && pwd)"
# cd "$this"
export PATH=$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

user="${SUDO_USER:-$(whoami)}"
home="$(eval echo ~$user)"

# export TERM=xterm-256color

# Use colors, but only if connected to a terminal, and that terminal
# supports them.
if which tput >/dev/null 2>&1; then
  ncolors=$(tput colors 2>/dev/null)
fi
if [ -t 1 ] && [ -n "$ncolors" ] && [ "$ncolors" -ge 8 ]; then
    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"
            CYAN="$(tput setaf 5)"
    BOLD="$(tput bold)"
    NORMAL="$(tput sgr0)"
else
    RED=""
    GREEN=""
    YELLOW=""
            CYAN=""
    BLUE=""
    BOLD=""
    NORMAL=""
fi
_err(){
    echo "$*" >&2
}

_runAsRoot(){
    cmd="${*}"
    local rootID=0
    if [ "${EUID}" -ne "${rootID}" ];then
        echo -n "Not root, try to run as root.."
        # or sudo sh -c ${cmd} ?
        if eval "sudo ${cmd}";then
            echo "ok"
            return 0
        else
            echo "failed"
            return 1
        fi
    else
        # or sh -c ${cmd} ?
        eval "${cmd}"
    fi
}

rootID=0
function _root(){
    if [ ${EUID} -ne ${rootID} ];then
        echo "Need run as root!"
        echo "Requires root privileges."
        exit 1
    fi
}

ed=vi
if command -v vim >/dev/null 2>&1;then
    ed=vim
fi
if command -v nvim >/dev/null 2>&1;then
    ed=nvim
fi
if [ -n "${editor}" ];then
    ed=${editor}
fi
###############################################################################
# write your code below (just define function[s])
# function is hidden when begin with '_'
###############################################################################
# TODO
certDir=/tmp/pki
serverDomain=sh.eagle711.win
caKey=ca-key.pem
caCert=ca-cert.pem
dn="C=CN, O=IKEv2 server, CN=IKEv2 VPN Server Root CA"
rightdns=10.1.1.1
subnet="10.8.0.0/16"
declare -a accounts=(
    "public|public"
    "eagle|eagle"
)

install(){
    echo "Install strongswan strongswan-pki"
    _runAsRoot "apt install strongswan strongswan-pki libcharon-extra-plugins -y" || { echo "Install strongswan failed!"; exit 1; }
    _runAsRoot "systemctl disable --now strongswan"

    echo "Create cacerts certs private directory in ${certDir}"
    mkdir -p ${certDir}/{cacerts,certs,private}

    _cacert

    _servercert

    _runAsRoot "cp -r ${certDir}/cacerts /etc/ipsec.d/"
    _runAsRoot "cp -r ${certDir}/certs /etc/ipsec.d/"
    _runAsRoot "cp -r ${certDir}/private /etc/ipsec.d/"

    _config


    echo "add ${this}/bin to PATH manaually"

    sed -e "s|START_PRE|${this}/bin/ikev2ctl _start_pre|g" \
        -e "s|STOP_POST|${this}/bin/ikev2ctl _stop_post|g" ikev2.service > /tmp/ikev2.service
    _runAsRoot "mv /tmp/ikev2.service /etc/systemd/system/ikev2.service"
    _runAsRoot "systemctl daemon-reload"
    _runAsRoot "systemctl enable --now ikev2.service"

}

# Create ca cer
_cacert(){
    echo "Create CA key"
    ipsec pki --gen --type rsa --size 4096 --outform pem > ${certDir}/private/${caKey}

    echo "Create CA cert"
    ipsec pki --self --ca --lifetime 3650 --in ${certDir}/private/${caKey} --type rsa \
              --dn "${dn}" --outform pem > ${certDir}/cacerts/${caCert}
}

# Create server cert
_servercert(){
    echo "Create server private key"
    ipsec pki --gen --type rsa --size 4096 --outform pem > ${certDir}/private/server-key.pem

    echo "Create server cert with CA cert"
    ipsec pki --pub --in ${certDir}/private/server-key.pem --type rsa \
        | ipsec pki --issue --lifetime 1825 \
            --cacert ${certDir}/cacerts/${caCert} \
            --cakey ${certDir}/private/${caKey} \
            --dn "${dn}" \
            --san "${serverDomain}" \
            --flag serverAuth \
            --flag ikeIntermediate --outform pem \
            > ${certDir}/certs/server-cert.pem
}

_config(){
    echo "Backup /etc/ipsec.conf"
    _runAsRoot "mv /etc/ipsec.conf /etc/ipsec.conf.ori"

    cat<<-EOF>/tmp/ipsec.conf
config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=no

conn ikev2-vpn
    auto=add
    compress=no
    type=tunnel
    keyexchange=ikev2
    fragmentation=yes
    forceencaps=yes
    ike=chacha20poly1305-prfsha256-newhope128,chacha20poly1305-prfsha256-ecp256,aes128gcm16-prfsha256-ecp256,aes256-sha256-modp2048,aes256-sha256-modp1024!
    esp=chacha20poly1305-newhope128,chacha20poly1305-ecp256,aes128gcm16-ecp256,aes256-sha256-modp2048,aes256-sha256,aes256-sha1!

    dpdaction=clear
    dpddelay=300s
    rekey=no

    left=%any
    leftid=@${serverDomain}
    leftcert=server-cert.pem
    leftsendcert=always
    leftsubnet=0.0.0.0/0

    right=%any
    rightid=%any
    rightauth=eap-mschapv2
    rightsourceip=${subnet}
    rightdns=${rightdns}
    rightsendcert=never

    eap_identity=%identity

	EOF

    _runAsRoot "mv /tmp/ipsec.conf /etc/ipsec.conf"


    cat<<-EOF>/tmp/ipsec.secrets
 : RSA "/etc/ipsec.d/private/server-key.pem"
EOF
    for account in "${accounts[@]}";do
        user="$(echo $account | perl -lne 'print $1 if /(\w+)\|(\w+)/')"
        password="$(echo $account | perl -lne 'print $2 if /(\w+)\|(\w+)/')"
        echo "${user} %any% : EAP \"${password}\"" >> /tmp/ipsec.secrets
    done

    _runAsRoot "mv /tmp/ipsec.secrets /etc/ipsec.secrets"

}

em(){
    $ed $0
}

###############################################################################
# write your code above
###############################################################################
function _help(){
    cat<<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    # perl -lne 'print "\t$1" if /^\s*(\w+)\(\)\{$/' $(basename ${BASH_SOURCE})
    # perl -lne 'print "\t$2" if /^\s*(function)?\s*(\w+)\(\)\{$/' $(basename ${BASH_SOURCE}) | grep -v '^\t_'
    perl -lne 'print "\t$2" if /^\s*(function)?\s*(\w+)\(\)\{$/' $(basename ${BASH_SOURCE}) | perl -lne "print if /^\t[^_]/"
}

function _loadENV(){
    if [ -z "$INIT_HTTP_PROXY" ];then
        echo "INIT_HTTP_PROXY is empty"
        echo -n "Enter http proxy: (if you need) "
        read INIT_HTTP_PROXY
    fi
    if [ -n "$INIT_HTTP_PROXY" ];then
        echo "set http proxy to $INIT_HTTP_PROXY"
        export http_proxy=$INIT_HTTP_PROXY
        export https_proxy=$INIT_HTTP_PROXY
        export HTTP_PROXY=$INIT_HTTP_PROXY
        export HTTPS_PROXY=$INIT_HTTP_PROXY
        git config --global http.proxy $INIT_HTTP_PROXY
        git config --global https.proxy $INIT_HTTP_PROXY
    else
        echo "No use http proxy"
    fi
}

function _unloadENV(){
    if [ -n "$https_proxy" ];then
        unset http_proxy
        unset https_proxy
        unset HTTP_PROXY
        unset HTTPS_PROXY
        git config --global --unset-all http.proxy
        git config --global --unset-all https.proxy
    fi
}


case "$1" in
     ""|-h|--help|help)
        _help
        ;;
    *)
        "$@"
esac

