#!/bin/bash
# shellcheck disable=SC1091,SC2009,SC2015

this_dir=$(dirname "$(readlink -f "$0")")
pushd "$this_dir" || exit 1

pids=$(ps -o ppid=$$)
ps -aux | grep -P "^[^-]+$this_dir/init.sh" | awk '{print $2}' | while read -r pid; do grep -q "$pid" <<<"$pids" || sudonot kill -9 "$pid" &>/dev/null; done
source "bs.sh"
mv -n examples/* . 2>/dev/null
rmdir examples 2>/dev/null
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
