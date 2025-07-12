#!/bin/bash
# shellcheck disable=SC2068

script_path="$(dirname "$(readlink -f "$0")")"
sudo -i bash <<EOF
pushd "$script_path" || exit 1
CLS_WG_ONLY=${CLS_WG_ONLY:-false} bash start.sh ${@@Q} &>start.log
popd || exit 1
EOF
