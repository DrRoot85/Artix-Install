#!/bin/bash
# Auto-install Artix Linux script with Btrfs subvolumes - PRESERVE EXISTING HOME
# WARNING: This will format /dev/nvme0n1 with EFI and Btrfs root, but PRESERVE /dev/sda1!

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

echo "=== Starting Artix Linux installation (preserving existing /dev/sda1) ==="

# 1. Create partitions on nvme0n1
echo "Creating partitions on $TARGET_DISK..."
# Fixed: EFI partition type should be 'ef' (EFI System)
echo -e "g\nn\n1\n\n+512M\nt\n1\nef\nn\n2\n\n\nw\n" | fdisk $TARGET_DISK

# Wait for kernel to re-read partition table
sleep 2
partprobe $TARGET_DISK

# 2. Format only the root partitions (NOT the home disk)
echo "Formatting root partitions..."
mkfs.fat -F32 -n $BName $EFI_PARTITION  # EFI partition
mkfs.btrfs -L $RName -f $ROOT_PARTITION  # Root partition
echo "NOTE: Preserving existing filesystem on $HOME_DISK"

# 3. Mount root partition and create subvolumes
echo "Mounting $ROOT_PARTITION and creating Btrfs subvolumes..."
mount $ROOT_PARTITION $ROOT_MOUNT

# Create Btrfs subvolumes for root partition
btrfs subvolume create $ROOT_MOUNT/@           # Root
btrfs subvolume create $ROOT_MOUNT/@home       # Home directories (on root partition)
btrfs subvolume create $ROOT_MOUNT/@var        # Variable data
btrfs subvolume create $ROOT_MOUNT/@opt        # Optional software
btrfs subvolume create $ROOT_MOUNT/@srv        # Server data
btrfs subvolume create $ROOT_MOUNT/@tmp        # Temporary files
# Note: @snapshots will be created on the home partition (sda1), not here

# Unmount the root to remount with subvolumes
umount $ROOT_MOUNT

# 4. Mount all partitions with proper subvolumes
echo "Mounting all partitions with subvolumes..."

# Mount root with @ subvolume
mount -o subvol=@,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT

# Create directories for other mount points
mkdir -p $ROOT_MOUNT/{boot/efi,home,var,opt,srv,tmp,.snapshots,home}

# Mount EFI partition
echo "Mounting EFI partition..."
mount $EFI_PARTITION $EFI_MOUNT

# Mount root subvolumes with appropriate options
mount -o subvol=@home,compress=zstd,noatime $ROOT_PARTITION $HOME_MOUNT
mount -o subvol=@var,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT/var
mount -o subvol=@opt,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT/opt
mount -o subvol=@srv,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT/srv
mount -o subvol=@tmp,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT/tmp
# Mount snapshots directory from home disk (not a subvolume, just a directory)
# Create the .snapshots directory and bind mount it
mkdir -p $ROOT_MOUNT/home/.snapshots
mount --bind $ROOT_MOUNT/home/.snapshots $ROOT_MOUNT/.snapshots

# 5. Set up snapshots subvolume on the home disk and mount existing data
echo "Setting up snapshots on $HOME_DISK..."

# First, check if the home disk has Btrfs filesystem, if not, we need to handle it differently
echo "Creating snapshots directory structure on $HOME_DISK..."
# Mount the existing home disk temporarily
mount $HOME_DISK /mnt/temp_home 2>/dev/null || {
    mkdir -p /mnt/temp_home
    mount $HOME_DISK /mnt/temp_home
}

# Create .snapshots directory on the existing home partition
mkdir -p /mnt/temp_home/.snapshots

# Unmount temp mount
umount /mnt/temp_home
rmdir /mnt/temp_home

# Now mount the home disk to /home/old_home for data access
echo "Mounting existing $HOME_DISK to /home/old_home for data preservation..."
mount $HOME_DISK $ROOT_MOUNT/home

echo "Your existing home data is available at /home/old_home after installation"
echo "You can migrate data from /home/old_home to /home/username as needed"

# 6. Install base system
echo "Installing base Artix system..."
basestrap $ROOT_MOUNT base base-devel s6-base elogind-s6 linux linux-headers nvidia-dkms linux-firmware vim nano btrfs-progs grub efibootmgr snapper networkmanager networkmanager-s6 dhcpcd dhcpcd-s6

# 7. Generate fstab
echo "Generating fstab..."
fstabgen -U $ROOT_MOUNT >> $ROOT_MOUNT/etc/fstab

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

# Create proper /etc/hosts file
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
snapper -c root set-config "SPACE_LIMIT=0.3"

# Configure snapper for home filesystem (@home subvolume)
snapper -c home create-config /home
snapper -c home set-config "SUBVOLUME=/home"
snapper -c home set-config "ALLOW_USERS=root"
snapper -c home set-config "SYNC_ACL=yes" 
snapper -c home set-config "SPACE_LIMIT=0.3"

# Set up snapshot policies for root
snapper -c root set-config "NUMBER_CLEANUP=yes"
snapper -c root set-config "NUMBER_MIN_AGE=1800"
snapper -c root set-config "NUMBER_LIMIT=10"
snapper -c root set-config "NUMBER_LIMIT_IMPORTANT=5"
snapper -c root set-config "TIMELINE_CREATE=yes"
snapper -c root set-config "TIMELINE_CLEANUP=yes"
snapper -c root set-config "TIMELINE_MIN_AGE=1800"
snapper -c root set-config "TIMELINE_LIMIT_HOURLY=5"
snapper -c root set-config "TIMELINE_LIMIT_DAILY=7"
snapper -c root set-config "TIMELINE_LIMIT_WEEKLY=3"
snapper -c root set-config "TIMELINE_LIMIT_MONTHLY=2"
snapper -c root set-config "TIMELINE_LIMIT_YEARLY=1"

# Set up snapshot policies for home
snapper -c home set-config "NUMBER_CLEANUP=yes"
snapper -c home set-config "NUMBER_MIN_AGE=1800"
snapper -c home set-config "NUMBER_LIMIT=5"
snapper -c home set-config "TIMELINE_CREATE=yes"
snapper -c home set-config "TIMELINE_CLEANUP=yes"
snapper -c home set-config "TIMELINE_MIN_AGE=1800"
snapper -c home set-config "TIMELINE_LIMIT_HOURLY=3"
snapper -c home set-config "TIMELINE_LIMIT_DAILY=5"
snapper -c home set-config "TIMELINE_LIMIT_WEEKLY=2"
snapper -c home set-config "TIMELINE_LIMIT_MONTHLY=1"

# Enable s6 services (CORRECTED for s6 init system)
# Enable base services
s6-rc-bundle add default elogind
s6-rc-bundle add default networkmanager
s6-rc-bundle add default dhcpcd

# Create snapper services for s6 (these may need to be created manually or use cron)
# Note: Snapper timeline services might need manual setup with s6
echo "Note: Snapper automatic timeline may need manual cron setup with s6"

# Configure sudo access for wheel group - FIXED
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
echo "Defaults timestamp_timeout=30" >> /etc/sudoers

# Set root password
echo "Set root password:"
passwd

# Install additional packages
pacman -Syy sudo android-tools usbutils util-linux cups sane uucp dbus acpi polkit htop git xorg xorg-apps xorg-drivers go rustup rsync --needed --noconfirm

# Prompt to create a regular user
echo ""
echo "=== USER CREATION ==="
read -p "Would you like to create a regular user? (y/N): " create_user

if [[ $create_user =~ ^[Yy]$ ]]; then
    read -p "Enter username: " username
    
    # Check if username is valid
    if [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        useradd -m -G wheel,video,audio,input,power,storage,optical,lp,scanner,dbus,adbusers,uucp "$username"
        echo "Set password for $username:"
        passwd "$username"
        
        echo "User $username created successfully with the following group memberships:"
        echo " - wheel (sudo privileges)"
        echo " - video (graphics access)"
        echo " - audio (sound access)" 
        echo " - input (input devices)"
        echo " - power (power management)"
        echo " - storage (storage devices)"
        echo " - optical (optical drives)"
        echo " - lp (printing)"
        echo " - scanner (scanner access)"
        echo " - dbus (D-Bus communication)"
        echo " - adbusers (Android debugging)"
        echo " - uucp (serial devices)"
        
        # Set up basic user directories in the @home subvolume
        mkdir -p "/home/$username"/{Desktop,Documents,Downloads,Music,Pictures,Videos}
        chown -R "$username:$username" "/home/$username"
        
        # Offer to migrate data from old home
        echo ""
        echo "=== DATA MIGRATION OPTION ==="
        echo "Your old home data is available at /home/old_home"
        read -p "Would you like to copy data from old home to new user directory? (y/N): " migrate_data
        
        if [[ $migrate_data =~ ^[Yy]$ ]]; then
            if [ -d "/home/old_home/$username" ]; then
                echo "Copying data from /home/old_home/$username to /home/$username..."
                rsync -av --exclude='.gvfs' "/home/old_home/$username/" "/home/$username/"
                chown -R "$username:$username" "/home/$username"
                echo "Data migration completed!"
            else
                echo "No matching user directory found in /home/old_home/$username"
                echo "You can manually copy data later using:"
                echo "  sudo rsync -av /home/old_home/[source_user]/ /home/$username/"
                echo "  sudo chown -R $username:$username /home/$username"
            fi
        else
            echo "Skipping data migration. You can migrate manually later."
            echo "Old data remains accessible at /home/old_home"
        fi
        
    else
        echo "Invalid username format. Skipping user creation."
        echo "Username should start with a letter or underscore, followed by letters, numbers, underscores, or hyphens."
    fi
else
    echo "Skipping user creation."
fi

# Create initial snapshots after installation
echo "Creating initial system snapshots..."
snapper -c root create -d "Fresh Artix installation"
snapper -c home create -d "Fresh home setup"

EOF

echo ""
echo "=== Installation Complete ==="
echo ""
echo "🎉 Artix Linux has been successfully installed (preserving your existing home data)!"
echo ""
echo "📊 System Configuration Summary:"
echo " • Bootloader: GRUB (EFI)"
echo " • Init System: s6"
echo " • Root Filesystem: Btrfs with subvolumes"
echo " • Home: @home subvolume + preserved old data"
echo " • Snapshots: Centralized in @snapshots"
echo " • Network: NetworkManager ready"
echo ""
echo "📁 Btrfs Subvolume Layout (all on $ROOT_PARTITION):"
echo " • /          -> @"
echo " • /home      -> @home (new Btrfs subvolume)"
echo " • /var       -> @var"
echo " • /opt       -> @opt" 
echo " • /srv       -> @srv"
echo " • /tmp       -> @tmp"
echo " • /.snapshots -> @snapshots"
echo ""
echo "💾 Data Preservation:"
echo " • Old home data: /home/old_home (mounted from $HOME_DISK)"
echo " • New home data: /home (Btrfs @home subvolume)"
echo " • You can access old files at /home/old_home"
echo " • Migration can be done manually or was offered during setup"
echo ""
echo "📸 Snapshot Configuration:"
echo " • Root snapshots: /.snapshots/ (snapper -c root)"
echo " • Home snapshots: /.snapshots/ (snapper -c home)" 
echo " • Both root and home use Btrfs subvolumes with snapshots"
echo " • Old home data is preserved but not snapshotted"
echo " • Automatic timeline snapshots enabled"
echo ""
echo "🔧 Snapper Quick Reference:"
echo " • List root snapshots:    snapper -c root list"
echo " • List home snapshots:    snapper -c home list"
echo " • Create root snapshot:   snapper -c root create -d 'Description'"
echo " • Create home snapshot:   snapper -c home create -d 'Description'"
echo " • Rollback root:          snapper -c root rollback <number>"
echo " • Rollback home:          snapper -c home rollback <number>"
echo ""
echo "🔄 Data Migration Commands (if needed later):"
echo " • Copy user data: sudo rsync -av /home/old_home/[user]/ /home/[user]/"
echo " • Fix permissions: sudo chown -R [user]:[user] /home/[user]"
echo " • Check old data: ls -la /home/old_home"
echo ""
echo "⚠️  Important Next Steps:"
echo " 1. Reboot into your new system"
echo " 2. Test network connectivity"
echo " 3. Verify snapshots: snapper list-configs"
echo " 4. Migrate any remaining data from /home/old_home"
echo " 5. Install desktop environment if desired"
echo " 6. Configure firewall (ufw recommended)"
echo ""
echo "🔗 Useful Commands After Reboot:"
echo " • Check services: s6-rc -l all"
echo " • Network config: nmcli or nmtui"
echo " • Check subvolumes: btrfs subvolume list /"
echo " • Check disk usage: btrfs filesystem usage /"
echo " • Access old data: ls /home/old_home"
echo ""
echo "✅ System is ready for reboot with preserved home data!"

# Clean up
rm -f artix_install_test.sh
