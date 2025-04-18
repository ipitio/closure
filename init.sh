#!/bin/bash
# shellcheck disable=SC1091,SC2009,SC2015

WIFI="$1"   # string: name, SSID of the wifi to connect to
PORTAL=$2   # bool: true/false, whether wifi uses a captive portal
MAC="$3"    # string: MAC address of a device previously connected to the wifi, used if $PORTAL is true
PASSWD="$4" # string: password of the wifi, if it has one

this_dir=$(dirname "$(readlink -f "$0")")
pushd "$this_dir" || exit 1
pids=$(ps -o ppid=$$)
ps -aux | grep -P "^[^-]+$this_dir/init.sh" | awk '{print $2}' | while read -r pid; do grep -q "$pid" <<<"$pids" || sudo kill -9 "$pid" &>/dev/null; done
mv -n examples/* . 2>/dev/null
rmdir examples 2>/dev/null

sudo() {
  if command -v sudo >/dev/null; then
    command sudo "$@"
  else
    "$@"
  fi
}

apt_install() {
  if ! dpkg -l "$@" >/dev/null 2>&1; then
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq "$@"
  fi
}

if ! dpkg -l apt-fast >/dev/null 2>&1; then
  sudo add-apt-repository -y ppa:apt-fast/stable
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq apt-fast
fi

if ! dpkg -l docker-ce >/dev/null 2>&1; then
  apt_install ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo \
    "deb [trusted=yes arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" |
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
fi

[ ! -f /etc/apt/preferences.d/nosnap.pref ] || sudo mv /etc/apt/preferences.d/nosnap.pref /etc/apt/preferences.d/nosnap.pref.bak
sudo systemctl disable --now whoopsie.path &>/dev/null
sudo systemctl mask whoopsie.path &>/dev/null
sudo apt-get purge -y ubuntu-report popularity-contest apport whoopsie
# shellcheck disable=SC2046
apt_install $(grep -oP '((?<=^Depends: )|(?<=^Recommends: )).*' DEBIAN/control | tr -d ',' | tr '\n' ' ')
sudo apt autoremove -y
yq -V | grep -q mikefarah 2>/dev/null || {
  [ ! -f /usr/bin/yq ] || sudo mv -f /usr/bin/yq /usr/bin/yq.bak
  arch=$(uname -m)
  [ "$arch" = "x86_64" ] && arch="amd64"
  [ "$arch" = "aarch64" ] && arch="arm64"
  [ "$arch" = "armv7l" ] && arch="armhf"
  [ "$arch" = "armhf" ] && arch="arm"
  [ "$arch" = "i686" ] && arch="386"
  [ "$arch" = "i386" ] && arch="386"
  sudo curl -LNZo /usr/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_"$arch"
  sudo chmod +x /usr/bin/yq
}
source "lib.sh"

# WIFI being set means that's where the gateway is, and the other args have also been set
# Ensure the first wifi interface in netplan is the one we want connected to the gateway
mkdir config
[ -f config/wifis.json ] || echo "{}" >config/wifis.json
if [ -n "$WIFI" ]; then
  ! $PORTAL || jq "(. | select(\"$WIFI\") | .$WIFI) = \"$MAC\"" config/wifis.json | sudo tee config/wifis.json
  [ -n "$PASSWD" ] && yq -i ".network.wifis.$CLS_WIFACE.access-points.$WIFI.password=\"$PASSWD\"" netplan/closed.yml || yq -i ".network.wifis.$CLS_WIFACE.access-points.$WIFI={}" netplan/closed.yml
fi

# Free port 53 on Ubuntu for Pi-hole
sudo sed -i 's/#\?DNSStubListener=.*/DNSStubListener=no/g' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
sudo cp -f /run/systemd/resolve/resolv.conf /etc/resolv.conf
grep -q '^nameserver 1\.1\.1\.1$' /etc/resolv.conf.bak || echo -e "nameserver 1.1.1.1\n$(cat /etc/resolv.conf)" | sudo tee /etc/resolv.conf.bak >/dev/null
sudo cp -f /etc/resolv.conf /etc/resolv.conf.orig
sudo cp -f /etc/resolv.conf.bak /etc/resolv.conf

# general performance
# https://cromwell-intl.com/open-source/performance-tuning/tcp.html
while IFS= read -r line; do
  grep -qP "^#?.*$(echo "$line" | cut -d= -f1) ?=.*$" /etc/sysctl.conf && sudo sed -r -i "s/^#\?.*$(echo "$line" | cut -d= -f1) \?=.*$/$line/g" /etc/sysctl.conf || echo "$line" | sudo tee -a /etc/sysctl.conf >/dev/null
done <sysctl.conf
grep -E '(#|.+=)' /etc/sysctl.conf | awk '!seen[$0]++' | sudo tee /etc/sysctl.conf >/dev/null
sudo sysctl -p

# wifi performance
echo "[connection]
# Values are 0 (use default), 1 (ignore/don't touch), 2 (disable) or 3 (enable).
wifi.powersave = 2
" | sudo tee /etc/NetworkManager/conf.d/wifi-powersave.conf >/dev/null
sudo cp -f /etc/NetworkManager/conf.d/wifi-powersave.conf /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf
[ ! -f /lib/NetworkManager/conf.d/20-connectivity-ubuntu.conf ] || sudo sed -i "s/uri=.*$/uri=/" /lib/NetworkManager/conf.d/20-connectivity-ubuntu.conf

if grep -q Raspberry /proc/device-tree/model; then

  # wifi 2.4GHz performance
  grep -q dtoverlay=disable-bt /boot/firmware/config.txt || echo "dtoverlay=disable-bt" | sudo tee -a /boot/firmware/config.txt >/dev/null

  if [ ! -f /etc/modprobe.d/brcmfmac.conf ]; then
    # wifi chip bug: https://github.com/raspberrypi/linux/issues/6049#issuecomment-2642566713
    echo "options brcmfmac roamoff=1 feature_disable=0x202000" | sudo tee /etc/modprobe.d/brcmfmac.conf >/dev/null
    sudo systemctl restart systemd-modules-load
  fi
fi

# DHCP
if $CLS_DOCKER; then
  sudo mkdir -p /etc/docker
  echo '{
    "ipv6": true,
    "fixed-cidr-v6": "2001:db8:1::/64",
    "userland-proxy": false
  }' | sudo tee /etc/docker/daemon.json >/dev/null
  sudo systemctl daemon-reload
  sudo docker compose build
  sudo systemctl enable --now docker

  for table in nat filter; do
    for chain in DOCKER DOCKER-ISOLATION-STAGE-1 DOCKER-ISOLATION-STAGE-2; do
      sudo iptables -L -t "$table" | grep -q "$chain" || sudo iptables -N "$chain" -t "$table"
      sudo ip6tables -L -t "$table" | grep -q "$chain" || sudo ip6tables -N "$chain" -t "$table"
    done
  done

  sudo systemctl stop isc-dhcp-server
  sudo systemctl restart docker
  sudo docker network prune -f
  sudo docker compose up -d --remove-orphans
else
  source dhcp/isc-dhcp-server

  if [ -n "$INTERFACESv4" ]; then
    if ! diff -q dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf &>/dev/null || ! diff -q dhcp/isc-dhcp-server /etc/default/isc-dhcp-server &>/dev/null; then
      sudo cp -f dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf
      sudo cp -f dhcp/isc-dhcp-server /etc/default/isc-dhcp-server
      sudo systemctl restart isc-dhcp-server
    fi

    sudo systemctl start isc-dhcp-server
  else
    sudo systemctl stop isc-dhcp-server
  fi
fi

# Configure nm
sudo systemctl disable isc-dhcp-server
sudo mkdir -p /etc/cloud/cloud.cfg.d
sudo touch /etc/cloud/cloud-init.disabled
echo "network: {config: disabled}" | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg >/dev/null
sudo rm -f /etc/netplan/50-cloud-init.yaml
set_netplan closed
sudo busctl --system set-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.NetworkManager ConnectivityCheckEnabled "b" 0 2>/dev/null

set_mac="$(jq ".$(iw dev | grep -zoE "$CLS_WIFACE.*type" | tr '\0' '\n' | grep -oP '(?<=ssid ).+')" config/wifis.json 2>/dev/null | tr -d '"')"
if (("${#set_mac}" == 17)) && [ "$set_mac" != "$(ifconfig | grep -zoE "$CLS_WIFACE:.*ether \S+" | grep -zoE '\S+$' | tr -d '\0')" ]; then
  sudo ifconfig "$CLS_WIFACE" down
  sudo macchanger -m "$set_mac" "$CLS_WIFACE"
  sudo ifconfig "$CLS_WIFACE" up
fi

# Verbose boot
if [ -f /etc/default/grub ] && grep -q "quiet splash" /etc/default/grub; then
  sudo sed -i 's/quiet splash//g' /etc/default/grub
  sudo update-grub
fi

# Ensure users exist
for user in $CLS_ACTIVE_USER $CLS_SCRIPT_USER; do
  if ! user_exists "$user"; then
    sudo useradd -m -s /bin/bash "$user"
    echo "$user:$user" | sudo chpasswd
  fi
done

# Autologin on boot
if grep -q gdm3 /etc/X11/default-display-manager 2>/dev/null; then
  sudo sed -i "/AutomaticLogin\(Enable\)*=.*/d; /\[daemon\]/a AutomaticLoginEnable=true\nAutomaticLogin=$CLS_ACTIVE_USER" /etc/gdm3/custom.conf
elif grep -q lightdm /etc/X11/default-display-manager 2>/dev/null; then
  echo -e "[Seat:*]\nautologin-guest=false\nautologin-user=$CLS_ACTIVE_USER\nautologin-user-timeout=0\n" | sudo tee /etc/lightdm/lightdm.conf >/dev/null
elif grep -q sddm /etc/X11/default-display-manager 2>/dev/null; then
  sudo sed -i '/\[Autologin\]/,/^$/d' /etc/sddm.conf
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
sudo sed -i "s,script_path=.*$,script_path=$PWD," kickstart.sh
active_path=/home/"$CLS_ACTIVE_USER"/.closure/kickstart.sh
allow_active="$CLS_ACTIVE_USER$(echo -e '\t')ALL=(ALL) NOPASSWD:$active_path"
allow_script="$CLS_SCRIPT_USER$(echo -e '\t')ALL=(ALL) NOPASSWD:$PWD/*"
sudo chown "$CLS_SCRIPT_USER":"$CLS_SCRIPT_USER" kickstart.sh
sudo chmod +x kickstart.sh
sudo mkdir -p "$(dirname "$active_path")"
sudo cp -f kickstart.sh "$active_path"
sudo grep -q "$allow_active" /etc/sudoers || echo "$allow_active" | sudo EDITOR='tee -a' visudo
sudo grep -q "$allow_script" /etc/sudoers || echo "$allow_script" | sudo EDITOR='tee -a' visudo

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
  ! grep -q "$active_path" /home/"$CLS_ACTIVE_USER"/.profile || sudo sed -i "\,$active_path,d" /home/"$CLS_ACTIVE_USER"/.profile
  echo "grep -qP '\d+' <<<\"\$SSH_CLIENT\" || sudo $active_path $CLS_STARTUP_ARGS" | sudo tee -a /home/"$CLS_ACTIVE_USER"/.profile >/dev/null
fi

# Prepare DDNS
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

until ping -c1 "${CLS_GATEWAY:-1.1.1.1}" &>/dev/null; do ((timer++ != 90)) || set_netplan open; done
set_netplan closed
popd || exit 1
