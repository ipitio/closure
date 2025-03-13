#!/bin/bash
# shellcheck disable=SC2034
# Environment Variables for Closure Scripts

# User to automatically log in and run the scripts on boot
CLS_ACTIVE_USER="ubuntu"

# User under which to store the scripts
CLS_SCRIPT_USER="ubuntu"

# Args to pass to the scripts on boot
CLS_STARTUP_ARGS=""

# Leave empty if not forwarding traffic to an external gateway
CLS_EXTERN_IFACE=""

# This is used to flush the nat chain, which is probably for DNS
CLS_EXTERN_CHAIN=""

# WireGuard interface name
CLS_INTERN_IFACE="wg0"

# TYPES: hub, spoke, haas, saah
CLS_TYPE_NODE=""

# DDNS update URL if needed
CLS_DYN_DNS=""

# If true, start entire stack in Docker, else only WireGuard on host
CLS_DOCKER=false

# Should be the same as your network's search domain or REV_SERVER_DOMAIN in the Pi-hole service
CLS_DOMAIN="internal"

# Expected network speed as described here: https://man7.org/linux/man-pages/man8/tc-cake.8.html
CLS_BANDWIDTH=""
