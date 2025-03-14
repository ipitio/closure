<div align="center">

# Cl<img src=closure.png height="19" width="19" style="top: .025em;position: relative;">sure

<strong>Complex? Simplicial.</strong>

</div>

---

Provision a fresh Ubuntu install as a Hub, Spoke, or hybrid of both! Ubuntu can be installed on a removable medium, or should already have openssh-server or git configured, so that there's a means of getting these files onto it.

You can run the entire stack as Docker services or just WireGuard on the host. If you run it with Docker, you'll also get Unbound and Pi-hole v5, which will come with [pihole-speedtest](https://github.com/arevindh/pihole-speedtest) and [pihole-updatelists](https://github.com/jacklul/pihole-updatelists).

If you have an Arm machine, it unfortunately may not be able to run the entire stack with these scripts since the images weren't built for your architecture. This means it might not make for a very good Hub, unless you set those things up yourself, but it'll work fine as a node otherwise!

## Getting Started

All you have to do to set a node up is fork and/or clone this repo, edit some variables, move the project directory to the target filesystem however you fancy, and run the kickstart script.

### Definitions

One of the variables you'll set in `env.sh` will be `CLS_TYPE_NODE`, which is the type of node you're setting up. The options are:

- **Hub**: A WireGuard server through which peers can route traffic. It just listens for incoming connections.
- **Spoke**: A WireGuard client that connects, and can route traffic, to a Hub or HaaS.
- **HaaS**: A special Hub that routes traffic to a special Spoke, a SaaH.
- **SaaH**: A WireGuard client through which a HaaS routes traffic. It initiates the connection to a HaaS.

A SaaH-HaaS[-Spoke] topology may be useful when you can't forward the WireGuard port at the location you'd like to have a Hub, but can where you'd otherwise have a stationary, always-on Spoke.

> [!NOTE]
> While a Spoke can route traffic to a Hub or HaaS, a HaaS can only route traffic to a SaaH.

### Configuration

The files to edit are:

- `netplan/{open,closed}.yml`: network config when the VPN is down or up, respectively
- `env.sh`: environment variables for the scripts
- `compose.yml`: environment variables for the services and bare WireGuard
- `hooks/{pre,post}-{up,down}.sh`: scripts that run from the project directory before and after everything is started or stopped

Keep in mind that:

- The netplan files may be different from each other, for example, if you want a Spoke or HaaS to act as an AP only when the VPN is up. Otherwise, they can be the same.
- Unbound connects to Cloudflare's servers using DoT by default, but you can uncomment its volume in `compose.yml` to use it as a recursive resolver.
- To configure Pi-hole more extensively, such as by enabling DHCP, see the [Pi-hole documentation](https://github.com/pi-hole/docker-pi-hole/tree/2024.07.0?tab=readme-ov-file#environment-variables).
- The hooks may be useful, for example, if you'd like to coordinate with an external, outbound VPN on a Hub or SaaH. All arguments given to `start.sh`and `stop.sh` are passed to their respective hooks.

> [!WARNING]
> The WireGuard service in the Compose file must be configured whether or not you'll use Docker ([docs](https://docs.linuxserver.io/images/docker-wireguard)).

### Deployment

Set a node up in two or three steps:

1. Move this directory to the target in any way you like, after modifying the files above.
2. Spin everything up by running, from the directory:

```{bash}
sudo bash init.sh
sudo bash start.sh
```

3. On a Hub or HaaS, add a Spoke or SaaH peer.

Set a Hub or HaaS up first, so you can generate the necessary peer configuration for a Spoke or SaaH. Drop that configuration in the Spoke's or SaaH's `wireguard/config/wg_confs` directory as part of its Step 1

To finish adding the SaaH peer to a HaaS, run `add.sh` (as described below) for it, after step 3, with `-a` to correctly set the peer's AllowedIPs. Then add an `SERVER_ALLOWEDIPS_PEER_[SaaH]=` environment variable -- using the peer's name sans the brackets -- for the wireguard service with the difference of `0.0.0.0/1,128.0.0.0/1,::/1,8000::/1` minus the peer's IP and run `sudo bash restart.sh`. This [AllowedIPs Calculator](https://www.procustodibus.com/blog/2021/03/wireguard-allowedips-calculator) is pretty nifty.

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
-l, --link        Allow access to the just the VPN
-o, --outgoing    Route outgoing traffic through the VPN
```

While `start.sh` brings everything up, `stop.sh` only stops WireGuard. `restart.sh` simply calls these two scripts, passing all of its arguments to them. Therefore, when stopping, if you're using Docker, you must also run `sudo docker compose down` to bring the other services down. Happy stargazing!

> [!TIP]
> Don't forget to share an updated config with its peer.
