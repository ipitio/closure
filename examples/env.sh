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

# DDNS update URL if needed
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
CLS_AP_WIFACES="ap@$CLS_WIFACE"

# "/" separated list of names of the respective configs in `hostapd/` for the above interfaces
CLS_AP_CONFIGS="ap@"
