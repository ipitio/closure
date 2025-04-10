#!/bin/bash
# shellcheck disable=SC2068

pushd "$(dirname "$(readlink -f "$0")")" || exit 1
sudo bash stop.sh ${@@Q}
sudo bash kickstart.sh ${@@Q}
popd || exit 1
