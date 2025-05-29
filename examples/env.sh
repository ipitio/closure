#!/bin/bash
# shellcheck disable=SC2034
# Environment Variables for Closure Scripts

# User to automatically log in and run the scripts on boot
CLS_ACTIVE_USER="ubuntu"

# User to run the scripts as
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

# If the current node is a haas, this is the name given, or to give, its saah peer
CLS_SAAH_PEER=""

# DDNS update URL if needed ("https://...")
CLS_DYN_DNS=""

# If true, start entire stack in Docker, else only WireGuard on host
CLS_DOCKER=false

# Should be the same as your network's search domain or REV_SERVER_DOMAIN in the Pi-hole service
CLS_DOMAIN="internal"

# Expected network speed as described here: https://man7.org/linux/man-pages/man8/tc-cake.8.html
CLS_BANDWIDTH=""

# Load "serial", "ether", etc. module, leave empty for host mode
CLS_OTG_g_=""

# If using a wireless interface to connect to the gateway, set its name
CLS_WIFACE=""

# Create hotspot(s) using hostapd, instead of including in netplan, eg. for the STA+AP mode example below
CLS_AP_HOSTAPD=false

# "/" separated list of interfaces to use for the hostapd AP
# Nothing happens if the corresponding config is not found in `hostapd/`
CLS_AP_WIFACES="ap@$CLS_WIFACE"

# "/" separated list of the respective configs in `hostapd/` (without `.conf`) for the above interfaces
# "." means the same as the interface, or the correct `X@[wiface].conf` for an AP@STA
CLS_AP_CONFIGS="."
