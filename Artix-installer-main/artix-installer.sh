#!/bin/bash
# artix-installer.sh — Artix Linux Installer
#
# Stack:
#   Init    : OpenRC + elogind
#   Desktop : KDE Plasma (minimal, Wayland)
#   Audio   : PipeWire + WirePlumber
#   Network : NetworkManager
#   Boot    : GRUB (UEFI/BIOS auto-detected)
#
# Usage: run as root from an Artix Linux live ISO

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source modules ─────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/detect.sh"
source "${SCRIPT_DIR}/lib/disk.sh"
source "${SCRIPT_DIR}/lib/install.sh"
source "${SCRIPT_DIR}/lib/configure.sh"

export SCRIPT_DIR

# ── Cleanup on any exit ────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    if (( exit_code != 0 )); then
        echo ""
        log_warn "Installer exited with error (code $exit_code)"
        log_warn "Attempting to unmount filesystems..."
    fi
    swapoff "${PART_SWAP:-}" 2>/dev/null || true
    umount -R "${MOUNTPOINT:-/mnt}" 2>/dev/null || true
}
trap cleanup EXIT

# ── Welcome screen ─────────────────────────────────────────────────
show_welcome() {
    clear
    echo -e "${BOLD}${BLUE}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║           ARTIX LINUX INSTALLER                      ║"
    echo "  ║   OpenRC  |  KDE Plasma  |  PipeWire  |  Wayland    ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "  This installer will:"
    echo "    1. Detect your hardware (CPU, GPU)"
    echo "    2. Partition and format the chosen disk automatically"
    echo "    3. Install Artix Linux with OpenRC"
    echo "    4. Install KDE Plasma (minimal) with Wayland"
    echo "    5. Install PipeWire audio stack"
    echo "    6. Install correct drivers for your hardware"
    echo "    7. Configure the system and create your user"
    echo ""
    log_warn "The target disk will be COMPLETELY ERASED."
    echo ""
    confirm "Start the installer?" || { echo "Bye."; exit 0; }
}

# ── Finish ─────────────────────────────────────────────────────────
show_finish() {
    log_section "Installation Finished!"
    echo ""
    echo -e "  ${GREEN}Artix Linux is installed and ready.${NC}"
    echo ""
    echo "  What to do next:"
    echo "    1. Remove the installation media (USB/CD)"
    echo "    2. Reboot"
    echo "    3. At the SDDM login screen, choose 'Plasma (Wayland)' session"
    echo "    4. Login as: ${BOLD}${USERNAME}${NC}"
    echo ""

    confirm "Reboot now?" && reboot
}

# ── Main flow ──────────────────────────────────────────────────────
main() {
    check_root
    detect_boot_mode
    show_welcome

    # Step 1: Hardware detection
    detect_cpu
    detect_gpu

    # Step 2: Disk setup
    select_disk
    plan_partitions
    do_partition
    do_format
    do_mount

    # Step 3: User preferences
    ask_user_info

    # Step 4: Install packages
    install_base
    generate_fstab

    # Step 5: Configure system inside chroot
    run_chroot_config

    show_finish
}

main
