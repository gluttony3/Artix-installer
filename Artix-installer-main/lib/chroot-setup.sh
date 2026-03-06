#!/bin/bash
# lib/chroot-setup.sh — runs INSIDE artix-chroot after basestrap
# All configuration values come from /root/install-config.sh

set -euo pipefail

# ── Colors (same as common.sh, standalone here) ────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[!!]${NC} $*"; }
log_step()    { echo -e "  ${CYAN}-->${NC} $*"; }
log_section() {
    echo ""
    echo -e "${BOLD}${BLUE}============================================${NC}"
    echo -e "${BOLD}${BLUE}  $*${NC}"
    echo -e "${BOLD}${BLUE}============================================${NC}"
}
die() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Load config ────────────────────────────────────────────────────
[[ -f /root/install-config.sh ]] || die "/root/install-config.sh not found"
# shellcheck source=/dev/null
source /root/install-config.sh

ROOT_PASSWORD="$(cat /root/.rootpw)"
USER_PASSWORD="$(cat /root/.userpw)"
# Remove password files immediately after reading
rm -f /root/.rootpw /root/.userpw

# ── Pacman setup ───────────────────────────────────────────────────
log_section "Configuring Pacman"
log_step "Enabling Color and ParallelDownloads..."
sed -i 's/^#Color/Color/'                        /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf

# Enable multilib (needed for 32-bit libs: Wine, Steam, etc.)
# Only enable if section exists but is commented out
if grep -q '^\[multilib\]' /etc/pacman.conf; then
    log_step "multilib already enabled"
elif grep -q '^#\[multilib\]' /etc/pacman.conf; then
    log_step "Enabling multilib..."
    sed -i '/^#\[multilib\]/{
        s/^#//
        n
        s/^#//
    }' /etc/pacman.conf
fi

pacman -Sy --noconfirm 2>&1 | tail -5

# ── Timezone ───────────────────────────────────────────────────────
log_section "Timezone: $TIMEZONE"
[[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] \
    || die "Timezone not found: /usr/share/zoneinfo/$TIMEZONE"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
log_info "Timezone set: $TIMEZONE"

# ── Locale ─────────────────────────────────────────────────────────
log_section "Locale Configuration"
log_step "Uncommenting en_US.UTF-8 and uk_UA.UTF-8..."
sed -i 's/^#\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(uk_UA\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen

cat > /etc/locale.conf << 'LOCEOF'
LANG=en_US.UTF-8
LC_TIME=uk_UA.UTF-8
LC_PAPER=uk_UA.UTF-8
LOCEOF

# Console font with Cyrillic support
cat > /etc/vconsole.conf << 'VCEOF'
KEYMAP=us
FONT=ter-v16n
VCEOF
log_info "Locale configured"

# ── Hostname ───────────────────────────────────────────────────────
log_section "Hostname: $HOSTNAME"
echo "$HOSTNAME" > /etc/hostname
echo "hostname='${HOSTNAME}'" > /etc/conf.d/hostname

cat > /etc/hosts << HOSTEOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain  ${HOSTNAME}
HOSTEOF
log_info "Hostname configured: $HOSTNAME"

# ── Bootloader (GRUB) ──────────────────────────────────────────────
log_section "Installing GRUB Bootloader"
if [[ "$BOOT_MODE" == "uefi" ]]; then
    log_step "UEFI mode -> grub-install (x86_64-efi)"
    grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --bootloader-id=Artix \
        --recheck \
        || die "grub-install (UEFI) failed"
else
    log_step "BIOS mode -> grub-install (i386-pc) on $DISK"
    grub-install \
        --target=i386-pc \
        --recheck \
        "$DISK" \
        || die "grub-install (BIOS) failed"
fi

# Let GRUB detect other OSes
sed -i 's/^#\?GRUB_DISABLE_OS_PROBER.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub \
    || echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub

grub-mkconfig -o /boot/grub/grub.cfg
log_info "GRUB installed and configured"

# ── OpenRC services ────────────────────────────────────────────────
log_section "Enabling OpenRC Services"

# dbus — needed by almost everything
rc-update add dbus default      && log_step "dbus -> default"

# elogind — seat/session management (runs at boot level)
rc-update add elogind boot      && log_step "elogind -> boot"

# NetworkManager
rc-update add NetworkManager default && log_step "NetworkManager -> default"

# Time sync (chrony)
rc-update add chronyd default   && log_step "chronyd -> default"

# Bluetooth
rc-update add bluetoothd default && log_step "bluetoothd -> default" || \
    log_warn "bluetoothd service not found, skipping"

# SDDM display manager
rc-update add sddm default      && log_step "sddm -> default"

# SSD TRIM (weekly via cron)
if [[ "$DISK_TYPE" == "ssd" ]]; then
    if [[ -d /etc/cron.weekly ]]; then
        echo '#!/bin/sh' > /etc/cron.weekly/fstrim
        echo '/sbin/fstrim -av' >> /etc/cron.weekly/fstrim
        chmod +x /etc/cron.weekly/fstrim
        log_step "Weekly fstrim cron job added (SSD)"
    fi
fi

log_info "OpenRC services configured"

# ── Root password ──────────────────────────────────────────────────
log_section "Setting Root Password"
echo "root:${ROOT_PASSWORD}" | chpasswd
log_info "Root password set"

# ── User account ───────────────────────────────────────────────────
log_section "Creating User: $USERNAME"
useradd -m \
    -G wheel,audio,video,storage,optical,network,input,lp \
    -s /bin/bash \
    "$USERNAME"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
log_info "User '$USERNAME' created"

# sudo: wheel group can use sudo with password
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel
log_step "sudo configured for wheel group"

# ── SDDM configuration ─────────────────────────────────────────────
log_section "Configuring SDDM"
mkdir -p /etc/sddm.conf.d

cat > /etc/sddm.conf.d/artix.conf << 'SDDMEOF'
[Theme]
Current=breeze

[Users]
MaximumUid=60000
MinimumUid=1000
SDDMEOF

log_info "SDDM configured with Breeze theme"

# ── PipeWire: user autostart ───────────────────────────────────────
# KDE Plasma 6 on Wayland starts pipewire automatically via plasma-workspace,
# but we add explicit autostart entries as a fallback for OpenRC (no systemd user sessions)
log_section "PipeWire Autostart"

USER_HOME="/home/${USERNAME}"
AUTOSTART_DIR="${USER_HOME}/.config/autostart"
mkdir -p "$AUTOSTART_DIR"

cat > "${AUTOSTART_DIR}/pipewire.desktop" << 'PWEOF'
[Desktop Entry]
Type=Application
Name=PipeWire
Exec=pipewire
Hidden=false
X-KDE-autostart-phase=1
PWEOF

cat > "${AUTOSTART_DIR}/wireplumber.desktop" << 'WPEOF'
[Desktop Entry]
Type=Application
Name=WirePlumber
Exec=wireplumber
Hidden=false
X-KDE-autostart-phase=1
WPEOF

cat > "${AUTOSTART_DIR}/pipewire-pulse.desktop" << 'PPEOF'
[Desktop Entry]
Type=Application
Name=PipeWire PulseAudio
Exec=pipewire-pulse
Hidden=false
X-KDE-autostart-phase=1
PPEOF

chown -R "${USERNAME}:${USERNAME}" "${USER_HOME}/.config"
log_info "PipeWire autostart entries created for $USERNAME"

# ── XDG user directories ───────────────────────────────────────────
log_section "XDG User Directories"
su -c "xdg-user-dirs-update" "$USERNAME" 2>/dev/null || true
log_info "XDG dirs created"

# ── NVIDIA-specific Wayland setup ─────────────────────────────────
if [[ "$GPU_TYPE" == "nvidia" ]] || [[ "$GPU_TYPE" == "hybrid-nvidia" ]]; then
    log_section "NVIDIA Wayland Configuration"

    log_step "Adding nvidia-drm.modeset=1 to GRUB kernel parameters..."
    sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 nvidia-drm.modeset=1"/' \
        /etc/default/grub

    log_step "Adding NVIDIA modules to initramfs..."
    # Check if MODULES line exists
    if grep -q '^MODULES=' /etc/mkinitcpio.conf; then
        sed -i 's/^MODULES=(\(.*\))/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm \1)/' \
            /etc/mkinitcpio.conf
    else
        echo 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)' >> /etc/mkinitcpio.conf
    fi

    log_step "Regenerating initramfs..."
    mkinitcpio -P

    log_step "Regenerating GRUB config with updated kernel params..."
    grub-mkconfig -o /boot/grub/grub.cfg

    log_info "NVIDIA Wayland configuration complete"
fi

# ── Summary ────────────────────────────────────────────────────────
log_section "Chroot Setup Complete"
echo ""
echo -e "  ${GREEN}System configuration summary:${NC}"
echo "  Hostname  : $HOSTNAME"
echo "  User      : $USERNAME"
echo "  Timezone  : $TIMEZONE"
echo "  Init      : OpenRC + elogind"
echo "  Network   : NetworkManager"
echo "  Desktop   : KDE Plasma (minimal, Wayland)"
echo "  Audio     : PipeWire + WirePlumber"
echo "  Boot      : GRUB ($BOOT_MODE)"
echo "  GPU       : $GPU_TYPE"
echo ""
