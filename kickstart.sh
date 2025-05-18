#!/bin/bash
# shellcheck disable=SC2068

script_path="$(dirname "$(readlink -f "$0")")"
sudo -i bash <<EOF
pushd "$script_path" || exit 1
sudo bash start.sh ${@@Q} > ks.log
popd || exit 1
EOF
