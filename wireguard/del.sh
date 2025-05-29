#!/bin/bash
# shellcheck disable=SC1091,SC2001,SC2068

[ -n "$1" ] || exit 1
pushd "$(dirname "$(readlink -f "$0")")/.." || exit 1
source "lib.sh"
peers=$(grep -- "- PEERS=" compose.yml)

if grep -q "$1" <<<"$peers"; then
    sed -i "s/$peers/$(sed "s/,\?$1//" <<<"$peers")/" compose.yml
    sudo rm -rf wireguard/config/peer_"$1"
    sudo mv -f wireguard/config/wg_confs/"$CLS_INTERN_IFACE".conf wireguard/config/wg_confs/"$CLS_INTERN_IFACE".conf.bak
    shift
    sudo CLS_WG_ONLY=true bash restart.sh ${@@Q}
fi

popd &>/dev/null || exit
