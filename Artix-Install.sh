#!/bin/bash
# Auto-install Artix Linux script with Btrfs subvolumes
# WARNING: This will format /dev/nvme0n1 with EFI and Btrfs root!

set -e  # Stop on any error

# Variables
TARGET_DISK="/dev/nvme0n1"
EFI_PARTITION="/dev/nvme0n1p1"
ROOT_PARTITION="/dev/nvme0n1p2"
HOME_DISK="/dev/sda1"
ROOT_MOUNT="/mnt"
EFI_MOUNT="$ROOT_MOUNT/boot/efi"
HOME_MOUNT="$ROOT_MOUNT/home"

echo "=== Starting Artix Linux installation ==="

# 1. Create partitions on nvme0n1
echo "Creating partitions on $TARGET_DISK..."
echo -e "g\nn\n1\n\n+512M\nt\n1\nn\n2\n\n\nw\n" | fdisk $TARGET_DISK

# 2. Format partitions
echo "Formatting partitions..."
mkfs.fat -F32 $EFI_PARTITION  # EFI partition
mkfs.btrfs -f $ROOT_PARTITION  # Root partition

# 3. Mount root partition and create subvolumes
echo "Mounting $ROOT_PARTITION and creating Btrfs subvolumes..."
mount $ROOT_PARTITION $ROOT_MOUNT

# Create Btrfs subvolumes
btrfs subvolume create $ROOT_MOUNT/@           # Root
btrfs subvolume create $ROOT_MOUNT/@var        # Variable data
btrfs subvolume create $ROOT_MOUNT/@opt        # Optional software
btrfs subvolume create $ROOT_MOUNT/@srv        # Server data
btrfs subvolume create $ROOT_MOUNT/@tmp        # Temporary files
# Note: @snapshots is not created here as it will be on the home partition

# Unmount the root to remount with subvolumes
umount $ROOT_MOUNT

# 4. Mount root with subvolume and other partitions
echo "Remounting with subvolumes..."
mount -o subvol=@,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT

# Create directories for other mount points
mkdir -p $ROOT_MOUNT/{boot/efi,home,var,opt,srv,tmp}

# Mount EFI partition
echo "Mounting EFI partition..."
mount $EFI_PARTITION $EFI_MOUNT

# Mount other subvolumes with appropriate options
mount -o subvol=@var,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT/var
mount -o subvol=@opt,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT/opt
mount -o subvol=@srv,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT/srv
mount -o subvol=@tmp,compress=zstd,noatime $ROOT_PARTITION $ROOT_MOUNT/tmp

# 5. Mount home disk and create snapshots directory
echo "Mounting $HOME_DISK as /home..."
mount $HOME_DISK $HOME_MOUNT

# Create .snapshots directory in home partition
echo "Creating .snapshots directory in home partition..."
mkdir -p $HOME_MOUNT/.snapshots

# 6. Install base system
echo "Installing base Artix system..."
basestrap $ROOT_MOUNT base base-devel s6-base elogind-s6 linux linux-headers nvidia-dkms linux-firmware vim nano btrfs-progs grub efibootmgr snapper

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

# Set hostname
echo "ThinkPad-P50" > /etc/hostname

# Install and configure bootloader
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARTIX
grub-mkconfig -o /boot/grub/grub.cfg


# Configure snapper for root filesystem
snapper -c root create-config /
snapper -c root set-config "SUBVOLUME=/"
snapper -c root set-config "ALLOW_USERS=root"
snapper -c root set-config "SYNC_ACL=yes"
snapper -c root set-config "SPACE_LIMIT=0.5"

# Configure snapper for home filesystem
snapper -c home create-config /home
snapper -c home set-config "SUBVOLUME=/home"
snapper -c home set-config "ALLOW_USERS=root"
snapper -c home set-config "SYNC_ACL=yes" 
snapper -c home set-config "SPACE_LIMIT=0.5"

# Change snapshot locations for both configs to use /home/.snapshots
snapper -c root set-config "SNAPPER_CONFIGS=/home/.snapshots"
snapper -c home set-config "SNAPPER_CONFIGS=/home/.snapshots"


# Set up snapshot policies (adjust as needed)
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

# Apply similar settings to home config
snapper -c home set-config "NUMBER_CLEANUP=yes"
snapper -c home set-config "NUMBER_MIN_AGE=1800"
snapper -c home set-config "NUMBER_LIMIT=3"


# Create the unified snapshots directory
mkdir -p /home/.snapshots/{root,home}


# Enable snapper timeline cleanup timer
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer


# Enable necessary services
ln -s /etc/s6/s6-rc.d/source/* /etc/s6/s6-rc.d/user/



# Set root password
echo "Set root password:"
passwd

pacman -Syy android-tools usbutils util-linux cups sane uucp dbus acpi polkit htop seatd --needed

# Prompt to create a regular user
echo ""
echo "=== USER CREATION ==="
read -p "Would you like to create a regular user? (y/N): " create_user

if [[ $create_user =~ ^[Yy]$ ]]; then
    read -p "Enter username: " username
    useradd -m -G wheel,video,audio,input,power,storage,optical,lp,scanner,dbus,adbusers,uucp "$username"
    echo "Set password for $username:"
    passwd "$username"
    echo "User $username created with sudo privileges (member of wheel group)"
    echo "And created with membership in:"
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
else
    echo "Skipping user creation."
fi

EOF

# Post-installation notes
echo "=== Installation complete ==="
echo "Snapshots are stored in /home/.snapshots (both root and home snapshots)"
echo " - Root snapshots: /home/.snapshots/root"
echo " - Home snapshots: /home/.snapshots/home"
echo "Snapper has been configured for:"
echo " - Root filesystem: / (keeps 10 regular + 5 important snapshots)"
echo " - Home directory: /home (keeps 5 snapshots)"
echo ""
echo "=== SNAPPER QUICK START ==="
echo "List snapshots:    snapper -c root list"
echo "Create snapshot:   snapper -c root create -d 'Description'"
echo "Rollback:          snapper -c root rollback [number]"
echo "Diff snapshots:    snapper -c root status [number1]..[number2]"
echo ""
echo "Snapshots are stored in /home/.snapshots for home and /.snapshots for root"
echo ""
echo "=== OPTIONAL NEXT STEPS ==="
echo "You may want to:"
echo "1. Create a user account (recommended): useradd -mG wheel <username>"
echo "2. Install additional packages based on your needs"
echo "3. Configure your desktop environment if desired"
echo "4. Set up snapshot management with snapper or timeshift"

echo ""
echo "These are just suggestions - you can choose which, if any, to follow!"


