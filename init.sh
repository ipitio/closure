#!/bin/bash
# shellcheck disable=SC1091,SC2009,SC2015

sudonot() {
    # shellcheck disable=SC2068
    if command -v sudo >/dev/null; then
        sudo -E "${@:-:}" || "${@:-:}"
    else
        "${@:-:}"
    fi
}

apt_install() {
    if ! dpkg -l "$@" >/dev/null 2>&1; then
        sudonot apt-get update
        export DEBIAN_FRONTEND=noninteractive
        sudonot apt-get install -yqq "$@"
        DEBIAN_FRONTEND=
    fi
}

this_dir=$(dirname "$(readlink -f "$0")")
pushd "$this_dir" || exit 1
source "env.sh"

pids=$(ps -o ppid=$$)
ps -aux | grep -P "^[^-]+$this_dir/init.sh" | awk '{print $2}' | while read -r pid; do grep -q "$pid" <<<"$pids" || sudonot kill -9 "$pid" &>/dev/null; done
mv -n examples/* . 2>/dev/null
rmdir examples 2>/dev/null

if ! dpkg -l apt-fast >/dev/null 2>&1; then
    sudonot add-apt-repository -y ppa:apt-fast/stable
    sudonot apt-get update
    sudonot DEBIAN_FRONTEND=noninteractive apt-get install -yq apt-fast
fi

if ! dpkg -l docker-ce >/dev/null 2>&1; then
    apt_install ca-certificates curl
    sudonot install -m 0755 -d /etc/apt/keyrings
    sudonot curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudonot chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [trusted=yes arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | sudonot tee /etc/apt/sources.list.d/docker.list >/dev/null
fi

if ! dpkg -l closure >/dev/null 2>&1; then
    sudonot mkdir -m 0755 -p /etc/apt/keyrings/
    wget -qO- https://ipitio.github.io/closure/gpg.key | gpg --dearmor | sudonot tee /etc/apt/keyrings/closure.gpg >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/closure.gpg] https://ipitio.github.io/closure master main" | sudonot tee /etc/apt/sources.list.d/closure.list &>/dev/null
    sudonot chmod 644 /etc/apt/keyrings/closure.gpg
    sudonot chmod 644 /etc/apt/sources.list.d/closure.list
fi

[ ! -f /etc/apt/preferences.d/nosnap.pref ] || sudonot mv /etc/apt/preferences.d/nosnap.pref /etc/apt/preferences.d/nosnap.pref.bak
sudonot systemctl disable --now whoopsie.path &>/dev/null
sudonot systemctl mask whoopsie.path &>/dev/null
sudonot apt-get purge -y ubuntu-report popularity-contest apport whoopsie
# shellcheck disable=SC2046
apt_install closure $(grep -oP '((?<=^Depends: )|(?<=^Recommends: )|(?<=^Suggests: )).*' debian/control | tr -d ',' | tr '\n' ' ')
sudonot apt autoremove -y
yq -V | grep -q mikefarah &>/dev/null || {
    [ ! -f /usr/bin/yq ] || sudonot mv -f /usr/bin/yq /usr/bin/yq.bak
    arch=$(uname -m)
    [ "$arch" = "x86_64" ] && arch="amd64" || :
    [ "$arch" = "aarch64" ] && arch="arm64" || :
    [ "$arch" = "armv7l" ] && arch="armhf" || :
    [ "$arch" = "armhf" ] && arch="arm" || :
    [[ "$arch" == "i686" || "$arch" == "i386" ]] && arch="386" || :
    sudonot curl -LNZo /usr/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_"$arch"
    sudonot chmod +x /usr/bin/yq
}
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --noninteractive flathub tv.kodi.Kodi
[ ! -f /.dockerenv ] || exit 0

# wifi performance
echo "[connection]
# Values are 0 (use default), 1 (ignore/don't touch), 2 (disable) or 3 (enable).
wifi.powersave = 2
" | sudo tee /etc/NetworkManager/conf.d/wifi-powersave.conf >/dev/null
sudo cp -f /etc/NetworkManager/conf.d/wifi-powersave.conf /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf
[ ! -f /lib/NetworkManager/conf.d/20-connectivity-ubuntu.conf ] || sudo sed -i "s/uri=.*$/uri=/" /lib/NetworkManager/conf.d/20-connectivity-ubuntu.conf
source "bs.sh"
source "lib.sh"

# general performance
# https://cromwell-intl.com/open-source/performance-tuning/tcp.html
while IFS= read -r line; do
    grep -qP "^#?\s*?$(echo "$line" | cut -d= -f1)\s*?=.*$" /etc/sysctl.conf && sudo sed -r -i "s/^#?\s*?$(echo "$line" | cut -d= -f1)\s*?=.*$/$line/g" /etc/sysctl.conf || echo "$line" | sudo tee -a /etc/sysctl.conf >/dev/null
done <sysctl.conf
grep -E '(#|.+=)' /etc/sysctl.conf | awk '!seen[$0]++' | sudo tee /etc/sysctl.conf >/dev/null
sudo sysctl -p

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
allow_active="$CLS_ACTIVE_USER$(echo -e '\t')ALL=(ALL) NOPASSWD:SETENV:$active_path"
allow_script="$CLS_SCRIPT_USER$(echo -e '\t')ALL=(ALL) NOPASSWD:SETENV:$PWD/*"
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
    ! grep -qF "/.closure/" /home/"$CLS_ACTIVE_USER"/.profile || sudo sed -i "\,/\.closure/,d" /home/"$CLS_ACTIVE_USER"/.profile
    echo "grep -qP '\d+' <<<\"\$SSH_CLIENT\" || sudo $active_path $CLS_STARTUP_ARGS" | sudo tee -a /home/"$CLS_ACTIVE_USER"/.profile >/dev/null
fi

if [ "$CLS_DOCKER" = "true" ]; then
    sudo mkdir -p /etc/docker
    echo '{
    "ipv6": true,
    "fixed-cidr-v6": "2001:db8:1::/64",
    "userland-proxy": false
  }' | sudo tee /etc/docker/daemon.json >/dev/null
    sudo systemctl daemon-reload
    sudo docker compose build
fi

sudo sed -i 's/\#\?DNSStubListener=.*/DNSStubListener=no/g' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
sudo systemctl disable isc-dhcp-server &>/dev/null
sudo systemctl stop hostapd &>/dev/null
sudo systemctl disable hostapd &>/dev/null
sudo systemctl mask hostapd &>/dev/null
[ -f /home/"$CLS_ACTIVE_USER"/.kodi/.cls ] || sudo cp -r kodi /home/"$CLS_ACTIVE_USER"/.kodi
sudo mkdir -p /opt/closure
sudo touch /opt/closure/installed
popd || exit 1
