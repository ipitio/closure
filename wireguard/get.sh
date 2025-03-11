#!/bin/bash
# shellcheck disable=SC1091

pushd "$(dirname "$(readlink -f "$0")")/.." || exit 1
source "lib.sh"

bash wireguard/app/show-peer "$@"
