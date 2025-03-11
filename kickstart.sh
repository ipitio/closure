#!/bin/bash

# these will be automatically set by the init script
script_user=ubuntu
script_path=~/server

sudo -i -u "$script_user" bash <<EOF
pushd "$script_path" || exit 1
bash init.sh
bash start.sh "$@"
popd || exit 1
EOF
