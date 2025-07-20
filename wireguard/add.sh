#!/bin/bash
# shellcheck disable=SC1091,SC2001,SC2068

[ -n "$1" ] || exit 1
pushd "$(dirname "$(readlink -f "$0")")/.." || exit 1
source "lib.sh"
option="$2"

if [[ -n "$2" && "$2" == "--" ]]; then
    shift 2
elif [[ "$3" == "--" ]]; then
    shift 3
fi

if ! grep -q "$1" <<<"$PEERS"; then
    new_peers="$PEERS,$1"
    sed -i "s/$PEERS/$new_peers/" compose.yml
    PEERS="$new_peers"
    sudo mv -f wireguard/config/wg_confs/"$CLS_INTERN_IFACE".conf wireguard/config/wg_confs/"$CLS_INTERN_IFACE".conf.bak

    if [ "$CLS_DOCKER" = "true" ]; then
        export CLS_WG_ONLY=true
        sudo bash restart.sh ${@@Q} 2>/dev/null
    else
        bash wireguard/etc/run
    fi
fi

peer_dir=wireguard/config/peer_"$1"
until [ -d "$peer_dir" ]; do sleep 1; done
sudo chmod -R 777 "$peer_dir"
path="$peer_dir/peer_$1"
conf=$(cat "$path.conf")

case $option in
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
    echo "Usage: ./add.sh <peer_name> [option] [-- args]
 By default, sets a non/saah peer to route inter/intra -net traffic through the VPN (change non-saah default with AllowedIPs in compose.yml).
 Any args are passed to restart.sh.
 Options:
   -e, --internet    Route all traffic through the VPN
   -a, --intranet    Allow access to the internal space
   -l, --link        Allow access to the just the VPN
   -o, --outgoing    Route outgoing traffic through the VPN"
    ;;
*)
    [ "$1" = "$CLS_SAAH_PEER" ] && conf=$(sed "s@AllowedIPs.*@AllowedIPs = 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,::/0@" <<<"$conf") || conf=$(sed "s@AllowedIPs.*@AllowedIPs = $ALLOWEDIPS@" <<<"$conf")
    ;;
esac

echo "$conf" | sudo tee "$path.conf" >/dev/null || exit 1
CLS_WG_ONLY=true
sudo bash restart.sh ${@@Q} 2>/dev/null
popd &>/dev/null || exit 1
