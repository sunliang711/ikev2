#!/bin/bash
rpath="$(readlink ${BASH_SOURCE})"
if [ -z "$rpath" ];then
    rpath=${BASH_SOURCE}
fi
thisDir="$(cd $(dirname $rpath) && pwd)"
cd "$thisDir"

user="${SUDO_USER:-$(whoami)}"
home="$(eval echo ~$user)"

red=$(tput setaf 1)
green=$(tput setaf 2)
yellow=$(tput setaf 3)
blue=$(tput setaf 4)
cyan=$(tput setaf 5)
        bold=$(tput bold)
reset=$(tput sgr0)
runAsRoot(){
    verbose=0
    while getopts ":v" opt;do
        case "$opt" in
            v)
                verbose=1
                ;;
            \?)
                echo "Unknown option: \"$OPTARG\""
                exit 1
                ;;
        esac
    done
    shift $((OPTIND-1))
    cmd="$@"
    if [ -z "$cmd" ];then
        echo "${red}Need cmd${reset}"
        exit 1
    fi

    if [ "$verbose" -eq 1 ];then
        echo "run cmd:\"${red}$cmd${reset}\" as root."
    fi

    if (($EUID==0));then
        sh -c "$cmd"
    else
        if ! command -v sudo >/dev/null 2>&1;then
            echo "Need sudo cmd"
            exit 1
        fi
        sudo sh -c "$cmd"
    fi
}
###############################################################################
        # write your code below (just define function[s])
###############################################################################
# TODO
name=ikev2-server
config=$(pwd)/config
config(){
    docker run --rm -it -v $config:/config cschlosser/ikev2-vpn configure
}

start(){
    if ! docker container inspect ${name} >/dev/null 2>&1;then
        echo -n "No container ${name}, create it..."
        docker container create --privileged --name=${name} --restart=always -v $config:/config -p 500:500/udp -p 4500:4500/udp cschlosser/ikev2-vpn >/dev/null 2>&1 && echo "Done."|| { echo "create container ${name} failed."; exit 1; }
    fi
    echo -n "Start $name..."
    docker start $name >/dev/null 2>&1 && echo "Done." || echo "Failed."
}

stop(){
    echo -n "Stop $name..."
    docker stop $name >/dev/null 2>&1 && echo "Done." || echo "Failed."
}

rm(){
    stop
    echo -n "Remove container $name..."
    docker rm $name >/dev/null 2>&1 && echo "Done." || echo "Failed."
}

restart(){
    stop
    start
}



###############################################################################
# write your code above
###############################################################################
help(){
    cat<<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    perl -lne 'print "\t$2" if /^(function)?\s*?(\w+)\(\)\{$/' $(basename ${BASH_SOURCE}) | grep -v runAsRoot
}

case "$1" in
     ""|-h|--help|help)
        help
        ;;
    *)
        "$@"
esac
