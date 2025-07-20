#!/bin/bash
# shellcheck disable=SC1091,SC2009,SC2015,SC2068

WIFI="$(echo "$1" | sed -r "s/^\"(.*)\"$/\1/g")"   # string: name, SSID of the wifi to connect to
PORTAL=$2                                          # bool: true/false, whether wifi uses a captive portal
MAC="$(echo "$3" | sed -r "s/^\"(.*)\"$/\1/g")"    # string: MAC address of a device previously connected to the wifi, used if $PORTAL is true
PASSWD="$(echo "$4" | sed -r "s/^\"(.*)\"$/\1/g")" # string: password of the wifi, if it has one
ADD=${5:-true}                                     # bool: true/false, whether to add or remove the wifi

this_dir=$(dirname "$(readlink -f "$0")")
pushd "$this_dir" || exit 1
source "lib.sh"
pids=$(ps -o ppid=$$)
ps -aux | grep -P "^[^-]+$this_dir/start.sh" | awk '{print $2}' | while read -r pid; do grep -q "$pid" <<<"$pids" || sudo kill -9 "$pid" &>/dev/null; done

if [ ! "${CLS_WG_ONLY:-false}" = "true" ]; then
    [ -d config ] || sudo mkdir config
    [[ -f config/wifis.json && -s config/wifis.json ]] || echo "{}" | sudo tee config/wifis.json

    if [ -n "$WIFI" ]; then
        WIFI=${WIFI//\"/\\\"}

        if [ "$ADD" = "true" ]; then
            ! $PORTAL || jq "(. | select([\"$WIFI\"]) | .[\"$WIFI\"]) = \"$MAC\"" config/wifis.json | sudo tee config/new.wifis.json
            [[ ! -f config/new.wifis.json || ! -s config/new.wifis.json ]] || sudo mv -f config/new.wifis.json config/wifis.json
            wpa_ssid=".network.wifis.[\"$CLS_WIFACE\"].access-points.[\"$WIFI\"]"
            wpa_pass=". = {}"
            [ -z "$PASSWD" ] || wpa_pass=".password = \"$(wpa_passphrase "$WIFI" "$PASSWD" | grep -oP '(?<=[^#]psk=).+')\""
            yq -i "with($wpa_ssid; $wpa_pass | key style=\"double\")" netplan.yml
        else
            yq -i "del(.network.wifis.[\"$CLS_WIFACE\"].access-points.[\"$WIFI\"])" netplan.yml
            jq "del(.[\"$WIFI\"])" config/wifis.json | sudo tee config/new.wifis.json
            [[ ! -f config/new.wifis.json || ! -s config/new.wifis.json ]] || sudo mv -f config/new.wifis.json config/wifis.json
        fi
    fi

    if [ -f /boot/firmware/cmdline.txt ]; then
        if [ -n "$CLS_OTG_g_" ] && ! grep -q "dtoverlay=dwc2,dr_mode=peripheral" /boot/firmware/config.txt; then
            grep -q "dtoverlay=dwc2" /boot/firmware/config.txt || echo "dtoverlay=dwc2" | sudo tee -a /boot/firmware/config.txt
            sudo sed -i "s/dtoverlay=dwc2.*/dtoverlay=dwc2,dr_mode=peripheral/g" /boot/firmware/config.txt
            grep -q "dwc_otg.lpm_enable=" /boot/firmware/cmdline.txt || sudo sed -i '$s/$/ dwc_otg.lpm_enable=/' /boot/firmware/cmdline.txt
            grep -q "modules-load=" /boot/firmware/cmdline.txt || sudo sed -i '$s/$/ modules-load=/' /boot/firmware/cmdline.txt
            grep -qP "modules-load=.*dwc2" /boot/firmware/cmdline.txt || sudo sed -i "s/\(modules-load=[^ ]*\)/\1,dwc2/g" /boot/firmware/cmdline.txt
            grep -qP "modules-load=.*g_$CLS_OTG_g_" /boot/firmware/cmdline.txt || sudo sed -i "s/\(modules-load=[^ ]*\)/\1,g_$CLS_OTG_g_/g" /boot/firmware/cmdline.txt
            sudo sed -i "s/,\s+/ /g; s/=,/=/g; s/cfg80211.ieee80211_regdom=\S*/cfg80211.ieee80211_regdom=PA/g; s/dwc_otg.lpm_enable=\S*/dwc_otg.lpm_enable=0/g" /boot/firmware/cmdline.txt
            sudo reboot
        elif [ -z "$CLS_OTG_g_" ] && grep -q "dtoverlay=dwc2,dr_mode=peripheral" /boot/firmware/config.txt; then
            sudo sed -i "s/dtoverlay=dwc2.*/dtoverlay=dwc2,dr_mode=host/g" /boot/firmware/config.txt
            sudo reboot
        fi
    fi

    [ ! -d /etc/cloud/cloud.cfg.d ] || sudo mkdir -p /etc/cloud/cloud.cfg.d
    sudo touch /etc/cloud/cloud-init.disabled
    echo "network: {config: disabled}" | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg >/dev/null
    [ ! -f /etc/netplan/50-cloud-init.yaml ] || sudo mv -f /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.bak
    sudo rfkill unblock wlan
    sudo iw reg set PA
    sudo cp -f netplan.yml /etc/netplan/99_config.yaml
    sudo chmod 0600 /etc/netplan/99_config.yaml
    stop_hostapd
    sudo sed -i '/\# subnets for hostapd/q' dhcp/dhcpd.conf
    grep -q "subnets for hostapd" dhcp/dhcpd.conf || echo -e "# subnets for hostapd are generated automatically" | sudo tee -a dhcp/dhcpd.conf >/dev/null
    ifconfig | grep -oP '^\S+(?=:)' | while read -r iface; do
        sudo ifconfig "$iface" down
        [[ "$CLS_TYPE_NODE" =~ (spoke|saah) ]] && sudo macchanger -r "$iface" || sudo macchanger -p "$iface"
        sudo ifconfig "$iface" up
    done &>/dev/null
    sudo netplan apply
    eval "start_hostapd ${*@Q}" &
fi

if [ "$CLS_DOCKER" = "true" ]; then
    sudo systemctl enable --now docker

    for table in nat filter; do
        for chain in DOCKER DOCKER-ISOLATION-STAGE-1 DOCKER-ISOLATION-STAGE-2; do
            sudo iptables -L -t "$table" | grep -q "$chain" || sudo iptables -N "$chain" -t "$table"
            sudo ip6tables -L -t "$table" | grep -q "$chain" || sudo ip6tables -N "$chain" -t "$table"
        done
    done
fi

sudo sysctl -w net.ipv4.ip_forward=0
sudo sysctl -w net.ipv6.conf.all.forwarding=0
for iface in $(wg | grep -oP '(?<=interface: ).+'); do sudo wg-quick down "$iface"; done
wg | grep -oP '(?<=^interface: ).+' | while read -r iface; do sudo wg-quick down "$iface" &>/dev/null; done
eval "cast pre-up ${*@Q}"

(
    og_server_ip=$(get_server_ip)

    until ip a show "$CLS_INTERN_IFACE" | grep -q UP && ([[ ! "$CLS_TYPE_NODE" =~ spoke ]] || ping -c1 "$CLS_WG_SERVER" >/dev/null); do
        get_local_ip
        new_ip=$(get_server_ip 1)

        if is_ip "$new_ip"; then
            if is_ip "$og_server_ip"; then
                [ "$og_server_ip" = "$new_ip" ] || exec sudo CLS_WG_ONLY=true bash restart.sh ${@@Q}
            else
                og_server_ip="$new_ip"
            fi
        fi

        sleep 1
    done

    sudo sysctl -w net.ipv4.ip_forward=1
    sudo sysctl -w net.ipv6.conf.all.forwarding=1

    while ip a show "$CLS_INTERN_IFACE" | grep -q UP; do
        get_local_ip

        if ! ip rule show table 7 2>/dev/null | grep -qP '0x55' || ! ip route show table 7 2>/dev/null | grep -q default; then
            ip route show table 7 2>/dev/null | grep -q default || sudo ip route add default via "$CLS_GATEWAY" dev "$CLS_LOCAL_IFACE" table 7 &>/dev/null
            ip rule show table 7 2>/dev/null | grep -qP '0x55' || sudo ip rule add fwmark 0x55 table 7 &>/dev/null
            sudo ip route flush cache
        fi

        if ! is_ip "$SERVERURL"; then
            core_ip_now=$(get_server_ip)

            if ([[ "$CLS_TYPE_NODE" =~ (spoke|saah) ]] && ! is_ip "$core_ip_now") || (is_ip "$core_ip_now" && is_ip "$og_server_ip" && [ "$core_ip_now" != "$og_server_ip" ]); then
                [[ "$CLS_TYPE_NODE" =~ (spoke|saah) ]] && ping -c5 "$CLS_WG_SERVER" >/dev/null || break
            fi
        fi

        if [[ "$CLS_TYPE_NODE" =~ (hub|haas) ]] && [ -n "$CLS_DYN_DNS" ] && [ -n "$CLS_GATEWAY" ]; then
            ping -c5 "$CLS_GATEWAY" >/dev/null || break
        fi

        sleep 5
    done

    exec sudo CLS_WG_ONLY=false bash restart.sh ${@@Q}
) &

if [ "$CLS_DOCKER" = "true" ]; then
    # prod starts wg
    if [ ! "${CLS_WG_ONLY:-false}" = "true" ] || ! sudo docker ps | grep -qE "pihole.*Up"; then
        sudo docker compose down
        sudo docker compose ps -aq | xargs -r sudo docker rm -f
        sudo systemctl restart docker
        sudo docker network prune -f
        until [ -n "$CLS_LOCAL_IP" ]; do
            get_local_ip
            sleep 1
        done
        sed -i "s/#\?- FTLCONF_LOCAL_IPV4=.*$/- FTLCONF_LOCAL_IPV4=$CLS_LOCAL_IP/" compose.yml
        sudo docker compose --profile prod up -d --force-recreate --remove-orphans
    elif ! sudo docker ps | grep -qE "wireguard.*Up"; then
        sudo docker compose up -d wireguard
    fi
else
    sudo bash wireguard/etc/run
    sudo mkdir -p /etc/wireguard
    sudo rm -f /etc/wireguard/*.conf &>/dev/null
    sudo ls wireguard/config/wg_confs | grep -oP '.+\.conf$' | while read -r conf; do
        [ -s "wireguard/config/wg_confs/$conf" ] || continue
        config="/etc/wireguard/$conf"
        iface="${conf%.conf}"
        sudo cp -f "wireguard/config/wg_confs/$conf" "$config"
        sudo chmod 600 "$config"
        sudo chown root:root "$config"
        sudo wg-quick down "$iface"
        sudo wg-quick up "$iface"
    done
fi

restart_isc

if [[ "$CLS_TYPE_NODE" == "haas" && -n "$CLS_SAAH_PEER" ]]; then
    [[ -d "wireguard/config/peer_$CLS_SAAH_PEER" ]] || exec sudo bash wireguard/add.sh "$CLS_SAAH_PEER" -- ${@@Q}
    saah_ip="$(grep -oP '(?<=Address = ).+' "wireguard/config/peer_$CLS_SAAH_PEER/peer_$CLS_SAAH_PEER.conf" 2>/dev/null)"

    if is_ip "$saah_ip" && grep -qF "$saah_ip/32" "wireguard/config/wg_confs/$CLS_INTERN_IFACE.conf"; then
        sed -i "s|$saah_ip/32|0.0.0.0/1,128.0.0.0/1,::/1,8000::/1|" "wireguard/config/wg_confs/$CLS_INTERN_IFACE.conf"
        exec sudo CLS_WG_ONLY=true bash restart.sh ${@@Q}
    fi
fi

for tables in iptables ip6tables; do
    sudo "$tables" -I FORWARD -i "$CLS_INTERN_IFACE" -j ACCEPT &>/dev/null
    sudo "$tables" -I FORWARD -o "$CLS_INTERN_IFACE" -j ACCEPT &>/dev/null
    sudo "$tables" -t nat -I POSTROUTING -j MASQUERADE &>/dev/null
    sudo "$tables" -I OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT &>/dev/null
    sudo "$tables" -I FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu &>/dev/null
done

if [[ "$CLS_TYPE_NODE" =~ (hub|saah) ]] && [ -n "$CLS_EXTERN_IFACE" ]; then
    ( # Insert rule to allow internal vpn every time external vpn reconnects and adds output chain
        while :; do
            while sudo iptables -L OUTPUT -n 2>/dev/null | grep -qzE "destination\s*ACCEPT"; do sleep 5; done
            for tables in iptables ip6tables; do
                for action in D I; do sudo "$tables" -"$action" OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; done

                # This is probably for DNS
                [ -z "$CLS_EXTERN_CHAIN" ] || sudo "$tables" -t nat -F "$CLS_EXTERN_CHAIN"
            done
        done
    ) &
fi

! sudo docker ps | grep -q pihole || sudo docker compose restart unbound

if sudo docker ps | grep -qE "pihole.*Up" && ! sudo docker exec pihole sh -c "if [ -e /etc/dnsmasq.d/99-dns.conf ]; then echo 0; else echo 1; fi"; then
    # setup for pihole-updatelists
    sudo docker exec pihole sed -e '/pihole updateGravity/ s/^#*/#/' -i /etc/cron.d/pihole
    sudo docker exec pihole sqlite3 /etc/pihole/gravity.db "UPDATE adlist SET comment=comment || ' | \$COMMENT' WHERE comment NOT LIKE '%\$COMMENT%' AND address IN ($(curl -s https://v.firebog.net/hosts/lists.php?type=all | grep -oP '^https?://.+' | sed 's/.*/"&"/' | paste -sd,))"
    sudo docker exec pihole sqlite3 /etc/pihole/gravity.db "UPDATE domainlist SET comment=comment || ' | \$COMMENT' WHERE comment NOT LIKE '%\$COMMENT%' AND (type=0 OR type=3) AND domain IN ($( (
        curl -s https://raw.githubusercontent.com/anudeepND/whitelist/master/domains/whitelist.txt
        curl -s https://raw.githubusercontent.com/mmotti/pihole-regex/refs/heads/master/regex.list
    ) | grep -vP '(#|^\s*$)' | sed 's/.*/"&"/' | paste -sd,))"
    sudo docker exec pihole sed -i '/^.*_.*=.*$/!d' /etc/pihole/versions # pihole-updatelists seems to break this

    # proxy for dhcphelper
    sudo docker exec pihole bash -c "echo 'dhcp-option=option:dns-server,$CLS_LOCAL_IP' | tee /etc/dnsmasq.d/99-dns.conf >/dev/null" || :
    sudo docker compose restart --no-deps pihole
fi

eval "cast post-up ${*@Q}"
popd || exit
