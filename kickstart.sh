#!/bin/bash
# shellcheck disable=SC2068

pushd "$(dirname "$(readlink -f "$0")")" || exit 1

if [ -f lib.sh ]; then
    sudo bash init.sh ${@@Q}
    sudo bash start.sh ${@@Q}
else
    script_path="$PWD"
    sudo -i bash <<EOF
pushd "$script_path" || exit 1
sudo bash init.sh ${@@Q}
sudo bash start.sh ${@@Q}
popd || exit 1
EOF
fi

popd || exit 1
