#!/bin/bash

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
    sudo update-grub
fi
