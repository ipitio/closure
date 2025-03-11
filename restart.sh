#!/bin/bash

pushd "$(dirname "$(readlink -f "$0")")" || exit 1
sudo bash stop.sh "$@"
sudo bash kickstart.sh "$@"
popd || exit 1
