<div align="center">

# Cl<img src=closure.png height="19" width="19" style="top: .025em;position: relative;" alt="o">sure

<strong>Complex? Simplicial.</strong>

---

[![build](https://github.com/ipitio/closure/actions/workflows/release.yml/badge.svg)](https://github.com/ipitio/closure/releases/latest)

</div>

Provision a fresh Ubuntu install as a Hub, Spoke, or hybrid of both!

You can run WireGuard with Docker or on the host. If you run it with Docker (beta, available for armv7+ and amd64), you'll also get Unbound and Pi-hole v5, which will come with [pihole-speedtest](https://github.com/arevindh/pihole-speedtest) and [pihole-updatelists](https://github.com/jacklul/pihole-updatelists). In either case, Kodi will be installed with the Jellyfin add-on source, for your convenience. You can also choose between Netplan and hostapd for your access point needs.

## Getting Started

Install. Configure. Reboot.

### Definitions

One of the variables you'll set in `env.sh` will be `CLS_TYPE_NODE`, which is the type of node you're setting up. The options are:

- **Hub**: A WireGuard server through which peers can route traffic. It just listens for incoming connections.
- **Spoke**: A WireGuard client that connects, and can route traffic, to a Hub or HaaS.
- **HaaS**: A special Hub that routes traffic to a special Spoke, a SaaH.
- **SaaH**: A WireGuard client through which a HaaS routes traffic. It initiates the connection to a HaaS.

A SaaH-HaaS[-Spoke] topology may be useful when you can't forward the WireGuard port at the location you'd like to have a Hub, but can where you'd otherwise have a stationary, always-on Spoke. While a Spoke can route traffic to a Hub or HaaS, a HaaS can only route traffic to a SaaH.

> [!NOTE]
> If your Hub or HaaS is behind a dynamic public IP address, sign up for a DDNS provider like freedns.afraid.org and set `CLS_DYN_DNS` to the update URL.

> [!CAUTION]
> If you use freeDNS, or another provider with a similar option, unlink updates of the same IP address.

### Configuration

When completing step 2 below, move everything in `examples/` out to the parent directory first. The files to edit are:

- `dhcp/*dhcp*`: optional DHCP server config, if you don't want to use Pi-hole for that
- `resolv.conf`: optional DNS client config
- `netplan.yml`: primary network config
- `env.sh`: environment variables for the scripts
- `compose.yml`: environment variables for the services and bare WireGuard
- `hooks/{pre,post}-{up,down}.sh`: scripts that run from the active user's home directory before and after everything is started or stopped, respectively
- `hostapd/*.conf`: hostapd configs for your non-netplan APs, for more control and AP+STA mode support

Keep in mind that:

- The default DHCP config doesn't enable it.
- Unbound connects to Cloudflare's servers using DoT by default, but you can uncomment its volume in `compose.yml` to use it as a recursive resolver.
- To configure Pi-hole more extensively, such as by enabling DHCP, see the [Pi-hole documentation](https://github.com/pi-hole/docker-pi-hole/tree/2024.07.0?tab=readme-ov-file#environment-variables).
- The hooks may be useful, for example, if you'd like to coordinate with an external, outbound VPN on a Hub or SaaH. All arguments given to `start.sh`and `stop.sh` are passed to their respective hooks.
- For AP+STA mode, you can define as many `X@[iface].conf` files as bands the device supports, where X is an integer band.

> [!NOTE]
> The WireGuard service in the Compose file must be configured whether or not you'll use Docker ([docs](https://docs.linuxserver.io/images/docker-wireguard)).

> [!WARNING]
> If a user you specify in `env.sh` doesn't exist, it will be created. By default, the password will be the same as the username; change it!

### Deployment

Create a node in two or three steps (or update in one). The initial reboot, as well as those after upgrading, may take a while as everything is set up, but the subsequent ones will be much faster. For example, the SaaH peer will be created on a HaaS if it doesn't exist. This means that you should set a Hub or HaaS up first, so SaaH and Spoke peer configurations can be generated. Drop those in their `wireguard/config/wg_confs` directories before rebooting. This [AllowedIPs Calculator](https://www.procustodibus.com/blog/2021/03/wireguard-allowedips-calculator) is pretty nifty, if you need it.

1. Install or update the package by either:
    - pasting the one-liner or block below;
    - downloading it from [Releases](https://github.com/ipitio/closure/releases); or
    - copying this repo to `/opt/closure`.

If you're installing on top of an existing configuration with one of the first two options, or updating by running `sudo apt upgrade -y closure`, `rc.local` will be copied for you; skip step 2 and reboot after this step.

```{bash}
curl -sSLNZ https://ipitio.github.io/closure/i | sudo bash
```

```{bash}
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq gpg wget
sudo mkdir -m 0755 -p /etc/apt/keyrings/
wget -qO- https://ipitio.github.io/closure/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/closure.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/closure.gpg] https://ipitio.github.io/closure master main" | sudo tee /etc/apt/sources.list.d/closure.list &>/dev/null
sudo chmod 644 /etc/apt/keyrings/closure.gpg
sudo chmod 644 /etc/apt/sources.list.d/closure.list
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -qq closure
```

2. Edit the files above, copy `rc.local` to `/etc`, and reboot.
3. On a Hub or HaaS, add Spokes you didn't define yet by running `add.sh` as described below.

> [!NOTE]
> Any arguments passed to `kickstart.sh` are passed to `start.sh`, which can add or edit wifi networks -- useful on a Raspberry Pi Zero (2) W! See the top of `start.sh` for the arguments it takes.

> [!IMPORTANT]
> Remember to forward a port to your Hub or HaaS, which listens on 51820 by default. Use 443 on your router to bypass some basic firewall filters.

### Maintenance

You can (re)configure WireGuard peers; add WireGuard peers or modify the AllowedIPs of existing ones, show peer config QR codes, and delete peers with:

```{bash}
sudo bash wireguard/add.sh <peer_name> [option] [-- args]
sudo bash wireguard/get.sh <peer_name>
sudo bash wireguard/del.sh <peer_name> [args]
```

By default, `add.sh` sets the peer to route outgoing traffic through the VPN. You can change this default by modifying AllowedIPs in `compose.yml`. The option it takes may be one of:

```{bash}
-e, --internet    Route all traffic through the VPN
-a, --intranet    Allow access to the internal space
-l, --link        Allow access to just the VPN
-o, --outgoing    Route outgoing traffic through the VPN
```

The args are passed to `re/start.sh`.

> [!NOTE]
> While `start.sh` brings everything up, `restart.sh` only restarts WireGuard unless `CLS_WG_ONLY=false` is exported first.

> [!TIP]
> Don't forget to share an updated config with its peer.
