#!/bin/bash
# lib/install.sh — package list construction and base system installation

ask_user_info() {
    log_section "Installation Configuration"

    ask_input HOSTNAME "Hostname" "artix"
    ask_input USERNAME "Username"  "user"
    ask_input TIMEZONE "Timezone (e.g. Europe/Kyiv)" "Europe/Kyiv"

    echo ""
    echo -e "${CYAN}Root password:${NC}"
    read -rs ROOT_PASSWORD; echo ""
    echo -e "${CYAN}Confirm root password:${NC}"
    read -rs ROOT_PASSWORD2; echo ""
    [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD2" ]] || die "Root passwords do not match"
    [[ -n "$ROOT_PASSWORD" ]] || die "Root password cannot be empty"

    echo ""
    echo -e "${CYAN}Password for user '${USERNAME}':${NC}"
    read -rs USER_PASSWORD; echo ""
    echo -e "${CYAN}Confirm password:${NC}"
    read -rs USER_PASSWORD2; echo ""
    [[ "$USER_PASSWORD" == "$USER_PASSWORD2" ]] || die "User passwords do not match"
    [[ -n "$USER_PASSWORD" ]] || die "User password cannot be empty"

    echo ""
    log_info "Hostname : $HOSTNAME"
    log_info "Username : $USERNAME"
    log_info "Timezone : $TIMEZONE"

    export HOSTNAME USERNAME TIMEZONE ROOT_PASSWORD USER_PASSWORD
}

build_package_list() {
    # --- Base + OpenRC ---
    local base_pkgs=(
        base base-devel
        openrc elogind-openrc
        linux linux-firmware linux-headers
        sudo nano vim git curl wget
        bash-completion
        man-db man-pages
        terminus-font
    )

    # --- CPU microcode ---
    local ucode_pkgs=()
    [[ -n "${CPU_UCODE:-}" ]] && ucode_pkgs=("$CPU_UCODE")

    # --- Bootloader ---
    local boot_pkgs=(grub os-prober)
    [[ "$BOOT_MODE" == "uefi" ]] && boot_pkgs+=(efibootmgr)

    # --- GPU drivers (detected earlier) ---
    local gpu_pkgs=()
    if [[ -n "${GPU_PACKAGES:-}" ]]; then
        read -ra gpu_pkgs <<< "$GPU_PACKAGES"
    fi

    # --- Network ---
    local net_pkgs=(
        networkmanager networkmanager-openrc
        wpa_supplicant dhcpcd
        iw iwd
    )

    # --- Audio: PipeWire + full compat stack ---
    local audio_pkgs=(
        pipewire
        pipewire-alsa
        pipewire-pulse
        pipewire-jack
        wireplumber
        xdg-desktop-portal
        xdg-desktop-portal-kde
    )

    # --- KDE Plasma (minimal, Wayland) ---
    # plasma-desktop pulls in: plasma-workspace, kwin, kscreen, etc.
    local plasma_pkgs=(
        plasma-desktop
        powerdevil
        plasma-nm
        bluedevil
        kscreen
        sddm
        sddm-openrc
        qt6-wayland
        qt5-wayland
        wayland-protocols
        xdg-utils
        # Basic applications (minimal set)
        konsole
        dolphin
        kate
        ark
        spectacle
        gwenview
        # Fonts for UI
        noto-fonts
        noto-fonts-emoji
    )

    # --- Bluetooth ---
    local bt_pkgs=(
        bluez
        bluez-utils
        bluez-openrc
    )

    # --- System utilities ---
    local sys_pkgs=(
        ntfs-3g
        exfatprogs
        dosfstools
        upower
        acpi
        unzip
        zip
        p7zip
        xdg-user-dirs
        htop
        chrony
        chrony-openrc
        dbus
        dbus-openrc
    )

    ALL_PACKAGES=(
        "${base_pkgs[@]}"
        "${ucode_pkgs[@]}"
        "${boot_pkgs[@]}"
        "${gpu_pkgs[@]}"
        "${net_pkgs[@]}"
        "${audio_pkgs[@]}"
        "${plasma_pkgs[@]}"
        "${bt_pkgs[@]}"
        "${sys_pkgs[@]}"
    )

    export ALL_PACKAGES
}

install_base() {
    log_section "Installing Base System via basestrap"

    build_package_list

    log_step "Package groups:"
    echo "  Base+OpenRC : base base-devel openrc elogind-openrc linux linux-firmware"
    echo "  CPU ucode   : ${CPU_UCODE:-none}"
    echo "  GPU drivers : ${GPU_PACKAGES:-none}"
    echo "  Network     : networkmanager networkmanager-openrc ..."
    echo "  Audio       : pipewire pipewire-pulse pipewire-alsa wireplumber ..."
    echo "  Desktop     : plasma-desktop sddm sddm-openrc konsole dolphin ..."
    echo "  Bluetooth   : bluez bluez-utils bluez-openrc"
    echo ""

    log_step "Starting basestrap (this will take a while)..."
    basestrap "$MOUNTPOINT" "${ALL_PACKAGES[@]}" \
        || die "basestrap failed — check internet connection and package names"

    log_info "Base system installed successfully"
}

generate_fstab() {
    log_section "Generating /etc/fstab"

    fstabgen -U "$MOUNTPOINT" >> "$MOUNTPOINT/etc/fstab"

    # SSD: add discard option for TRIM support
    if [[ "$DISK_TYPE" == "ssd" ]]; then
        sed -i '/ext4/ s/relatime/relatime,discard/' "$MOUNTPOINT/etc/fstab"
        log_info "Added 'discard' option to ext4 partitions (SSD TRIM)"
    fi

    log_step "Generated fstab:"
    cat "$MOUNTPOINT/etc/fstab"
}
