#!/bin/bash
# Simple Artix Linux installer (OpenRC + KDE Plasma + PipeWire + Wayland)
# Run as root from an Artix Linux live ISO.

set -euo pipefail

# -----------------------------------------------------------------------------
# Settings
# -----------------------------------------------------------------------------
MOUNTPOINT="/mnt"
HOSTNAME=""
USERNAME=""
TIMEZONE=""
BOOT_MODE=""
DISK=""
DISK_TYPE=""
SWAP_GB=""
CPU_UCODE=""
GPU_TYPE=""
GPU_PACKAGES=""
ROOT_PASSWORD=""
USER_PASSWORD=""

PART_EFI=""
PART_SWAP=""
PART_ROOT=""

# If true, no disk or system changes are made; commands are only printed.
DRY_RUN=false

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

msg() {
    echo "==> $*"
}

error() {
    echo "ERROR: $*" >&2
    exit 1
}

# Ask a question and save the answer into the variable whose name is passed.
ask() {
    local varname="$1"
    local prompt="$2"
    local default="${3:-}"
    local value

    if [[ -n "$default" ]]; then
        read -rp "$prompt [$default]: " value
    else
        read -rp "$prompt: " value
    fi

    printf -v "$varname" '%s' "${value:-$default}"
}

confirm() {
    local prompt="${1:-Continue?}"
    local answer
    read -rp "$prompt [y/N]: " answer
    [[ "${answer,,}" =~ ^y(es)?$ ]]
}

# Convert partition number into the correct device name.
get_part() {
    local disk="$1"
    local num="$2"

    if [[ "$disk" == *nvme* ]] || [[ "$disk" == *mmcblk* ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# Execute a command, or just print it in dry-run mode.
run() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------

check_root() {
    if [[ "$DRY_RUN" == true ]]; then
        msg "[DRY-RUN] Skipping root check"
        return
    fi
    [[ "$EUID" -eq 0 ]] || error "Run this script as root"
}

check_network() {
    if [[ "$DRY_RUN" == true ]]; then
        msg "[DRY-RUN] Would check internet connection"
        return
    fi

    msg "Checking internet connection..."
    if ! curl -s --max-time 5 https://archlinux.org >/dev/null; then
        error "No internet connection. Please check your network."
    fi
}

detect_boot_mode() {
    if [[ -d /sys/firmware/efi/efivars ]]; then
        BOOT_MODE="uefi"
    else
        BOOT_MODE="bios"
    fi
    msg "Boot mode: $BOOT_MODE"
}

# -----------------------------------------------------------------------------
# Hardware detection
# -----------------------------------------------------------------------------

detect_cpu() {
    if grep -qi "intel" /proc/cpuinfo; then
        CPU_UCODE="intel-ucode"
    elif grep -qi "amd" /proc/cpuinfo; then
        CPU_UCODE="amd-ucode"
    else
        CPU_UCODE=""
    fi
    msg "CPU microcode package: ${CPU_UCODE:-none}"
}

detect_gpu() {
    local gpu_info
    gpu_info=$(lspci 2>/dev/null | grep -iE "VGA compatible|3D controller|Display controller" || true)

    if [[ -z "$gpu_info" ]]; then
        GPU_TYPE="generic"
        GPU_PACKAGES="mesa xf86-video-vesa"
        msg "No GPU found via lspci, using generic drivers"
        return
    fi

    msg "Detected GPU(s):"
    echo "$gpu_info" | sed 's/^/    /'

    if echo "$gpu_info" | grep -qi "intel" && echo "$gpu_info" | grep -qi "nvidia"; then
        GPU_TYPE="hybrid-nvidia"
        GPU_PACKAGES="mesa vulkan-intel intel-media-driver libva-intel-driver lib32-mesa lib32-vulkan-intel nvidia-dkms nvidia-utils nvidia-prime lib32-nvidia-utils"
    elif echo "$gpu_info" | grep -qi "nvidia"; then
        GPU_TYPE="nvidia"
        GPU_PACKAGES="nvidia-dkms nvidia-utils nvidia-settings lib32-nvidia-utils"
    elif echo "$gpu_info" | grep -qiE "amd|radeon|advanced micro devices"; then
        GPU_TYPE="amd"
        GPU_PACKAGES="mesa vulkan-radeon xf86-video-amdgpu libva-mesa-driver lib32-mesa lib32-vulkan-radeon"
    elif echo "$gpu_info" | grep -qi "intel"; then
        GPU_TYPE="intel"
        GPU_PACKAGES="mesa vulkan-intel intel-media-driver libva-intel-driver lib32-mesa lib32-vulkan-intel"
    else
        GPU_TYPE="generic"
        GPU_PACKAGES="mesa xf86-video-vesa"
    fi

    msg "GPU type: $GPU_TYPE"
}

# -----------------------------------------------------------------------------
# Disk selection
# -----------------------------------------------------------------------------

select_disk() {
    msg "Available disks:"

    # Read disk list into an array (one line per disk).
    mapfile -t disks < <(lsblk -d -o NAME,SIZE,MODEL --noheadings | grep -vE '^(loop|sr|fd)')

    local i=1
    local line
    for line in "${disks[@]}"; do
        echo "  $i) $line"
        ((i++))
    done

    local choice
    ask choice "Select disk number"

    # Validate choice.
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#disks[@]} )); then
        error "Invalid choice"
    fi

    # Extract the device name from the chosen line.
    DISK="/dev/$(awk '{print $1}' <<< "${disks[$((choice-1))]}")"
    [[ -b "$DISK" ]] || error "Not a block device: $DISK"

    msg "Selected disk: $DISK"
}

check_disk_safety() {
    # SSD or HDD.
    local devname="${DISK##*/}"
    local rotational
    rotational=$(cat "/sys/block/${devname}/queue/rotational" 2>/dev/null || echo 1)

    if [[ "$rotational" == "0" ]]; then
        DISK_TYPE="ssd"
        msg "Disk type: SSD"
    else
        DISK_TYPE="hdd"
        msg "Disk type: HDD"
    fi

    # Check whether any partition is mounted.
    local mounted
    mounted=$(lsblk -n -o MOUNTPOINT "$DISK" | tr -d '[:space:]')
    if [[ -n "$mounted" ]]; then
        msg "WARNING: Some partitions on $DISK are currently mounted."
        confirm "Unmount them and continue?" || error "Cancelled"
    fi
}

# -----------------------------------------------------------------------------
# Partition plan
# -----------------------------------------------------------------------------

plan_partitions() {
    local ram_kb ram_gb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    ram_gb=$(( (ram_kb + 1048575) / 1048576 ))

    if (( ram_gb <= 2 )); then
        SWAP_GB=$(( ram_gb * 2 ))
    elif (( ram_gb <= 8 )); then
        SWAP_GB=$ram_gb
    else
        SWAP_GB=8
    fi

    msg "RAM: ${ram_gb} GB -> swap: ${SWAP_GB} GB"

    # Make sure the disk is big enough (EFI 512 MiB + swap + 5 GiB root).
    local disk_bytes disk_mib required_mib
    disk_bytes=$(lsblk -d -b -o SIZE --noheadings "$DISK" | tr -d ' ')
    disk_mib=$(( disk_bytes / 1024 / 1024 ))

    if [[ "$BOOT_MODE" == "uefi" ]]; then
        required_mib=$(( 513 + SWAP_GB * 1024 + 5120 ))
    else
        required_mib=$(( 1 + SWAP_GB * 1024 + 5120 ))
    fi

    if (( disk_mib < required_mib )); then
        error "Disk is too small. Need at least ${required_mib} MiB."
    fi

    # Show plan.
    echo ""
    echo "Partition plan:"
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        echo "  1) 512 MiB  EFI   (fat32)"
        echo "  2) ${SWAP_GB} GiB  swap"
        echo "  3) rest      root  (ext4)"
    else
        echo "  1) ${SWAP_GB} GiB  swap"
        echo "  2) rest      root  (ext4, bootable)"
    fi
    echo ""

    msg "WARNING: All data on $DISK will be erased."
    confirm "Continue with partitioning?" || error "Cancelled"
}

# -----------------------------------------------------------------------------
# Partition, format, mount
# -----------------------------------------------------------------------------

do_partition() {
    msg "Wiping $DISK..."
    run wipefs -af "$DISK" >/dev/null 2>&1 || true
    run sgdisk --zap-all "$DISK" >/dev/null 2>&1 || true
    sync

    local swap_mb=$(( SWAP_GB * 1024 ))

    if [[ "$BOOT_MODE" == "uefi" ]]; then
        local efi_end=513
        local swap_end=$(( efi_end + swap_mb ))

        run parted -s -a optimal "$DISK" mklabel gpt
        run parted -s -a optimal "$DISK" mkpart EFI fat32 1MiB ${efi_end}MiB
        run parted -s "$DISK" set 1 esp on
        run parted -s -a optimal "$DISK" mkpart SWAP linux-swap ${efi_end}MiB ${swap_end}MiB
        run parted -s -a optimal "$DISK" mkpart ROOT ext4 ${swap_end}MiB 100%

        PART_EFI=$(get_part "$DISK" 1)
        PART_SWAP=$(get_part "$DISK" 2)
        PART_ROOT=$(get_part "$DISK" 3)
    else
        local swap_end=$(( 1 + swap_mb ))

        run parted -s -a optimal "$DISK" mklabel msdos
        run parted -s -a optimal "$DISK" mkpart primary linux-swap 1MiB ${swap_end}MiB
        run parted -s -a optimal "$DISK" mkpart primary ext4 ${swap_end}MiB 100%
        run parted -s "$DISK" set 2 boot on

        PART_EFI=""
        PART_SWAP=$(get_part "$DISK" 1)
        PART_ROOT=$(get_part "$DISK" 2)
    fi

    run partprobe "$DISK"
    sleep 2
    run udevadm settle
}

do_format() {
    if [[ -n "$PART_EFI" ]]; then
        msg "Formatting EFI partition..."
        run mkfs.fat -F32 -n ESP "$PART_EFI"
    fi

    msg "Formatting swap partition..."
    run mkswap -L SWAP "$PART_SWAP"

    msg "Formatting root partition..."
    run mkfs.ext4 -L ROOT -F "$PART_ROOT"
}

do_mount() {
    msg "Mounting root..."
    run mount "$PART_ROOT" "$MOUNTPOINT"

    if [[ -n "$PART_EFI" ]]; then
        msg "Mounting EFI partition..."
        run mkdir -p "$MOUNTPOINT/boot/efi"
        run mount "$PART_EFI" "$MOUNTPOINT/boot/efi"
    fi

    msg "Enabling swap..."
    run swapon "$PART_SWAP"
}

# -----------------------------------------------------------------------------
# User configuration
# -----------------------------------------------------------------------------

ask_user_info() {
    ask HOSTNAME "Hostname" "artix"
    ask USERNAME "Username" "user"

    while true; do
        ask TIMEZONE "Timezone (e.g. Europe/Kyiv)" "Europe/Kyiv"
        if [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
            break
        fi
        echo "Invalid timezone. Try again."
    done

    while true; do
        read -rsp "Root password: " ROOT_PASSWORD; echo
        read -rsp "Confirm root password: " pass2; echo
        [[ "$ROOT_PASSWORD" == "$pass2" ]] && [[ -n "$ROOT_PASSWORD" ]] && break
        echo "Passwords do not match or are empty. Try again."
    done

    while true; do
        read -rsp "Password for $USERNAME: " USER_PASSWORD; echo
        read -rsp "Confirm password: " pass2; echo
        [[ "$USER_PASSWORD" == "$pass2" ]] && [[ -n "$USER_PASSWORD" ]] && break
        echo "Passwords do not match or are empty. Try again."
    done
}

# -----------------------------------------------------------------------------
# Package installation
# -----------------------------------------------------------------------------

build_packages() {
    local base=(
        base base-devel
        openrc elogind-openrc
        linux linux-firmware linux-headers
        sudo nano vim git curl wget
        bash-completion
        man-db man-pages
        terminus-font
    )

    local ucode=()
    [[ -n "$CPU_UCODE" ]] && ucode=("$CPU_UCODE")

    local boot=(grub os-prober)
    [[ "$BOOT_MODE" == "uefi" ]] && boot+=(efibootmgr)

    local gpu=()
    read -ra gpu <<< "$GPU_PACKAGES"

    local net=(
        networkmanager networkmanager-openrc
        wpa_supplicant dhcpcd
        iw iwd
    )

    local audio=(
        pipewire pipewire-alsa pipewire-pulse pipewire-jack
        wireplumber
        xdg-desktop-portal xdg-desktop-portal-kde
    )

    local plasma=(
        plasma-desktop
        powerdevil
        plasma-nm
        bluedevil
        kscreen
        sddm sddm-openrc
        qt6-wayland qt5-wayland
        wayland-protocols
        xdg-utils
        konsole dolphin kate ark spectacle gwenview
        noto-fonts noto-fonts-emoji
    )

    local bt=(bluez bluez-utils bluez-openrc)

    local utils=(
        ntfs-3g exfatprogs dosfstools
        upower acpi
        unzip zip p7zip
        xdg-user-dirs
        htop
        chrony chrony-openrc
        dbus dbus-openrc
    )

    PACKAGES=(
        "${base[@]}"
        "${ucode[@]}"
        "${boot[@]}"
        "${gpu[@]}"
        "${net[@]}"
        "${audio[@]}"
        "${plasma[@]}"
        "${bt[@]}"
        "${utils[@]}"
    )
}

install_base() {
    msg "Installing base system. This may take a while..."

    build_packages

    if [[ "$DRY_RUN" == true ]]; then
        msg "[DRY-RUN] Would install ${#PACKAGES[@]} packages via basestrap"
        return
    fi

    echo ""
    echo "You may be asked to choose a provider for some packages."
    echo "Recommended: iptables-nft, mkinitcpio, xorg-server."
    echo ""

    run basestrap "$MOUNTPOINT" "${PACKAGES[@]}"
}

generate_fstab() {
    if [[ "$DRY_RUN" == true ]]; then
        msg "[DRY-RUN] Would generate /etc/fstab"
        return
    fi

    msg "Generating /etc/fstab..."

    # Overwrite, not append.
    fstabgen -U "$MOUNTPOINT" > "$MOUNTPOINT/etc/fstab"

    if [[ "$DISK_TYPE" == "ssd" ]]; then
        sed -i '/ext4/ s/relatime/relatime,discard/' "$MOUNTPOINT/etc/fstab"
        msg "Enabled discard for SSD"
    fi
}

# -----------------------------------------------------------------------------
# Chroot configuration
# -----------------------------------------------------------------------------

write_config() {
    msg "Writing install config for chroot..."

    {
        printf 'HOSTNAME=%q\n' "$HOSTNAME"
        printf 'USERNAME=%q\n' "$USERNAME"
        printf 'TIMEZONE=%q\n' "$TIMEZONE"
        printf 'BOOT_MODE=%q\n' "$BOOT_MODE"
        printf 'DISK=%q\n' "$DISK"
        printf 'DISK_TYPE=%q\n' "$DISK_TYPE"
        printf 'GPU_TYPE=%q\n' "$GPU_TYPE"
    } > "$MOUNTPOINT/root/install-config.sh"

    printf '%s' "$ROOT_PASSWORD" > "$MOUNTPOINT/root/.rootpw"
    printf '%s' "$USER_PASSWORD" > "$MOUNTPOINT/root/.userpw"
    chmod 600 "$MOUNTPOINT/root/.rootpw" "$MOUNTPOINT/root/.userpw"
}

write_chroot_script() {
    msg "Writing chroot setup script..."

    cat > "$MOUNTPOINT/root/chroot-setup.sh" <<'CHROOT_SCRIPT'
#!/bin/bash
set -euo pipefail

source /root/install-config.sh
ROOT_PASSWORD=$(cat /root/.rootpw)
USER_PASSWORD=$(cat /root/.userpw)
rm -f /root/.rootpw /root/.userpw

# --- Timezone ---
echo "Setting timezone to $TIMEZONE..."
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

# --- Locale ---
echo "Generating locales..."
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
sed -i 's/^#uk_UA.UTF-8/uk_UA.UTF-8/' /etc/locale.gen
locale-gen

echo "LANG=en_US.UTF-8" > /etc/locale.conf

cat > /etc/vconsole.conf <<EOF
KEYMAP=us
FONT=ter-v16n
EOF

# --- Hostname ---
echo "$HOSTNAME" > /etc/hostname
echo "hostname='$HOSTNAME'" > /etc/conf.d/hostname

cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain  ${HOSTNAME}
EOF

# --- Pacman ---
sed -i 's/^#Color/Color/' /etc/pacman.conf

# --- GRUB ---
if [[ "$BOOT_MODE" == "uefi" ]]; then
    echo "Installing GRUB for UEFI..."
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Artix --recheck
else
    echo "Installing GRUB for BIOS on $DISK..."
    grub-install --target=i386-pc --recheck "$DISK"
fi

if grep -q '^#*GRUB_DISABLE_OS_PROBER' /etc/default/grub; then
    sed -i 's/^#*GRUB_DISABLE_OS_PROBER.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
else
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
fi

grub-mkconfig -o /boot/grub/grub.cfg

# --- Services ---
echo "Enabling services..."
rc-update add dbus default
rc-update add elogind boot
rc-update add NetworkManager default
rc-update add chronyd default
rc-update add bluetoothd default || echo "Bluetooth service not found, skipping"
rc-update add sddm default

if [[ "$DISK_TYPE" == "ssd" ]]; then
    echo "Setting up weekly TRIM..."
    cat > /etc/cron.weekly/fstrim <<EOF
#!/bin/sh
/sbin/fstrim -av
EOF
    chmod +x /etc/cron.weekly/fstrim
fi

# --- Users ---
echo "Setting root password..."
echo "root:${ROOT_PASSWORD}" | chpasswd

echo "Creating user $USERNAME..."
useradd -m -G wheel,audio,video,storage,optical,network,input,lp -s /bin/bash "$USERNAME"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# --- SDDM ---
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/artix.conf <<EOF
[Theme]
Current=breeze

[Users]
MaximumUid=60000
MinimumUid=1000
EOF

# --- PipeWire autostart ---
autostart_dir="/home/$USERNAME/.config/autostart"
mkdir -p "$autostart_dir"

cat > "$autostart_dir/pipewire.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=PipeWire
Exec=pipewire
EOF

cat > "$autostart_dir/wireplumber.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=WirePlumber
Exec=wireplumber
EOF

chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"

# --- User directories ---
su -c "xdg-user-dirs-update" "$USERNAME" || true

# --- NVIDIA Wayland tweaks ---
if [[ "$GPU_TYPE" == "nvidia" || "$GPU_TYPE" == "hybrid-nvidia" ]]; then
    echo "Applying NVIDIA Wayland settings..."

    if ! grep -q "nvidia-drm.modeset=1" /etc/default/grub; then
        sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 nvidia-drm.modeset=1"/' /etc/default/grub
    fi

    if ! grep -q "nvidia" /etc/mkinitcpio.conf; then
        sed -i 's/^MODULES=(\(.*\))/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm \1)/' /etc/mkinitcpio.conf
    fi

    mkinitcpio -P
    grub-mkconfig -o /boot/grub/grub.cfg
fi

echo "Chroot setup complete."
CHROOT_SCRIPT

    chmod +x "$MOUNTPOINT/root/chroot-setup.sh"
}

run_chroot() {
    if [[ "$DRY_RUN" == true ]]; then
        msg "[DRY-RUN] Would write config and run chroot setup"
        return
    fi

    write_config
    write_chroot_script

    msg "Running configuration inside chroot..."
    run artix-chroot "$MOUNTPOINT" /root/chroot-setup.sh

    msg "Cleaning up temporary files..."
    rm -f "$MOUNTPOINT/root/install-config.sh"
    rm -f "$MOUNTPOINT/root/chroot-setup.sh"
    rm -f "$MOUNTPOINT/root/.rootpw"
    rm -f "$MOUNTPOINT/root/.userpw"
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------

cleanup() {
    if [[ -d "$MOUNTPOINT" ]] && mountpoint -q "$MOUNTPOINT"; then
        msg "Unmounting target system..."
        swapoff "${PART_SWAP:-}" 2>/dev/null || true
        umount -R "$MOUNTPOINT" 2>/dev/null || true
    fi
}

trap cleanup EXIT

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    check_root
    detect_boot_mode

    echo ""
    echo "Artix Linux installer (OpenRC + KDE Plasma + Wayland)"
    if [[ "$DRY_RUN" == true ]]; then
        echo "DRY-RUN mode: no changes will be made to any disk."
    else
        echo "Target disk will be COMPLETELY ERASED."
    fi
    echo ""
    confirm "Start the installer?" || { echo "Bye."; exit 0; }

    check_network
    detect_cpu
    detect_gpu

    select_disk
    check_disk_safety
    plan_partitions
    do_partition
    do_format
    do_mount

    ask_user_info
    install_base

    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        msg "DRY-RUN complete. Summary:"
        echo "  Hostname : $HOSTNAME"
        echo "  Username : $USERNAME"
        echo "  Timezone : $TIMEZONE"
        echo "  Boot mode: $BOOT_MODE"
        echo "  Disk     : $DISK"
        echo "  Disk type: $DISK_TYPE"
        echo "  Swap     : ${SWAP_GB} GiB"
        echo "  GPU      : $GPU_TYPE"
        echo "  Packages : ${#PACKAGES[@]}"
        exit 0
    fi

    generate_fstab
    run_chroot

    echo ""
    msg "Installation finished."
    echo "Login: $USERNAME"
    echo "At SDDM choose 'Plasma (Wayland)'."
    echo ""
    confirm "Reboot now?" && reboot
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------

if [[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]]; then
    DRY_RUN=true
    msg "Dry-run mode enabled. No disk changes will be made."
    shift
fi

main "$@"
