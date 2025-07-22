#!/bin/bash
set -e

echo "Starting Arch GPG keyring fix..."

echo "Step 1: Enabling NTP to sync system clock"
timedatectl set-ntp true

echo "Step 2: Removing existing keyring"
rm -rf /etc/pacman.d/gnupg

echo "Step 3: Initializing and populating pacman keyring"
pacman-key --init
pacman-key --populate archlinux

pacman -Sy archlinux-keyring --noconfirm

echo "Performing System Update"
pacman -Syu --noconfirm

echo "Adding Users & Groups"
useradd -m admin

echo "Please set the password of the admin user:"
passwd admin

groupadd media
usermod -aG media,wheel,storage,video,audio,network,optical admin

pacman -S sudo --noconfirm

echo "Sudo is now installed. Please run visudo and uncomment wheel permissions."
