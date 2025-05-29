#!/bin/bash
# shellcheck disable=SC1091

export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
this_dir=$(dirname "$(readlink -f "$0")")
pushd "$this_dir" || exit 1
source "lib.sh"
direct_domain "wget --no-check-certificate -O - $CLS_DYN_DNS"
popd || exit 1
