#!/bin/bash
# shellcheck disable=SC1091,SC2009,SC2015,SC2068

this_dir=$(dirname "$(readlink -f "$0")")
pushd "$this_dir" || exit 1
source "lib.sh"
pids=$(ps -o ppid=$$)
ps -aux | grep -P "^[^-]+$this_dir/start.sh" | awk '{print $2}' | while read -r pid; do grep -q "$pid" <<<"$pids" || sudo kill -9 "$pid" &>/dev/null; done
sudo systemctl enable --now docker

for table in nat filter; do
  for chain in DOCKER DOCKER-ISOLATION-STAGE-1 DOCKER-ISOLATION-STAGE-2; do
    sudo iptables -L -t "$table" | grep -q "$chain" || sudo iptables -N "$chain" -t "$table"
    sudo ip6tables -L -t "$table" | grep -q "$chain" || sudo ip6tables -N "$chain" -t "$table"
  done
done

sudo bash hooks/pre-up.sh ${@@Q}

(
  should_check_server_ip
  until ip a show "$CLS_INTERN_IFACE" | grep -q UP; do sleep 1; done

  while ip a show "$CLS_INTERN_IFACE" | grep -q UP; do
    if ! ip rule show table 7 2>/dev/null | grep -qP '0x55' || ! ip route show table 7 2>/dev/null | grep -q default; then
      ip route show table 7 2>/dev/null | grep -q default || sudo ip route add default via "$(ip r | grep -oP 'default via \K\S+')" dev "$CLS_LOCAL_IFACE" table 7
      ip rule show table 7 2>/dev/null | grep -qP '0x55' || sudo ip rule add fwmark 0x55 table 7 &>/dev/null
      sudo ip route flush cache
    fi

    if [ -n "$CLS_EXTERN_IFACE" ] && [[ "$CLS_TYPE_NODE" =~ (hub|saah) ]] && ip a show "$CLS_EXTERN_IFACE" | grep -q UP; then
      sudo wg | grep -oE 'endpoint: [^:]+' | grep -oE '\S+$' | while read -r endpoint; do
        route -n | grep -q "$endpoint" || sudo route add -net "$endpoint" netmask 255.255.255.255 gw "$(ip r | grep -oP 'default via \K\S+')" &>/dev/null
      done
    fi

    if should_check_server_ip; then
      core_ip_now=$(dig +short "$SERVERURL" | grep -oP '\S+$' | tail -n1)

      # Only ping and break if either DNS failed or IP changed
      if ! is_ip "$core_ip_now" || (is_ip "$CLS_WG_SERVER_IP" && [ "$core_ip_now" != "$CLS_WG_SERVER_IP" ]); then
        ping -c5 "$CLS_WG_SERVER" >/dev/null || break
      fi
    fi

    if [[ "$CLS_TYPE_NODE" =~ (hub|haas) ]] && [ -n "$CLS_DYN_DNS" ] && [ -n "$CLS_GATEWAY" ]; then
      ping -c5 "$CLS_GATEWAY" >/dev/null || break
    fi

    sleep 5
  done

  exec sudo bash restart.sh ${@@Q}
) &

if $CLS_DOCKER; then
  sudo systemctl stop isc-dhcp-server
  # prod starts wg
  if ! ip a show "$CLS_INTERN_IFACE" | grep -q UP; then
    sudo systemctl restart docker
    sudo docker network prune -f
    sudo docker compose --profile prod up -d --force-recreate --remove-orphans
  elif ! sudo docker ps | grep -qE "wireguard.*Up"; then
    sudo docker compose --profile prod up -d --force-recreate --remove-orphans
    sudo docker compose up -d wireguard
  fi
else
  bash wireguard/etc/run
  sudo mkdir -p /etc/wireguard
  sudo ln -f wireguard/config/wg_confs/"$CLS_INTERN_IFACE".conf /etc/wireguard/"$CLS_INTERN_IFACE".conf
  sudo wg-quick up "$CLS_INTERN_IFACE"
fi

# Lower the drawbridges
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv6.conf.all.forwarding=1

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
sudo docker ps | grep -qE "pihole.*Up" && sudo docker ps | grep -qE "unbound.*Up" && echo -e "nameserver 127.0.0.1\nsearch $CLS_DOMAIN" | sudo tee /etc/resolv.conf.bak >/dev/null || :
sudo cp -f /etc/resolv.conf.bak /etc/resolv.conf

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

sudo bash hooks/post-up.sh ${@@Q}
popd || exit
