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
    if ! dpkg -s "$@" &>/dev/null; then
        sudonot apt-get update
        export DEBIAN_FRONTEND=noninteractive
        sudonot apt-get install -yqq "$@"
        DEBIAN_FRONTEND=
    fi
}

this_dir=$(dirname "$(readlink -f "$0")")
pids=$(ps -o ppid=$$)
ps -aux | grep -P "^[^-]+$this_dir/bs.sh" | awk '{print $2}' | while read -r pid; do grep -q "$pid" <<<"$pids" || sudonot kill -9 "$pid" &>/dev/null; done

if ! dpkg -s apt-fast &>/dev/null; then
    sudonot add-apt-repository -y ppa:apt-fast/stable
    sudonot apt-get update
    sudonot DEBIAN_FRONTEND=noninteractive apt-get install -yq apt-fast
fi

if ! dpkg -s docker-ce &>/dev/null; then
    apt_install ca-certificates curl
    sudonot install -m 0755 -d /etc/apt/keyrings
    sudonot curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudonot chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [trusted=yes arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | sudonot tee /etc/apt/sources.list.d/docker.list >/dev/null
fi

if ! dpkg -s closure &>/dev/null; then
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
" | sudonot tee /etc/NetworkManager/conf.d/wifi-powersave.conf >/dev/null
sudonot cp -f /etc/NetworkManager/conf.d/wifi-powersave.conf /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf
[ ! -f /lib/NetworkManager/conf.d/20-connectivity-ubuntu.conf ] || sudonot sed -i "s/uri=.*$/uri=/" /lib/NetworkManager/conf.d/20-connectivity-ubuntu.conf

if grep -q Raspberry /proc/device-tree/model; then

    # wifi 2.4GHz performance
    grep -q dtoverlay=disable-bt /boot/firmware/config.txt || echo "dtoverlay=disable-bt" | sudonot tee -a /boot/firmware/config.txt >/dev/null

    if [ ! -f /etc/modprobe.d/brcmfmac.conf ]; then
        # wifi chip bug: https://github.com/raspberrypi/linux/issues/6049#issuecomment-2642566713
        echo "options brcmfmac roamoff=1 feature_disable=0x202000" | sudonot tee /etc/modprobe.d/brcmfmac.conf >/dev/null
        sudonot systemctl restart systemd-modules-load
    fi
fi

# Verbose boot
if [ -f /etc/default/grub ] && grep -q "quiet splash" /etc/default/grub; then
    sudonot sed -i 's/quiet splash//g' /etc/default/grub
    grep -q "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub || echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\"" | sudonot tee -a /etc/default/grub >/dev/null
    grep -q "nosplash debug --verbose" /etc/default/grub || echo "GRUB_CMDLINE_LINUX=\"nosplash debug --verbose\"" | sudonot tee -a /etc/default/grub >/dev/null
    sudonot update-grub
fi
