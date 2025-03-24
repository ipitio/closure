#!/bin/bash

pushd "$(dirname "$(readlink -f "$0")")" || exit 1

if [ -f lib.sh ]; then
    sudo bash init.sh
    sudo bash start.sh "$@"
else
    script_user="$USER"
    script_path="$PWD"

    sudo -i -u "$script_user" bash <<EOF
pushd "$script_path" || exit 1
bash init.sh
bash start.sh "$@"
popd || exit 1
EOF
fi

popd || exit 1
