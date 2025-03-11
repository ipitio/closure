#!/bin/bash
# shellcheck disable=SC1091,SC2001

pushd "$(dirname "$(readlink -f "$0")")/.." || exit 1
source "lib.sh"

peers=$(grep -- "- PEERS=" compose.yml)

if grep -q "$1" <<<"$peers"; then
    sed -i "s/$peers/$(sed "s/,\?$1//" <<<"$peers")/" compose.yml
    sudo rm -rf wireguard/config/peer_"$1"
    sudo mv -f wireguard/config/wg_confs/wg0.conf wireguard/config/wg_confs/wg0.conf.bak
    sudo docker compose restart wireguard
    sudo docker exec wireguard bash -c "wg-quick down wg0 ; wg-quick up wg0"
    sudo docker compose up -d wireguard
fi

popd &>/dev/null || exit
