#!/bin/bash
# shellcheck disable=SC1091,SC2015,SC2034
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

get_local_iface() {
    comm -12 <(ifconfig | grep ': flags=' | grep -vP '(SLAVE|POINTOPOINT)' | grep -oP '.*(?=:)' | sort -u) <(route -n | awk '{$1=""; print substr($0,2)}' | grep -P '^\d' | grep -v '^0\.0\.0\.0' | awk '{print $NF}' | sort -u)
}

get_local_ip() {
    CLS_LOCAL_IFACE=$(get_local_iface)
    [ -n "$CLS_LOCAL_IFACE" ] || return 1
    ip r | grep -q '^default via' || sudo ip r add default via "$(nmcli dev show "$CLS_LOCAL_IFACE" | grep -oP '((?<=GATEWAY:)[^-]*|/0.*?= [^,]+)' | grep -oE '[^ ]+$' | head -n1)" &>/dev/null
    ip a show "$CLS_LOCAL_IFACE" | grep -oP 'inet \K\S+' | cut -d/ -f1
}

CLS_TYPE_NODE=$(echo "$CLS_TYPE_NODE" | tr '[:upper:]' '[:lower:]')
CLS_LOCAL_IP=$(get_local_ip)
CLS_WG_SERVER=$(echo "$INTERNAL_SUBNET" | awk 'BEGIN{FS=OFS="."} NF--').1
CLS_WG_SERVER_IP=""

set_netplan() {
    sudo cp -f netplan/"${1:-open}".yml /etc/netplan/99_config.yaml
    sudo chmod 0600 /etc/netplan/99_config.yaml
    sudo netplan apply
    local try=0
    until CLS_LOCAL_IP=$(get_local_ip); do ((try++)) && ((try > 60)) && return 1 || sleep 1; done
    sudo tc qdisc del dev "$CLS_LOCAL_IFACE" root &>/dev/null
    sudo tc qdisc replace dev "$CLS_LOCAL_IFACE" root cake "$([ -z "$CLS_BANDWIDTH" ] || echo "bandwidth $CLS_BANDWIDTH")" diffserv8 nat docsis ack-filter
    sed -i "s/#\?- FTLCONF_LOCAL_IPV4=.*$/- FTLCONF_LOCAL_IPV4=$CLS_LOCAL_IP/" compose.yml
}

is_ip() {
    [[ "$1" =~ ^[0-9.]+$ || "$1" =~ ^[0-9a-fA-F:]+$ ]]
}

should_check_server_ip() {
    if [[ "$CLS_TYPE_NODE" =~ (spoke|saah) ]] && is_ip "$SERVERURL"; then
        is_ip "$CLS_WG_SERVER_IP" || CLS_WG_SERVER_IP=$(dig +short "$SERVERURL")
        return 0
    fi

    return 1
}

set +a
