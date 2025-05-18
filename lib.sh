#!/bin/bash
# shellcheck disable=SC1091,SC2009,SC2015,SC2034,SC2068
# Definitions for Closure

set -a

# Closure settings from env.sh
this_dir=$(dirname "$(readlink -f "$0")")
source "$this_dir/env.sh"

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

CLS_TYPE_NODE=$(echo "$CLS_TYPE_NODE" | tr '[:upper:]' '[:lower:]')
CLS_WG_SERVER=$(echo "$INTERNAL_SUBNET" | awk 'BEGIN{FS=OFS="."} NF--').1
CLS_WG_SERVER_IP=""
CLS_LOCAL_IFACE=""
CLS_LOCAL_IP=""
CLS_GATEWAY=""

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

get_local_iface() {
    comm -12 <(ifconfig | grep ': flags=' | grep -vP '(SLAVE|POINTOPOINT)' | grep -oP '.*(?=:)' | sort -u) <(route -n | awk '{$1=""; print substr($0,2)}' | grep -P '^\d' | grep -v '^0\.0\.0\.0' | awk '{print $NF}' | sort -u)
}

get_local_ip() {
    CLS_LOCAL_IFACE=$(get_local_iface)
    [ -n "$CLS_LOCAL_IFACE" ] || return 1
    ip r | grep -q '^default via' || sudo ip r add default via "$(nmcli dev show "$CLS_LOCAL_IFACE" | grep -oP '((?<=GATEWAY:)[^-]*|/0.*?= [^,]+)' | grep -oE '[^ ]+$' | head -n1)" dev "$CLS_LOCAL_IFACE" &>/dev/null
    CLS_GATEWAY=$(ip r | grep -oP '^default via \K\S+')
    CLS_LOCAL_IP=$(ip a show "$CLS_LOCAL_IFACE" | grep -oP 'inet \K\S+' | cut -d/ -f1)
}

restart_isc() {
    source dhcp/isc-dhcp-server

    if [ -n "$INTERFACESv4" ]; then
        if ! diff -q dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf &>/dev/null || ! diff -q dhcp/isc-dhcp-server /etc/default/isc-dhcp-server &>/dev/null; then
            sudo cp -f dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf
            sudo cp -f dhcp/isc-dhcp-server /etc/default/isc-dhcp-server
        fi

        sudo systemctl restart isc-dhcp-server &
    else
        sudo systemctl stop isc-dhcp-server &
    fi
}

stop_hostapd() {
    local aps
    aps=$(sudo find /var/run/hostapd -type s | grep -oP '(?<=/var/run/hostapd/).+')
    ps -aux | grep -P "^[^-]+hostapd$2" | awk '{print $2}' | while read -r pid; do sudo kill -9 "$pid" &>/dev/null; done

    for wiface in $aps; do
        [[ -z "$1" || "$1" == "${wiface//*@/}" ]] || continue
        sudo rm -rf /var/run/hostapd/"$wiface" &>/dev/null
        [[ ! "$wiface" =~ @ ]] || sudo iw dev "$wiface" del &>/dev/null
    done
}

start_hostapd() {
    if [ -n "$CLS_WIFACE" ]; then
        (
            until iwconfig "$CLS_WIFACE" | grep -q 'Bit Rate='; do sleep 1; done
            set_mac="$(jq ".[\"$(iwconfig "$CLS_WIFACE" | grep -oP '(?<=ESSID:)\S+' | sed -r "s/^\"(.+)\"$/\1/g; s/\"/\\\\\"/g")\"]" config/wifis.json 2>/dev/null | tr -d '"')"

            if (("${#set_mac}" == 17)) && [ "$set_mac" != "$(ifconfig "$CLS_WIFACE" | grep -oP "(?<=ether )\S+")" ]; then
                sudo ifconfig "$CLS_WIFACE" down
                sudo macchanger -m "$set_mac" "$CLS_WIFACE"
                sudo ifconfig "$CLS_WIFACE" up
            fi
        ) &
    fi

    if ! $CLS_AP_HOSTAPD; then
        restart_isc
    else
        declare -A wifaces_configs
        IFS='/' read -r -a wifaces <<<"$CLS_AP_WIFACES"
        IFS='/' read -r -a configs <<<"$CLS_AP_CONFIGS"
        for i in "${!wifaces[@]}"; do wifaces_configs["${wifaces[$i]}"]="${configs[$i]}"; done

        for wiface in "${!wifaces_configs[@]}"; do
            config="${wifaces_configs[$wiface]}"
            [ "$config" != "." ] || config="$wiface"
            [ -f hostapd/"$config".conf ] && ! yq '(.network.wifis | keys)[]' netplan.yml | grep -qFx "$wiface" && iw dev | grep -qzP "Interface ${wiface//*@/}\n" && ! iw dev "$wiface" info | grep -q ssid || continue
            # https://raw.githubusercontent.com/MkLHX/AP_STA_RPI_SAME_WIFI_CHIP/refs/heads/master/ap_sta_config2.sh
            [[ ! "$wiface" =~ @ ]] || until [ -n "$freq" ]; do freq=$(iwconfig "${wiface//*@/}" | grep -oP '(?<=Frequency:)\S+' | tr -d '.'); done
            [[ ! "$wiface" =~ @ ]] || sudo sed -i "s/^\(channel\s*=\s*\).*/\1$(iw list | grep "$freq." | head -n1 | grep -oP '(?<=\[)[^\]]+')/" hostapd/"$config".conf
            sudo sed -i "s/^\(interface\s*=\s*\).*/\1$wiface/" hostapd/"$config".conf
            sudo chmod 644 hostapd/"$config".conf

            (
                while :; do
                    while iw dev "$wiface" info | grep -q ssid; do sleep 5; done
                    until iw dev "$wiface" info | grep -q ssid; do
                        echo "Starting hostapd on $wiface"
                        stop_hostapd "$wiface" ".*$config"
                        [[ ! "$wiface" =~ @ ]] || sudo iw dev "${wiface//*@/}" interface add "$wiface" type __ap
                        sudo hostapd -i "$wiface" -P /run/hostapd.pid -B hostapd/"$config".conf
                        sudo iw dev "$wiface" set power_save off
                        sudo ifconfig "$wiface" 10.42.1.$((1 + $( (ifconfig | grep -oP '(?<=10\.42\.1\.)\S+'; echo 1) | grep -v 255 | sort -ru | head -n1))) netmask 255.255.255.0
                        restart_isc
                        sleep 15
                    done
                done
            ) &
        done
    fi
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

direct_domain() {
    local ichi
    ichi=$(dig +short "$1")
    for ip in $ichi; do ip r | grep -q "$ip" || sudo ip route add "$ip" via "$CLS_GATEWAY" dev "$CLS_LOCAL_IFACE" &>/dev/null; done
    $2
    for ip in $ichi; do ! ip r | grep -q "$ip" || sudo ip route del "$ip" &>/dev/null; done
}

get_server_ip() {
    local server_ip="$CLS_WG_SERVER_IP"

    if ! is_ip "$server_ip"; then
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
    sudo bash "$this_dir/hooks/$hook.sh" ${@@Q}
    popd || exit
}

set +a
