#!/bin/bash
# shellcheck disable=SC1091,SC2015

this_dir=$(dirname "$(readlink -f "$0")")
pushd "$this_dir" || exit 1
source "lib.sh"

# shellcheck disable=SC2009
ps -aux | grep -P "^[^-]+$this_dir/start.sh" | awk '{print $2}' | while read -r pid; do [ "$pid" = "$$" ] || sudo kill -9 "$pid" &>/dev/null; done
sudo systemctl enable --now docker

for table in nat filter; do
  for chain in DOCKER DOCKER-ISOLATION-STAGE-1 DOCKER-ISOLATION-STAGE-2; do
    sudo iptables -L -t "$table" | grep -q "$chain" || sudo iptables -N "$chain" -t "$table"
    sudo ip6tables -L -t "$table" | grep -q "$chain" || sudo ip6tables -N "$chain" -t "$table"
  done
done

sudo bash hooks/pre-up.sh "$@"

(
  until ip a show "$CLS_INTERN_IFACE" | grep -q UP; do sleep 1; done
  (
    while ip a show "$CLS_INTERN_IFACE" | grep -q UP; do
      if [ -n "$CLS_EXTERN_IFACE" ] && [[ "$CLS_TYPE_NODE" =~ (hub|saah) ]] && ip a show "$CLS_EXTERN_IFACE" | grep -q UP; then
        until sudo wg | grep -q endpoint; do sleep 1; done

        while sudo wg | grep -q endpoint; do
          sudo wg | grep -oE 'endpoint: [^:]+' | grep -oE '\S+$' | while read -r endpoint; do
            route -n | grep -q "$endpoint" || sudo route add -net "$endpoint" netmask 255.255.255.255 gw "$(ip r | grep -oP 'default via \K\S+')" &>/dev/null
          done
          sleep 5
        done
      fi
      sleep 5
    done
  ) &

  core_ip=$(dig +short "$SERVERURL")

  while ip a show "$CLS_INTERN_IFACE" | grep -q UP; do
    if [[ "$CLS_TYPE_NODE" =~ (spoke|saah) ]] && [[ "$SERVERURL" =~ \. ]] && ! [[ "$SERVERURL" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      core_ip_now=$(dig +short "$SERVERURL") && [ -n "$core_ip_now" ] && [ "$core_ip_now" != "$core_ip" ] && exec sudo bash restart.sh "$CLS_ACTIVE_USER" "$1" || :
      sudo wg | grep -q handshake && ! nmap -sn "$(cut -d. -f1-3 <<<"$INTERNAL_SUBNET").*" | grep -q 'Host is up' && exec sudo bash restart.sh "$CLS_ACTIVE_USER" "$1" || :
    fi

    route_wg
    sleep 5
  done

  exec sudo bash restart.sh "$CLS_ACTIVE_USER" "$1"
) &

if $CLS_DOCKER; then
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
  sudo ln -f wireguard/config/wg_confs/"$CLS_INTERN_IFACE".conf /etc/wireguard/"$CLS_INTERN_IFACE".conf
  sudo wg-quick up "$CLS_INTERN_IFACE"
fi

# add hotspot
set_netplan closed

# Lower the drawbridges
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

sudo bash hooks/post-up.sh "$@"
popd || exit
