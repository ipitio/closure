#!/bin/bash
# shellcheck disable=SC1091

[ -n "$1" ] || exit 1
pushd "$(dirname "$(readlink -f "$0")")/.." || exit 1
source "lib.sh"
bash wireguard/app/show-peer "$@"
popd &>/dev/null || exit 1
