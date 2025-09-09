#!/bin/bash
# Auto-install Artix Linux script with Btrfs subvolumes - SIMPLE VERSION
# WARNING: This will format /dev/nvme0n1 with EFI and Btrfs root, but leaves /dev/sda1 alone!

set -e  # Stop on any error

# Variables
TARGET_DISK="/dev/nvme0n1"
EFI_PARTITION="/dev/nvme0n1p1"
ROOT_PARTITION="/dev/nvme0n1p2"
HOME_DISK="/dev/sda1"
ROOT_MOUNT="/mnt"
EFI_MOUNT="$ROOT_MOUNT/boot/efi"
HOME_MOUNT="$ROOT_MOUNT/home"
RName="ROOT"
BName="BOOT"

echo "=== Starting Artix Linux installation ==="
echo ""
echo "🛡️  SIMPLE APPROACH:"
echo "  ✅ Format /dev/nvme0n1 (root partition)"
echo "  ✅ Create /home/.snapshots on /dev/sda1"
echo "  ❌ Don't touch your existing data - you handle it later"
echo ""
read -p "Press Enter to continue or Ctrl+C to abort..."

# 1. Create partitions on nvme0n1
echo "Creating partitions on $TARGET_DISK..."
echo -e "g\nn\n1\n\n+512M\nt\n1\nef\nn\n2\n\n\nw\n" | fdisk $TARGET_DISK

# Wait for kernel to re-read partition table
sleep 2
partprobe $TARGET_DISK

# 2. Format only the root partitions
echo "Formatting root partitions..."
mkfs.fat -F32 -n $BName $EFI_PARTITION  # EFI partition
mkfs.btrfs -L $RName -f $ROOT_PARTITION  # Root partition
echo "✅ /dev/sda1 left completely untouched"

# 3. Mount root partition and create subvolumes
echo "Mounting $ROOT_PARTITION and creating Btrfs subvolumes..."
mount $ROOT_PARTITION $ROOT_MOUNT

# Create Btrfs subvolumes for root partition
btrfs subvolume create $ROOT_MOUNT/@           # Root
btrfs subvolume create $ROOT_MOUNT/@home       # Home directories 
btrfs subvolume create $ROOT_MOUNT/@var        # Variable data
btrfs subvolume create $ROOT_MOUNT/@opt        # Optional software
btrfs subvolume create $ROOT_MOUNT/@srv        # Server data
btrfs subvolume create $ROOT_MOUNT/@tmp        # Temporary files

echo "✅ Created Btrfs subvolumes on root partition"

# Unmount the root to remount with subvolumes
umount $ROOT_MOUNT

# 4. Mount all subvolumes
echo "Mounting all subvolumes..."

# Mount root with @ subvolume
mount -o subvol=@,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT

# Create directories for mount points
mkdir -p $ROOT_MOUNT/{boot/efi,home,var,opt,srv,tmp,.snapshots}

# Mount EFI partition
echo "Mounting EFI partition..."
mount $EFI_PARTITION $EFI_MOUNT

# Mount root subvolumes
mount -o subvol=@home,compress=zstd,noatime $ROOT_PARTITION $HOME_MOUNT
mount -o subvol=@var,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT/var
mount -o subvol=@opt,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT/opt
mount -o subvol=@srv,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT/srv
mount -o subvol=@tmp,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT/tmp

echo "✅ All root subvolumes mounted"

# 5. Set up snapshots on home disk
echo "Setting up snapshots on $HOME_DISK..."

# Mount home disk temporarily to create .snapshots directory
mkdir -p /mnt/temp_home
mount $HOME_DISK /mnt/temp_home
mkdir -p /mnt/temp_home/.snapshots

# Create .snapshots in @home subvolume and bind mount from home disk
mkdir -p $HOME_MOUNT/.snapshots
mount --bind /mnt/temp_home/.snapshots $HOME_MOUNT/.snapshots

# Also make available at /.snapshots for system access
mount --bind $HOME_MOUNT/.snapshots $ROOT_MOUNT/.snapshots

# Unmount temporary mount
umount /mnt/temp_home
rmdir /mnt/temp_home

echo "✅ Snapshots will be stored on $HOME_DISK at /home/.snapshots"

# 6. Install base system
echo "Installing base Artix system..."
basestrap $ROOT_MOUNT base base-devel s6-base elogind-s6 linux linux-headers nvidia-dkms linux-firmware vim nano btrfs-progs grub efibootmgr snapper networkmanager networkmanager-s6 wpa_supplicant wpa_supplicant-s6 dhcpcd dhcpcd-s6

# 7. Generate fstab
echo "Generating fstab..."
fstabgen -U $ROOT_MOUNT >> $ROOT_MOUNT/etc/fstab

# Add snapshots mount to fstab
echo "" >> $ROOT_MOUNT/etc/fstab
echo "# Snapshots on home partition" >> $ROOT_MOUNT/etc/fstab
echo "UUID=$(blkid -s UUID -o value $HOME_DISK)/.snapshots /home/.snapshots none bind 0 0" >> $ROOT_MOUNT/etc/fstab
echo "/home/.snapshots /.snapshots none bind 0 0" >> $ROOT_MOUNT/etc/fstab

# 8. Chroot for configuration
echo "Entering chroot for configuration..."
artix-chroot $ROOT_MOUNT /bin/bash <<'EOF'

# Set timezone and hardware clock
ln -sf /usr/share/zoneinfo/Asia/Riyadh /etc/localtime
hwclock --systohc

# Configure locale
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Set hostname and configure hosts file
echo "ThinkPad-P50" > /etc/hostname

cat > /etc/hosts << 'HOSTS_EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   ThinkPad-P50.localdomain ThinkPad-P50
HOSTS_EOF

# Install and configure bootloader
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARTIX
grub-mkconfig -o /boot/grub/grub.cfg

# Configure snapper for root filesystem
snapper -c root create-config /
snapper -c root set-config "SUBVOLUME=/"
snapper -c root set-config "ALLOW_USERS=root"
snapper -c root set-config "SYNC_ACL=yes"
snapper -c root set-config "SPACE_LIMIT=0.2"

# Configure snapper for home filesystem
snapper -c home create-config /home
snapper -c home set-config "SUBVOLUME=/home"
snapper -c home set-config "ALLOW_USERS=root"
snapper -c home set-config "SYNC_ACL=yes" 
snapper -c home set-config "SPACE_LIMIT=0.2"

# Set up conservative snapshot policies
snapper -c root set-config "NUMBER_CLEANUP=yes"
snapper -c root set-config "NUMBER_MIN_AGE=1800"
snapper -c root set-config "NUMBER_LIMIT=8"
snapper -c root set-config "NUMBER_LIMIT_IMPORTANT=3"
snapper -c root set-config "TIMELINE_CREATE=yes"
snapper -c root set-config "TIMELINE_CLEANUP=yes"
snapper -c root set-config "TIMELINE_MIN_AGE=1800"
snapper -c root set-config "TIMELINE_LIMIT_HOURLY=3"
snapper -c root set-config "TIMELINE_LIMIT_DAILY=5"
snapper -c root set-config "TIMELINE_LIMIT_WEEKLY=2"
snapper -c root set-config "TIMELINE_LIMIT_MONTHLY=1"
snapper -c root set-config "TIMELINE_LIMIT_YEARLY=0"

snapper -c home set-config "NUMBER_CLEANUP=yes"
snapper -c home set-config "NUMBER_MIN_AGE=1800"
snapper -c home set-config "NUMBER_LIMIT=5"
snapper -c home set-config "TIMELINE_CREATE=yes"
snapper -c home set-config "TIMELINE_CLEANUP=yes"
snapper -c home set-config "TIMELINE_MIN_AGE=1800"
snapper -c home set-config "TIMELINE_LIMIT_HOURLY=2"
snapper -c home set-config "TIMELINE_LIMIT_DAILY=3"
snapper -c home set-config "TIMELINE_LIMIT_WEEKLY=1"
snapper -c home set-config "TIMELINE_LIMIT_MONTHLY=1"

# Enable s6 services
s6-rc-bundle add default elogind
s6-rc-bundle add default networkmanager
s6-rc-bundle add default dhcpcd

# Configure sudo
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
echo "Defaults timestamp_timeout=30" >> /etc/sudoers

# Set root password
echo "Set root password:"
passwd

# Install additional packages
pacman -Sy --needed --noconfirm sudo android-tools usbutils util-linux cups sane uucp dbus acpi polkit htop git xorg xorg-apps xorg-drivers go rustup rsync

# Create user
echo ""
echo "=== USER CREATION ==="
read -p "Create a user? (y/N): " create_user

if [[ $create_user =~ ^[Yy]$ ]]; then
    read -p "Username: " username
    
    if [[ "$username" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
        useradd -m -G wheel,video,audio,input,power,storage,optical,lp,scanner,dbus,adbusers,uucp "$username"
        echo "Set password for $username:"
        passwd "$username"
        
        mkdir -p "/home/$username"/{Desktop,Documents,Downloads,Music,Pictures,Videos}
        chown -R "$username:$username" "/home/$username"
        
        echo "✅ User $username created"
    else
        echo "Invalid username format"
    fi
fi

# Create initial snapshots
snapper -c root create -d "Fresh Artix installation"
snapper -c home create -d "Initial home setup"

EOF

echo ""
echo "================================="
echo "🎉 INSTALLATION COMPLETED! 🎉"
echo "================================="
echo ""
echo "📊 System Summary:"
echo "  • Root: Btrfs with subvolumes on /dev/nvme0n1p2"
echo "  • Home: @home subvolume on root partition"  
echo "  • Snapshots: /home/.snapshots on /dev/sda1"
echo "  • Old data: Untouched on /dev/sda1 - you handle it"
echo ""
echo "🏗️ Layout:"
echo "  /dev/nvme0n1p2 (Root - Btrfs):"
echo "    ├── / → @"
echo "    ├── /home → @home"
echo "    ├── /var → @var"
echo "    ├── /opt → @opt"
echo "    └── /tmp → @tmp"
echo ""
echo "  /dev/sda1 (Your data + snapshots):"
echo "    ├── .snapshots → mounted to /home/.snapshots"
echo "    └── [your data] → you'll handle this after reboot"
echo ""
echo "📸 Snapshots:"
echo "  • Access: /home/.snapshots and /.snapshots"
echo "  • Storage: Physically on /dev/sda1"
echo "  • Commands: snapper -c root list, snapper -c home list"
echo ""
echo "⚠️ Next Steps:"
echo "  1. Reboot your system"
echo "  2. After reboot, mount /dev/sda1 and access your old data"
echo "  3. Migrate data as needed to /home/[username]"
echo ""
echo "✅ Ready for reboot!"
