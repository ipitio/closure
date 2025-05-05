#!/bin/bash
# shellcheck disable=SC1091,SC2015,SC2068

this_dir=$(dirname "$(readlink -f "$0")")
pushd "$this_dir" || exit 1
source "lib.sh"

cast pre-down ${@@Q}
sudo sysctl -w net.ipv4.ip_forward=0
sudo sysctl -w net.ipv6.conf.all.forwarding=0
sudo docker ps | grep -q wireguard && sudo docker compose stop wireguard || sudo wg-quick down "$CLS_INTERN_IFACE"
sudo docker ps | grep -qE "pihole.*Up" || sudo cp -f /etc/resolv.conf.orig /etc/resolv.conf

# shellcheck disable=SC2009
ps -aux | grep -P "^[^-]+$this_dir/start.sh" | awk '{print $2}' | while read -r pid; do sudo kill -9 "$pid" &>/dev/null; done

route -n | grep -P "$(ip r | grep -oP 'default via \K\S+')\s+255\.255\.255\.255" | awk '{print $1}' | while read -r endpoint; do
    sudo route del -net "$endpoint" netmask 255.255.255.255 gw "$(ip r | grep -oP 'default via \K\S+')" &>/dev/null
done

sudo ip route flush table 7
sudo ip route flush cache

for tables in iptables ip6tables; do
    sudo "$tables" -D FORWARD -i "$CLS_INTERN_IFACE" -j ACCEPT &>/dev/null
    sudo "$tables" -D FORWARD -o "$CLS_INTERN_IFACE" -j ACCEPT &>/dev/null
    sudo "$tables" -t nat -D POSTROUTING -j MASQUERADE &>/dev/null
    sudo "$tables" -D OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT &>/dev/null
    sudo "$tables" -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu &>/dev/null
    sudo "$tables"-legacy-save | uniq | sudo "$tables"-restore
done

cast post-down ${@@Q}
popd || exit
