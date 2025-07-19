#!/bin/bash

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

# Verbose boot
if [ -f /etc/default/grub ] && grep -q "quiet splash" /etc/default/grub; then
    sudo sed -i 's/quiet splash//g' /etc/default/grub
    grep -q "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub || echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\"" | sudo tee -a /etc/default/grub >/dev/null
    grep -q "nosplash debug --verbose" /etc/default/grub || echo "GRUB_CMDLINE_LINUX=\"nosplash debug --verbose\"" | sudo tee -a /etc/default/grub >/dev/null
    sudo update-grub
fi
