#!/usr/bin/env bash

set -eu

drive=sda
efi=sda2
main=sda3
MNT_DIR="/mnt/usb"
TIMEZONE="/usr/share/zoneinfo/Asia/Dhaka"
LOCALE="en_US.UTF-8 UTF-8"
LANG1=LANG="en_US.UTF-8"
HOSTNAME="linux"
ROOT_PASSWORD="admin"
USER="user"
USER_PASSWORD="root"

# Create a 10M BIOS partition, a 500M EFI partition, and a Linux partition with the remaining space:
sgdisk --zap-all /dev/$drive
sudo sgdisk -o -n 1:0:+10M -t 1:EF02 -n 2:0:+500M -t 2:EF00 -n 3:0:0 -t 3:8300 /dev/$drive
#sudo sgdisk -o -n 1:0:+10M -t 1:EF02 -n 2:0:+500M -t 2:EF00 -n 3:0:+8096M -t 3:8300 /dev/$drive

#Do not format the /dev/sdX1 block. This is the BIOS/MBR parition.
#Format the 500MB EFI system partition with a FAT32 filesystem:
sudo mkfs.fat -F32 /dev/$efi

#Format the Linux partition with an ext4 filesystem:
yes y | sudo mkfs.ext4 /dev/$main

#mount
#Mount the ext4 formatted partition as the root filesystem:
sudo mkdir -p /mnt/usb
sudo mount /dev/$main /mnt/usb

#Mount the FAT32 formatted EFI partition to /boot:
sudo mkdir /mnt/usb/boot
sudo mount /dev/$efi /mnt/usb/boot

#pacstrap
#Download and install the Arch Linux base packages:
sudo pacstrap /mnt/usb linux linux-firmware base nano

#fstab
sudo genfstab -U /mnt/usb > /mnt/usb/etc/fstab

#run rest of intsall from a arch-chroot script

cat << EOF > "${MNT_DIR}"/install.sh

locale
ln -s -f "$TIMEZONE" /etc/localtime

#Generate /etc/adjtime
hwclock --systohc

#Uncomment the desired Language
sed -i "s/#$LOCALE/$LOCALE/" /etc/locale.gen

#Generate the locale information
locale-gen

#Set the LANG variable in /etc/locale.conf
echo -e "$LANG1" >> /etc/locale.conf

#Create a /etc/hostname with the desired hostname
echo "$HOSTNAME" >> /etc/hostname

#Put the following in the /etc/hosts file
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1  localhost" >> /etc/hosts
echo 127.0.1.1 "$HOSTNAME".localdomain "$HOSTNAME" >> /etc/hosts

#Set the root password
printf "%s\n%s" "$ROOT_PASSWORD" "$ROOT_PASSWORD" | passwd

#Install grub and efibootmgr
yes | pacman -S grub efibootmgr

#Install grub for both BIOS and UEFI booting
grub-install --target=i386-pc --recheck /dev/$drive
grub-install --target=x86_64-efi --efi-directory /boot --recheck --removable

#Change some settings in the /etc/default/grub file
sed -i 's/GRUB_GFXMODE=auto/GRUB_GFXMODE=800x600/' /etc/default/grub
sed -i 's/#GRUB_SAVEDEFAULT=true/GRUB_SAVEDEFAULT=true/' /etc/default/grub
sed -i -E 's/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 nomodeset"/' /etc/default/grub
sed -i 's/#GRUB_DISABLE_OS_PROBER/GRUB_DISABLE_OS_PROBER/' /etc/default/grub

#Generate the GRUB configuration file
grub-mkconfig -o /boot/grub/grub.cfg

#Create a networkd file to get a wired connection
echo [Match] >> /etc/systemd/network/10-ethernet.network
echo Name=en* >> /etc/systemd/network/10-ethernet.network
echo Name=eth* >> /etc/systemd/network/10-ethernet.network
echo  >> /etc/systemd/network/10-ethernet.network
echo [Network] >> /etc/systemd/network/10-ethernet.network
echo DHCP=yes >> /etc/systemd/network/10-ethernet.network
echo IPv6PrivacyExtensions=yes >> /etc/systemd/network/10-ethernet.network
echo  >> /etc/systemd/network/10-ethernet.network
echo [DHCPv4] >> /etc/systemd/network/10-ethernet.network
echo RouteMetric=10 >> /etc/systemd/network/10-ethernet.network
echo  >> /etc/systemd/network/10-ethernet.network
echo [IPv6AcceptRA] >> /etc/systemd/network/10-ethernet.network
echo RouteMetric=10 >> /etc/systemd/network/10-ethernet.network

#Enable the networkd service
systemctl enable systemd-networkd.service

#Install and enable iwd for wireless setup
yes | pacman -S iwd
systemctl enable iwd.service

#Create a netword file for use with Wireless
echo [Match] >> /etc/systemd/network/20-wifi.network
echo Name=wl* >> /etc/systemd/network/20-wifi.network
echo  >> /etc/systemd/network/20-wifi.network
echo [Network] >> /etc/systemd/network/20-wifi.network
echo DHCP=yes >> /etc/systemd/network/20-wifi.network
echo IPv6PrivacyExtensions=yes >> /etc/systemd/network/20-wifi.network
echo  >> /etc/systemd/network/20-wifi.network
echo [DHCPv4] >> /etc/systemd/network/20-wifi.network
echo RouteMetric=20 >> /etc/systemd/network/20-wifi.network
echo  >> /etc/systemd/network/20-wifi.network
echo [IPv6AcceptRA] >> /etc/systemd/network/20-wifi.network
echo RouteMetric=20 >> /etc/systemd/network/20-wifi.network

#Enable the networkd wireless service
systemctl enable systemd-resolved.service

#Enable timesync service
systemctl enable systemd-timesyncd.service

#Create a new user
useradd -m "$USER"
printf "%s\n%s" "$USER_PASSWORD" "$USER_PASSWORD" | passwd "$USER"

#groupadd wheel for user
usermod -aG wheel "$USER"

#Install sudo
yes | pacman -S sudo

#Enable sudo for the sudo group
echo "%sudo ALL=(ALL) ALL" >> /etc/sudoers.d/10-sudo

#Create sudo group and add user to the group
groupadd sudo
usermod -aG sudo "$USER"

#Install polkit
yes | pacman -S polkit

#Decrease writes to the USB by using the noatime option in fstab
sed -i 's/relatime/noatime/' /etc/fstab

#Prevent the systemd journal from writing to the USB it will use RAM
mkdir -p /etc/systemd/journal.conf.d
echo [Journal] >> /etc/systemd/journal.conf.d/10-volatile.conf
echo Storage=volatile >> /etc/systemd/journal.conf.d/10-volatile.conf
echo SystemMaxUse=16M >> /etc/systemd/journal.conf.d/10-volatile.conf
echo RuntimeMaxUse=32M >> /etc/systemd/journal.conf.d/10-volatile.conf

#interface names. Ensure names are eth0 and wlan0
ln -s /dev/null /etc/udev/rules.d/80-net-setup-link.rules

#modify pacman.conf for color and ILoveCandy
sed -i 's/#Color/Color/' /etc/pacman.conf
sed -i 's/#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
sed -i '35 i ILoveCandy' /etc/pacman.conf
EOF


chmod 0755 ${MNT_DIR}/install.sh
arch-chroot ${MNT_DIR} /install.sh

#NOTE: This command must be run outside of the chroot
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/usb/etc/resolv.conf
