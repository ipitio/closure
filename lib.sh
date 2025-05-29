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
        command sudo -E ${@:-:} || ${@:-:}
    else
        ${@:-:}
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
    aps=$(sudo find /var/run/hostapd -type s 2>&1 | grep -oP '(?<=/var/run/hostapd/).+')
    ps -aux | grep -P "^[^-]+hostapd$2" | awk '{print $2}' | while read -r pid; do sudo kill -9 "$pid" &>/dev/null; done

    for wiface in $1 $aps; do
        [[ -z "$1" || "$1" == "$wiface" ]] || continue
        sudo rm -rf /var/run/hostapd/"$wiface" &>/dev/null
        [[ ! "$wiface" =~ @ ]] || sudo iw dev "$wiface" del &>/dev/null
    done
}

start_hostapd() {
    (
        until [ -n "$CLS_LOCAL_IFACE" ]; do
            get_local_ip
            sleep 1
        done
        [ ! -f /etc/resolv.conf ] || sudo rm -f /etc/resolv.conf
        (
            cat resolv.conf
            (
                nmcli dev show "$CLS_LOCAL_IFACE" | grep DNS | grep -oP '\S+$'
            ) | while read -r ip; do echo "nameserver $ip"; done
            (
                nmcli dev show "$CLS_LOCAL_IFACE" | grep DOMAIN | grep -oP '\S+$' || echo .
            ) | while read -r name; do echo "search $name"; done
        ) | sudo tee /etc/resolv.conf >/dev/null
        sudo tc qdisc del dev "$CLS_LOCAL_IFACE" root &>/dev/null
        sudo tc qdisc replace dev "$CLS_LOCAL_IFACE" root cake "$([ -z "$CLS_BANDWIDTH" ] && echo diffserv8 || echo "bandwidth $CLS_BANDWIDTH diffserv8")" nat docsis ack-filter
        sudo busctl --system set-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.NetworkManager ConnectivityCheckEnabled "b" 0 2>/dev/null
        (crontab -l 2>/dev/null | grep -Fv "/ddns.sh &") | crontab -

        if [ -n "$CLS_DYN_DNS" ]; then
            (
                crontab -l 2>/dev/null
                echo "0,5,10,15,20,25,30,35,40,45,50,55 * * * * /usr/bin/sleep 10 ; /usr/bin/bash $this_dir/ddns.sh &"
            ) | crontab -
            sudo bash ddns.sh
        fi
    ) &

    if [ -n "$CLS_WIFACE" ]; then
        (
            until iwconfig "$CLS_WIFACE" | grep -q 'Bit Rate='; do sleep 1; done
            set_mac="$(jq ".[\"$(printf "%b" "$(iwconfig "$CLS_WIFACE" | grep -zoP '(?<=ESSID:").+(?=")' | tr -d '\0' | sed -r "s/\"/\\\\\"/g")")\"]" config/wifis.json 2>/dev/null | tr -d '"')"

            if (("${#set_mac}" == 17)) && [ "$set_mac" != "$(ifconfig "$CLS_WIFACE" | grep -oP "(?<=ether )\S+")" ]; then
                sudo ifconfig "$CLS_WIFACE" down
                sudo macchanger -m "$set_mac" "$CLS_WIFACE"
                sudo ifconfig "$CLS_WIFACE" up
            fi

            sudo iw dev "$CLS_WIFACE" set power_save off
            ip a show "$CLS_INTERN_IFACE" | grep -q UP || sudo CLS_WG_ONLY=true bash restart.sh ${@@Q}
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

            if [ "$config" = "." ]; then
                if [[ "$wiface" =~ @ ]]; then
                    config="$(iwconfig "${wiface//*@/}" | grep -oP '(?<=Frequency:)\d+')@"
                    [ ! -f hostapd/"$config${wiface//*@/}".conf ] || config=$config${wiface//*@/}
                else
                    config="$wiface"
                fi
            fi

            [ -f hostapd/"$config".conf ] && ! yq '(.network.wifis | keys)[]' netplan.yml | grep -qFx "$wiface" && iw dev | grep -qzP "Interface ${wiface//*@/}\n" && ! iw dev "$wiface" info | grep -q ssid || continue
            sudo sed -i "s/^\(interface\s*=\s*\).*/\1$wiface/" hostapd/"$config".conf
            sudo chmod 644 hostapd/"$config".conf

            (
                while :; do
                    while iw dev "$wiface" info | grep -q ssid; do sleep 5; done
                    until iw dev "$wiface" info | grep -q ssid; do
                        stop_hostapd "$wiface" ".*$config"

                        if [[ "$wiface" =~ @ ]]; then
                            sudo iw dev "${wiface//*@/}" interface add "$wiface" type __ap
                            freq=$(iw list | grep "$(iwconfig "${wiface//*@/}" | grep -oP '(?<=Frequency:)\S+' | tr -d '.')." | head -n1 | grep -oP '(?<=\[)[^\]]+')

                            if [ -z "$freq" ]; then
                                grep -q '^hw_mode=a' hostapd/"$config".conf && freq=149 || freq=11
                            fi

                            sudo sed -i "s/^\(channel\s*=\s*\).*/\1$freq/" hostapd/"$config".conf
                        fi

                        sudo hostapd -i "$wiface" -P /run/hostapd.pid -B hostapd/"$config".conf
                        sudo iw dev "$wiface" set power_save off
                        local octet
                        octet=$(ifconfig "$wiface" | grep -zoP '(?<=inet 10\.42\.)\S+(?=\.1)')

                        if [ -z "$octet" ]; then
                            octet=$((1 + $( (
                                ifconfig | grep -zoP '(?<=10\.42\.)\S+(?=\.1)'
                                echo 1
                            ) | grep -v 255 | sort -ru | head -n1)))
                            sudo ifconfig "$wiface" 10.42."$octet".1 netmask 255.255.255.0
                        fi

                        grep -qF "subnet 10.42.$octet.0 netmask 255.255.255.0" dhcp/dhcpd.conf || echo -e "\nsubnet 10.42.$octet.0 netmask 255.255.255.0 {\n    option routers 10.42.$octet.1;\n    range 10.42.$octet.2 10.42.$octet.254;\n}" | sudo tee -a dhcp/dhcpd.conf
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

dig() {
    command dig "$1" +trace 2>/dev/null | grep -oP "(?<=^${1//\./\\\.}\.).+(AAA)?A.+" | grep -oP '\S+$'
}

direct_domain() {
    local ichi
    ichi=$(dig "$(grep -oP '((?<=http:\/\/)|(?<=https:\/\/)).+?[^/?]+' <<<"$1")")
    for ip in $ichi; do ip r | grep -q "$ip" || sudo ip route add "$ip" via "$CLS_GATEWAY" dev "$CLS_LOCAL_IFACE" &>/dev/null; done
    $1 2>/dev/null
    for ip in $ichi; do ! ip r | grep -q "$ip" || sudo ip route del "$ip" &>/dev/null; done
}

get_server_ip() {
    local server_ip="$SERVERURL"

    if ! is_ip "$server_ip"; then
        if [[ "$CLS_TYPE_NODE" =~ (spoke|saah) ]]; then
            server_ip=$(dig "$SERVERURL" | tail -n1)
        else
            server_ip=$(direct_domain "curl https://icanhazip.com" | tail -n1)
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
