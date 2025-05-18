<div align="center">

# Cl<img src=closure.png height="19" width="19" style="top: .025em;position: relative;" alt="o">sure

<strong>Complex? Simplicial.</strong>

---

[![build](https://github.com/ipitio/closure/actions/workflows/release.yml/badge.svg)](https://github.com/ipitio/closure/pkgs/container/closure)

</div>

Provision a fresh Ubuntu install as a Hub, Spoke, or hybrid of both!

You can run WireGuard with Docker or on the host. If you run it with Docker (available for armv7+ and amd64), you'll also get Unbound and Pi-hole v5, which will come with [pihole-speedtest](https://github.com/arevindh/pihole-speedtest) and [pihole-updatelists](https://github.com/jacklul/pihole-updatelists). In either case, Kodi will be installed with the Jellyfin add-on source, for your convenience. You can also choose between Netplan and hostapd for your access point needs.

## Getting Started

Just edit some variables and go!

### Definitions

One of the variables you'll set in `env.sh` will be `CLS_TYPE_NODE`, which is the type of node you're setting up. The options are:

- **Hub**: A WireGuard server through which peers can route traffic. It just listens for incoming connections.
- **Spoke**: A WireGuard client that connects, and can route traffic, to a Hub or HaaS.
- **HaaS**: A special Hub that routes traffic to a special Spoke, a SaaH.
- **SaaH**: A WireGuard client through which a HaaS routes traffic. It initiates the connection to a HaaS.

A SaaH-HaaS[-Spoke] topology may be useful when you can't forward the WireGuard port at the location you'd like to have a Hub, but can where you'd otherwise have a stationary, always-on Spoke. While a Spoke can route traffic to a Hub or HaaS, a HaaS can only route traffic to a SaaH.

### Configuration

When completing step 2 below, move everything in `examples/` out to the parent directory. The files to edit are:

- `dhcp/*dhcp*`: DHCP config, if you want to use the node as a DHCP server without Pi-hole
- `netplan.yml`: primary network config
- `env.sh`: environment variables for the scripts
- `compose.yml`: environment variables for the services and bare WireGuard
- `hooks/{pre,post}-{up,down}.sh`: scripts that run from the active user's home directory before and after everything is started or stopped
- `hostapd/*.conf`: hostapd configs for your non-netplan APs, for more control and AP+STA mode support

Keep in mind that:

- The default DHCP config doesn't enable it.
- Unbound connects to Cloudflare's servers using DoT by default, but you can uncomment its volume in `compose.yml` to use it as a recursive resolver.
- To configure Pi-hole more extensively, such as by enabling DHCP, see the [Pi-hole documentation](https://github.com/pi-hole/docker-pi-hole/tree/2024.07.0?tab=readme-ov-file#environment-variables).
- The hooks may be useful, for example, if you'd like to coordinate with an external, outbound VPN on a Hub or SaaH. All arguments given to `start.sh`and `stop.sh` are passed to their respective hooks.

To customize iptables, modify the relevant lines in `start.sh` and `stop.sh`.

> [!WARNING]
> The WireGuard service in the Compose file must be configured whether or not you'll use Docker ([docs](https://docs.linuxserver.io/images/docker-wireguard)).

> [!CAUTION]
> If a user you specify in `env.sh` doesn't exist, it will be created. By default, the password will be the same as the username; change it!

### Deployment

Create or update a node in two or three steps:

1. Move this repo to the target or install the [package](https://github.com/ipitio/closure/releases):

```{bash}
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq gpg wget
sudo mkdir -m 0755 -p /etc/apt/keyrings/
wget -qO- https://ipitio.github.io/closure/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/closure.gpg > /dev/null
sudo chmod 644 /etc/apt/keyrings/closure.gpg
echo "deb [signed-by=/etc/apt/keyrings/closure.gpg] https://ipitio.github.io/closure master main" | sudo tee /etc/apt/sources.list.d/closure.list
sudo chmod 644 /etc/apt/sources.list.d/closure.list
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -qq closure
```

2. Edit the files above (in `/opt/closure` if you installed the package). If you didn't install the package, change the path in `rc.local` and move it to `/etc`. Ensure the target is connected to the internet and reboot.
3. On a Hub or HaaS, add a Spoke or SaaH peer by running `add.sh` (as described below). Then, for a SaaH, add an `SERVER_ALLOWEDIPS_PEER_[SaaH]=` environment variable -- using the peer's name sans the brackets -- for the wireguard service with the difference of `0.0.0.0/1,128.0.0.0/1,::/1,8000::/1` and the peer's IP, and run `sudo kickstart.sh`. This [AllowedIPs Calculator](https://www.procustodibus.com/blog/2021/03/wireguard-allowedips-calculator) is pretty nifty. Follow a similar process for a Spoke, if needed.

Set a Hub or HaaS up first, so you can generate the necessary peer configuration for a Spoke or SaaH, then drop it in the Spoke's or SaaH's `wireguard/config/wg_confs` directory before their reboot.

> [!NOTE]
> Any arguments passed to `kickstart.sh` are passed to `init.sh` and `start.sh`, and `init.sh` can add or edit wifi networks -- useful on a Raspberry Pi Zero (2) W! See the top of `init.sh` for the arguments it takes.

> [!IMPORTANT]
> Remember to forward a port to your Hub or HaaS, which listens on 51820 by default. Use 443 on your router to bypass some basic firewall filters.

### Maintenance

You can (re)configure WireGuard peers (on bare metal as well, thanks to code shared by [LinuxServer.io](https://github.com/linuxserver/docker-wireguard)):

- Add WireGuard peers, or modify the AllowedIPs of existing ones, with `sudo bash wireguard/add.sh <peer_name> [option]`.
- Show peer config QR codes with `sudo bash wireguard/get.sh <peer_name>`.
- Delete peers with `sudo bash wireguard/del.sh <peer_name>`.

By default, `add.sh` sets the peer to route outgoing traffic through the VPN. You can change this default by modifying AllowedIPs in `compose.yml`. The option it takes may be one of:

```{bash}
-e, --internet    Route all traffic through the VPN
-a, --intranet    Allow access to the internal space
-l, --link        Allow access to just the VPN
-o, --outgoing    Route outgoing traffic through the VPN
```

While `start.sh` brings everything up, `stop.sh` only stops WireGuard. `restart.sh` simply calls these two scripts, passing all of its arguments to them. Therefore, when stopping, if you're using Docker, you must also run `sudo docker compose down` to bring the other services down. Happy stargazing!

> [!TIP]
> Don't forget to share an updated config with its peer.
