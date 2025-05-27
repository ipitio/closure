#!/bin/bash
# shellcheck disable=SC1091,SC2001

pushd "$(dirname "$(readlink -f "$0")")/.." || exit 1
source "lib.sh"

if ! grep -q "$1" <<<"$PEERS"; then
    new_peers="$PEERS,$1"
    sed -i "s/$PEERS/$new_peers/" compose.yml
    PEERS="$new_peers"
    sudo mv -f wireguard/config/wg_confs/"$CLS_INTERN_IFACE".conf wireguard/config/wg_confs/"$CLS_INTERN_IFACE".conf.bak

    if $CLS_DOCKER; then
        sudo docker compose restart wireguard
    else
        bash wireguard/etc/run
    fi
fi

peer_dir=wireguard/config/peer_"$1"
until [ -d "$peer_dir" ]; do sleep 1; done
sudo chmod -R 777 "$peer_dir"
path="$peer_dir/peer_$1"
conf=$(cat "$path.conf")

case $2 in
-a | --intranet)
    conf=$(sed "s@AllowedIPs.*@AllowedIPs = 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,::/0@" <<<"$conf")
    ;;
-l | --link)
    conf=$(sed "s@AllowedIPs.*@AllowedIPs = 10.13.13.0/24,::/0@" <<<"$conf")
    ;;
-e | --internet)
    conf=$(sed "s@AllowedIPs.*@AllowedIPs = 0.0.0.0/0,::/0@" <<<"$conf")
    ;;
-o | --outgoing)
    conf=$(sed "s@AllowedIPs.*@AllowedIPs = 0.0.0.0/1,128.0.0.0/1,::/1,8000::/1@" <<<"$conf")
    ;;
-h | --help)
    echo "Usage: ./add.sh <peer_name> [option]
 By default, sets the peer to route outgoing traffic through the VPN (change default with AllowedIPs in compose.yml)
 Options:
   -e, --internet    Route all traffic through the VPN
   -a, --intranet    Allow access to the internal space
   -l, --link        Allow access to the just the VPN
   -o, --outgoing    Route outgoing traffic through the VPN"
    ;;
*)
    conf=$(sed "s@AllowedIPs.*@AllowedIPs = $ALLOWEDIPS@" <<<"$conf")
    ;;
esac

echo "$conf" >"$path.conf"

if $CLS_DOCKER; then
    sudo docker compose restart wireguard
    sudo docker exec wireguard bash -c "wg-quick down wg0 ; wg-quick up wg0"
    sudo docker compose up -d wireguard
else
    sudo wg-quick down "$CLS_INTERN_IFACE" ; sudo wg-quick up "$CLS_INTERN_IFACE"
fi

popd &>/dev/null || exit
