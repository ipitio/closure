#!/bin/bash
# shellcheck disable=SC1091,SC2009,SC2015,SC2034,SC2068
# Definitions for Closure

set -a

# Closure settings from env.sh
source "$(dirname "$(readlink -f "$0")")/env.sh"

if [ -z "$CLS_TYPE_NODE" ]; then
    echo "Node type is not set"
    exit 1
fi

# WireGuard settings from compose.yml
SERVERURL="$(grep -oP '(?<=SERVERURL=).+' compose.yml)"
SERVERPORT="$(grep -oP '(?<=SERVERPORT=).+' compose.yml)"
PEERDNS="$(grep -oP '(?<=PEERDNS=).+' compose.yml)"
PEERS="$(grep -oP '(?<=PEERS=).+' compose.yml)"
ALLOWEDIPS="$(grep -oP '(?<=ALLOWEDIPS=).+' compose.yml)"
PERSISTENTKEEPALIVE_PEERS="$(grep -oP '(?<=PERSISTENTKEEPALIVE_PEERS=).+' compose.yml)"
INTERNAL_SUBNET="$(grep -oP '(?<=INTERNAL_SUBNET=).+' compose.yml)"

# get all "SERVER_ALLOWEDIPS_PEER_.*=.*" in compose.yml
while IFS= read -r line; do
    var_name=$(cut -d= -f1 <<<"$line")
    var_value=$(cut -d= -f2 <<<"$line")
    declare "$var_name=$var_value"
done < <(grep -oP 'SERVER_ALLOWEDIPS_PEER_.*=.*' compose.yml)

user_exists() { id "$1" &>/dev/null; }

sudo() {
    if command -v sudo >/dev/null; then
        command sudo "$@"
    else
        "$@"
    fi
}

wg() {
    if $CLS_DOCKER; then
        sudo docker exec wireguard wg "$@"
    else
        command wg "$@"
    fi
}

CLS_LOCAL_IFACE=""
CLS_GATEWAY=""

get_local_iface() {
    comm -12 <(ifconfig | grep ': flags=' | grep -vP '(SLAVE|POINTOPOINT)' | grep -oP '.*(?=:)' | sort -u) <(route -n | awk '{$1=""; print substr($0,2)}' | grep -P '^\d' | grep -v '^0\.0\.0\.0' | awk '{print $NF}' | sort -u)
}

get_local_ip() {
    CLS_LOCAL_IFACE=$(get_local_iface)
    [ -n "$CLS_LOCAL_IFACE" ] || return 1
    ip r | grep -q '^default via' || sudo ip r add default via "$(nmcli dev show "$CLS_LOCAL_IFACE" | grep -oP '((?<=GATEWAY:)[^-]*|/0.*?= [^,]+)' | grep -oE '[^ ]+$' | head -n1)" dev "$CLS_LOCAL_IFACE" &>/dev/null
    CLS_GATEWAY=$(ip r | grep -oP '^default via \K\S+')
    ip a show "$CLS_LOCAL_IFACE" | grep -oP 'inet \K\S+' | cut -d/ -f1
}

CLS_TYPE_NODE=$(echo "$CLS_TYPE_NODE" | tr '[:upper:]' '[:lower:]')
CLS_WG_SERVER=$(echo "$INTERNAL_SUBNET" | awk 'BEGIN{FS=OFS="."} NF--').1
CLS_WG_SERVER_IP=""

set_netplan() {
    [[ "$(md5sum netplan.yml | cut -d' ' -f1 | sudo tee new.netplan.hash)" != "$(cat netplan.hash 2>/dev/null)" || -n "$1" ]] || return 0
    sudo mv -f new.netplan.hash netplan.hash
    ps -aux | grep -P "^[^-]+hostapd" | awk '{print $2}' | while read -r pid; do sudo kill -9 "$pid" &>/dev/null; done
    IFS='/' read -r -a wifaces <<<"$CLS_AP_WIFACES"

    for wiface in "${!wifaces[@]}"; do
        sudo rm -f /var/run/hostapd/"$wiface" &>/dev/null
        [[ ! "$wiface" =~ @ ]] || sudo iw dev "$wiface" del &>/dev/null
    done

    sudo cp -f netplan.yml /etc/netplan/99_config.yaml
    sudo chmod 0600 /etc/netplan/99_config.yaml
    sudo netplan apply
    sudo iw dev "$CLS_WIFACE" set power_save off
    sudo cp -f /etc/resolv.conf.bak /etc/resolv.conf
    get_local_ip # set variables
    [ -z "$CLS_LOCAL_IFACE" ] || sudo tc qdisc del dev "$CLS_LOCAL_IFACE" root &>/dev/null
    [ -z "$CLS_LOCAL_IFACE" ] || sudo tc qdisc replace dev "$CLS_LOCAL_IFACE" root cake "$([ -z "$CLS_BANDWIDTH" ] && echo diffserv8 || echo "bandwidth $CLS_BANDWIDTH diffserv8")" nat docsis ack-filter
}

is_ip() {
    [[ "$1" =~ ^[0-9.]+$ || "$1" =~ ^[0-9a-fA-F:]+$ ]]
}

curl() {
    # if connection times out or max time is reached, wait increasing amounts of time before retrying
    local i=2
    local max_attempts=7
    local wait_time=1
    local result

    while [ "$i" -lt "$max_attempts" ]; do
        result=$(command curl -sSLNZ --connect-timeout 60 -m 120 "$@" 2>/dev/null)
        [ -n "$result" ] && echo "$result" && return 0
        sleep "$wait_time"
        ((i++))
        ((wait_time *= i))
    done

    echo ""
    return 1
}

direct_domain(){
    local ichi
    ichi=$(dig +short "$1")
    for ip in $ichi; do ip r | grep -q "$ip" || sudo ip route add "$ip" via "$CLS_GATEWAY" dev "$CLS_LOCAL_IFACE" &>/dev/null; done
    $2
    for ip in $ichi; do ! ip r | grep -q "$ip" || sudo ip route del "$ip" &>/dev/null; done
}

get_server_ip() {
    local server_ip="$CLS_WG_SERVER_IP"

    if ! is_ip "$server_ip" ; then
        if ! is_ip "$SERVERURL"; then
            if [[ "$CLS_TYPE_NODE" =~ (spoke|saah) ]]; then
                server_ip=$(dig +short "$SERVERURL" | grep -oP '\S+$' | tail -n1)
            else
                local ichi
                ichi=$(dig +short icanhazip.com)
                for ip in $ichi; do ip r | grep -q "$ip" || sudo ip route add "$ip" via "$CLS_GATEWAY" dev "$CLS_LOCAL_IFACE"; done
                server_ip=$(direct_domain icanhazip.com "curl https://icanhazip.com" | tail -n1)
                for ip in $ichi; do ! ip r | grep -q "$ip" || sudo ip route del "$ip"; done
            fi
        else
            server_ip="$SERVERURL"
        fi
    fi

    echo "$server_ip"
}

cast() {
    local hook="$1"
    shift
    pushd /home/"$CLS_ACTIVE_USER"/ || exit
    sudo bash hooks/"$hook".sh ${@@Q}
    popd || exit
}

set +a
