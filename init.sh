#!/bin/bash
# shellcheck disable=SC1091,SC2015

pushd "$(dirname "$(readlink -f "$0")")" || exit 1
source "lib.sh"

# Free port 53 on Ubuntu for Pi-hole
sudo sed -i 's/#\?DNSStubListener=.*/DNSStubListener=no/g' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
sudo cp -f /run/systemd/resolve/resolv.conf /etc/resolv.conf
grep -q '^nameserver 1\.1\.1\.1$' /etc/resolv.conf.bak || echo -e "nameserver 1.1.1.1\n$(cat /etc/resolv.conf)" | sudo tee /etc/resolv.conf.bak >/dev/null
sudo cp -f /etc/resolv.conf /etc/resolv.conf.orig
sudo cp -f /etc/resolv.conf.bak /etc/resolv.conf

apt_install() {
  if ! dpkg -l "$@" >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y "$@"
  fi
}

# install deps, installed manually: openssh-server
if ! dpkg -l apt-fast >/dev/null 2>&1; then
  sudo add-apt-repository -y ppa:apt-fast/stable
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y apt-fast
fi

if ! dpkg -l docker-ce >/dev/null 2>&1; then
  # Add Docker's official GPG key:
  apt_install ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  # Add the repository to Apt sources:
  # shellcheck disable=SC1091
  echo \
    "deb [trusted=yes arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" |
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
fi

[ ! -f /etc/apt/preferences.d/nosnap.pref ] || sudo mv /etc/apt/preferences.d/nosnap.pref /etc/apt/preferences.d/nosnap.pref.bak
sudo systemctl disable --now whoopsie.path &>/dev/null
sudo systemctl mask whoopsie.path &>/dev/null
sudo apt-get purge -y ubuntu-report popularity-contest apport whoopsie
apt_install byobu docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin iperf3 iw net-tools nmap qrencode snapd traceroute tmux wireguard wmctrl
sudo apt autoremove -y

echo "[connection]
# Values are 0 (use default), 1 (ignore/don't touch), 2 (disable) or 3 (enable).
wifi.powersave = 2
" | sudo tee /etc/NetworkManager/conf.d/wifi-powersave.conf >/dev/null
sudo cp -f /etc/NetworkManager/conf.d/wifi-powersave.conf /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf

if grep -q Raspberry /proc/device-tree/model; then

  # wifi 2.4GHz performance
  grep -q dtoverlay=disable-bt /boot/firmware/config.txt || echo "dtoverlay=disable-bt" | sudo tee -a /boot/firmware/config.txt >/dev/null

  if [ ! -f /etc/modprobe.d/brcmfmac.conf ]; then
    # wifi chip bug: https://github.com/raspberrypi/linux/issues/6049#issuecomment-2642566713
    echo "options brcmfmac roamoff=1 feature_disable=0x202000" | sudo tee /etc/modprobe.d/brcmfmac.conf >/dev/null
    sudo systemctl restart systemd-modules-load
  fi
fi

# Configure bridge
sudo mkdir -p /etc/cloud/cloud.cfg.d
sudo touch /etc/cloud/cloud-init.disabled
echo "network: {config: disabled}" | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg >/dev/null
sudo rm -f /etc/netplan/50-cloud-init.yaml
set_netplan open
sudo sed -i "s/uri=.*$/uri=/" /lib/NetworkManager/conf.d/20-connectivity-ubuntu.conf
sudo busctl --system set-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.NetworkManager ConnectivityCheckEnabled "b" 0 2>/dev/null

# Enable IP forwarding
# https://cromwell-intl.com/open-source/performance-tuning/tcp.html
sysctl="
fs.file-max=51200
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.netdev_max_backlog=250000
net.core.somaxconn=4096
net.core.default_qdisc=fq
net.ipv4.ip_forward=1
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=2
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=1200
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_max_tw_buckets=5000
net.ipv4.tcp_mem=25600 51200 102400
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_slow_start_after_idle=1
net.ipv4.conf.all.src_valid_mark=1
net.ipv4.conf.all.proxy_arp=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.all.proxy_ndp=1
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_tcp_timeout_established=86400
"
while IFS= read -r line; do
  grep -qP "^.*$(echo "$line" | cut -d= -f1) ?=.*$" /etc/sysctl.conf && sudo sed -r -i "s/^.*$(echo "$line" | cut -d= -f1) \?=.*$/$line/g" /etc/sysctl.conf || echo "$line" | sudo tee -a /etc/sysctl.conf >/dev/null
done <<<"$sysctl"
grep -E '(#|.+=)' /etc/sysctl.conf | awk '!seen[$0]++' | sudo tee /etc/sysctl.conf >/dev/null
sudo sysctl -p

# Fix IP in Docker
sudo mkdir -p /etc/docker
echo '{
  "ipv6": true,
  "fixed-cidr-v6": "2001:db8:1::/64",
  "userland-proxy": false
}' | sudo tee /etc/docker/daemon.json >/dev/null

(crontab -l 2>/dev/null | grep -Fv "$CLS_DYN_DNS") | crontab -

if [ -n "$CLS_DYN_DNS" ]; then
  if [[ "$CLS_TYPE_NODE" =~ (hub|saah) ]]; then
    if [ -z "$CLS_EXTERN_IFACE" ] && ! crontab -l 2>/dev/null | grep -Fq "ddns.log"; then
      (
        crontab -l 2>/dev/null
        echo "0,5,10,15,20,25,30,35,40,45,50,55 * * * * /usr/bin/sleep 10 ; /usr/bin/wget --no-check-certificate -O - $CLS_DYN_DNS >> /tmp/ddns.log 2>&1 &"
      ) | crontab -
    fi

    ip a show "$CLS_EXTERN_IFACE" | grep -q UP || wget --no-check-certificate -O - "$CLS_DYN_DNS"
  else
    ip a show "$CLS_INTERN_IFACE" | grep -q UP || wget --no-check-certificate -O - "$CLS_DYN_DNS"
  fi
fi

if $CLS_DOCKER; then
  sudo docker compose build
fi

# Verbose boot
if grep -q "quiet splash" /etc/default/grub; then
  sudo sed -i 's/quiet splash//g' /etc/default/grub
  sudo update-grub
fi

# Autologin on boot
if grep -q gdm3 /etc/X11/default-display-manager; then
  sudo sed -i "/AutomaticLogin\(Enable\)*=.*/d; /\[daemon\]/a AutomaticLoginEnable=true\nAutomaticLogin=$CLS_ACTIVE_USER" /etc/gdm3/custom.conf
elif grep -q lightdm /etc/X11/default-display-manager; then
  echo -e "[Seat:*]\nautologin-guest=false\nautologin-user=$CLS_ACTIVE_USER\nautologin-user-timeout=0\n" | sudo tee /etc/lightdm/lightdm.conf >/dev/null
elif grep -q sddm /etc/X11/default-display-manager; then
  sed -i '/\[Autologin\]/,/^$/d' /etc/sddm.conf
  echo -e "[Autologin]\nUser=$CLS_ACTIVE_USER\n\n" | sudo tee -a /etc/sddm.conf >/dev/null
else
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  echo "[Service]
ExecStart=
ExecStart=-/sbin/agetty --noissue --autologin $CLS_ACTIVE_USER %I $TERM
Type=idle
" | sudo tee /etc/systemd/system/getty@tty1.service.d/override.conf >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable getty@tty1
fi

# Autostart on login
sed -i "s/script_user=.*$/script_user=$CLS_SCRIPT_USER/" kickstart.sh
sed -i "s/script_path=.*$/script_path=$PWD/" kickstart.sh
active_path=/home/"$CLS_ACTIVE_USER"/kickstart.sh
allow_path="$CLS_ACTIVE_USER$(echo -e '\t')ALL=(ALL) NOPASSWD:$active_path"
sudo cp -f kickstart.sh "$active_path"
sudo chown "$CLS_ACTIVE_USER":"$CLS_ACTIVE_USER" "$active_path"
grep -q "$allow_path" /etc/sudoers || echo "$allow_path" | sudo EDITOR='tee -a' visudo

if grep -qE '(gdm3|lightdm)' /etc/X11/default-display-manager; then
  [ -d /home/"$CLS_ACTIVE_USER"/.config/autostart ] || sudo mkdir -p /home/"$CLS_ACTIVE_USER"/.config/autostart
  echo "[Desktop Entry]
Type=Application
Name=Kickstart
Exec=sudo $active_path $CLS_STARTUP_ARGS
Icon=system-run
X-GNOME-Autostart-enabled=true
" | sudo tee /home/"$CLS_ACTIVE_USER"/.config/autostart/kickstart.desktop >/dev/null
else
  grep -q "sudo $active_path $CLS_STARTUP_ARGS" /home/"$CLS_ACTIVE_USER"/.profile || echo "[ -n $SSH_CLIENT ] || sudo $active_path $CLS_STARTUP_ARGS" | sudo tee -a /home/"$CLS_ACTIVE_USER"/.profile >/dev/null
fi
popd || exit 1
