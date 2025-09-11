#!/bin/bash
# Auto-install Artix Linux with full-disk formatting (EFI + Root + Home)

set -e  # Stop on any error

# Devices
TARGET_DISK="/dev/nvme0n1"
HOME_DISK="/dev/sda"
ROOT_MOUNT="/mnt"
EFI_MOUNT="$ROOT_MOUNT/boot/efi"
HOME_MOUNT="$ROOT_MOUNT/home"
RName="ROOT"
BName="ESP"
HName="HOME"

echo "=== Starting Full-Disk Artix Linux Installation ==="
echo "⚠️ WARNING: This will ERASE ALL DATA on $TARGET_DISK and $HOME_DISK!"
read -p "Press Enter to continue or Ctrl+C to abort..."

# ------------------------------------------------
# 1. Partition main disk (EFI + Root)
# ------------------------------------------------
echo "Partitioning $TARGET_DISK..."
sgdisk --zap-all $TARGET_DISK
sgdisk -n1:0:+1G -t1:ef00 -c1:"EFI" $TARGET_DISK
sgdisk -n2:0:0   -t2:8300 -c2:"ROOT" $TARGET_DISK
partprobe $TARGET_DISK
sleep 2

EFI_PARTITION="${TARGET_DISK}p1"
ROOT_PARTITION="${TARGET_DISK}p2"

# Mark EFI partition as bootable
echo "Marking EFI partition bootable..."
parted -s $TARGET_DISK set 1 boot on
parted -s $TARGET_DISK set 1 esp on

# ------------------------------------------------
# 2. Format partitions
# ------------------------------------------------
echo "Formatting partitions..."
mkfs.fat -F32 -n $BName $EFI_PARTITION
mkfs.btrfs -L $RName -f $ROOT_PARTITION

echo "Formatting $HOME_DISK for /home..."
mkfs.btrfs -L $HName -f $HOME_DISK

# ------------------------------------------------
# 3. Mount root and create subvolumes
# ------------------------------------------------
echo "Mounting root partition and creating subvolumes..."
mount $ROOT_PARTITION $ROOT_MOUNT
btrfs subvolume create $ROOT_MOUNT/@
btrfs subvolume create $ROOT_MOUNT/@home
btrfs subvolume create $ROOT_MOUNT/@var
btrfs subvolume create $ROOT_MOUNT/@opt
btrfs subvolume create $ROOT_MOUNT/@srv
btrfs subvolume create $ROOT_MOUNT/@tmp
btrfs subvolume create $HOME_MOUNT/@home/.snapshots
umount $ROOT_MOUNT

# ------------------------------------------------
# 4. Remount subvolumes
# ------------------------------------------------
echo "Mounting subvolumes..."
mount -o subvol=@,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT
mkdir -p $ROOT_MOUNT/{boot/efi,home,home/.snapshots,var,opt,srv,tmp}

mount -o subvol=@var,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT/var
mount -o subvol=@opt,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT/opt
mount -o subvol=@srv,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT/srv
mount -o subvol=@tmp,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT/tmp

# EFI
mount $EFI_PARTITION $EFI_MOUNT

# ------------------------------------------------
# 5. Mount /home disk
# ------------------------------------------------
echo "Mounting /home on $HOME_DISK..."
mount $HOME_DISK $HOME_MOUNT
btrfs subvolume create $HOME_MOUNT/@home || true
umount $HOME_MOUNT
mount -o subvol=@home,compress=zstd,noatime $HOME_DISK $HOME_MOUNT
mount -o subvol=@home_snapshots,compress=zstd,noatime $HOME_DISK $HOME_MOUNT/.snapshots

echo "✅ Partitions and subvolumes ready"
echo "Root: $ROOT_PARTITION → Btrfs with subvolumes"
echo "Home: $HOME_DISK → Btrfs mounted as /home"
echo "EFI:  $EFI_PARTITION"

# ------------------------------------------------
# 6. Install base system
# ------------------------------------------------
basestrap $ROOT_MOUNT base base-devel s6-base elogind-s6 linux linux-headers \
    linux-firmware btrfs-progs grub efibootmgr vim nano snapper \
    connman connman-s6 wpa_supplicant dhcpcd bash-completion 

# ------------------------------------------------
# 7. Generate fstab
# ------------------------------------------------
fstabgen -U $ROOT_MOUNT >> $ROOT_MOUNT/etc/fstab

# # ------------------------------------------------
# # 8. Chroot for configuration
# # ------------------------------------------------
# artix-chroot $ROOT_MOUNT /bin/bash <<'EOF'
# ln -sf /usr/share/zoneinfo/Asia/Riyadh /etc/localtime
# hwclock --systohc

# echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
# locale-gen
# echo "LANG=en_US.UTF-8" > /etc/locale.conf

# echo "ThinkPad-P50" > /etc/hostname
# cat > /etc/hosts << HOSTS_EOF
# 127.0.0.1   localhost
# ::1         localhost
# 127.0.1.1   ThinkPad-P50.localdomain ThinkPad-P50
# HOSTS_EOF

# grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARTIX
# grub-mkconfig -o /boot/grub/grub.cfg

# snapper -c root create-config /
# snapper -c home create-config /home

# s6-rc-bundle add default elogind
# s6-rc-bundle add default networkmanager
# s6-rc-bundle add default dhcpcd

# echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
# passwd

# pacman -Sy --needed --noconfirm sudo git htop xorg xorg-apps xorg-drivers \
#     android-tools usbutils cups sane go rustup rsync

# read -p "Username: " username
# if [[ -n "$username" ]]; then
#   useradd -m -G wheel,video,audio,input,power,storage,optical,lp,scanner,dbus,adbusers,uucp "$username"
#   passwd "$username"
#   mkdir -p /home/$username/{Desktop,Documents,Downloads,Music,Pictures,Videos}
#   chown -R $username:$username /home/$username
# fi

# snapper -c root create -d "Fresh Install"
# snapper -c home create -d "Fresh Home"
# EOF

# ------------------------------------------------
# 8. Chroot for configuration (split for safety)
# ------------------------------------------------

echo "Configuring system inside chroot..."

# Timezone & clock
artix-chroot $ROOT_MOUNT ln -sf /usr/share/zoneinfo/Asia/Riyadh /etc/localtime || true
artix-chroot $ROOT_MOUNT hwclock --systohc || true

# Locale
# artix-chroot $ROOT_MOUNT bash -c "echo -e 'en_US.UTF-8 UTF-8\nar_SA.UTF-8 UTF-8' > /etc/locale.gen" || true
# artix-chroot $ROOT_MOUNT locale-gen || true

# Add locales to /etc/locale.gen
artix-chroot $ROOT_MOUNT bash -c "{
  echo 'en_US.UTF-8 UTF-8'
  echo 'ar_SA.UTF-8 UTF-8'
} > /etc/locale.gen" || true

# Generate locales
artix-chroot $ROOT_MOUNT locale-gen || true

# Set default locale with LC_COLLATE
artix-chroot $ROOT_MOUNT bash -c "{
  echo 'LANG=en_US.UTF-8'
  echo 'LC_COLLATE=C'
} > /etc/locale.conf" || true


# Hostname & hosts
artix-chroot $ROOT_MOUNT bash -c "echo 'ThinkPad-P50' > /etc/hostname" || true
artix-chroot $ROOT_MOUNT bash -c "cat > /etc/hosts << 'HOSTS_EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   ThinkPad-P50.localdomain ThinkPad-P50
HOSTS_EOF" || true

# Bootloader
artix-chroot $ROOT_MOUNT grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=DrRoot || true
artix-chroot $ROOT_MOUNT grub-mkconfig -o /boot/grub/grub.cfg || true

# Snapper setup
artix-chroot $ROOT_MOUNT snapper -c root create-config / || true
artix-chroot $ROOT_MOUNT snapper -c home create-config /home || true

# Services
artix-chroot $ROOT_MOUNT s6-rc-bundle add default elogind || true
artix-chroot $ROOT_MOUNT s6-rc-bundle add default connmand || true
artix-chroot $ROOT_MOUNT s6-rc-bundle add default dhcpcd || true
artix-chroot $ROOT_MOUNT s6-db-reload || true

# Sudo config
artix-chroot $ROOT_MOUNT bash -c "echo '%wheel ALL=(ALL:ALL) ALL' >> /etc/sudoers" || true

# Root password
echo "Set root password:"
artix-chroot $ROOT_MOUNT passwd || true

# Packages
artix-chroot $ROOT_MOUNT pacman -Sy --needed --noconfirm sudo git htop xorg xorg-apps xorg-drivers \
    android-tools usbutils cups sane go rustup rsync || true

# User creation
echo ""
echo "=== USER CREATION ==="
read -p "Username: " username
if [[ -n "$username" ]]; then
  artix-chroot $ROOT_MOUNT useradd -m -G wheel,video,audio,input,power,storage,optical,lp,scanner,dbus,adbusers,uucp "$username" || true
  echo "Set password for $username:"
  artix-chroot $ROOT_MOUNT passwd "$username" || true
  artix-chroot $ROOT_MOUNT mkdir -p /home/$username/{Desktop,Documents,Downloads,Music,Pictures,Videos} || true
  artix-chroot $ROOT_MOUNT chown -R $username:$username /home/$username || true
fi

# Initial snapshots
artix-chroot $ROOT_MOUNT snapper -c root create -d "Fresh Install" || true
artix-chroot $ROOT_MOUNT snapper -c home create -d "Fresh Home" || true

echo "🎉 Installation complete! Reboot when ready."

echo "🎉 Installation complete! Reboot when ready."
