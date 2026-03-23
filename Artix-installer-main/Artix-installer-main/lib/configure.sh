#!/bin/bash
# lib/configure.sh — writes config into /mnt and runs chroot-setup.sh inside chroot

run_chroot_config() {
    log_section "Configuring Installed System (chroot)"

    # Write all variables the chroot script needs into a config file
    log_step "Writing install config..."
    cat > "$MOUNTPOINT/root/install-config.sh" << EOF
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
TIMEZONE="$TIMEZONE"
BOOT_MODE="$BOOT_MODE"
DISK="$DISK"
DISK_TYPE="$DISK_TYPE"
GPU_TYPE="$GPU_TYPE"
EOF

    # Passwords go into separate files so special characters cannot break anything
    printf '%s' "$ROOT_PASSWORD" > "$MOUNTPOINT/root/.rootpw"
    printf '%s' "$USER_PASSWORD" > "$MOUNTPOINT/root/.userpw"
    chmod 600 "$MOUNTPOINT/root/.rootpw" "$MOUNTPOINT/root/.userpw"

    # Copy the chroot script into /mnt
    local chroot_script="${SCRIPT_DIR}/lib/chroot-setup.sh"
    [[ -f "$chroot_script" ]] || die "chroot-setup.sh not found: $chroot_script"
    cp "$chroot_script" "$MOUNTPOINT/root/chroot-setup.sh"
    chmod +x "$MOUNTPOINT/root/chroot-setup.sh"

    log_step "Entering chroot and running setup..."
    artix-chroot "$MOUNTPOINT" /root/chroot-setup.sh \
        || die "chroot configuration failed"

    # Clean up sensitive files
    rm -f "$MOUNTPOINT/root/install-config.sh"
    rm -f "$MOUNTPOINT/root/chroot-setup.sh"
    rm -f "$MOUNTPOINT/root/.rootpw"
    rm -f "$MOUNTPOINT/root/.userpw"

    log_info "Chroot configuration complete"
}
