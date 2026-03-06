# Artix Linux Installer

A shell-based installer for [Artix Linux](https://artixlinux.org) that automates a complete desktop setup from the live ISO.

**Stack:**
- Init: **OpenRC** + elogind
- Desktop: **KDE Plasma** (minimal, Wayland)
- Audio: **PipeWire** + WirePlumber
- Network: **NetworkManager**
- Bootloader: **GRUB** (UEFI and BIOS)

---

## Features

- Automatic **UEFI / BIOS** detection
- Automatic **SSD / HDD** detection (enables `discard` + `fstrim` for SSDs)
- Automatic **CPU microcode** installation (Intel / AMD)
- Automatic **GPU driver** installation:
  - Intel — `mesa`, `vulkan-intel`, `intel-media-driver`
  - AMD — `mesa`, `vulkan-radeon`, `xf86-video-amdgpu`
  - NVIDIA — `nvidia-dkms` with Wayland DRM modesetting
  - Hybrid Intel+NVIDIA — both driver sets + `nvidia-prime`
- **GPT** partition layout for UEFI, **MBR** for BIOS
- SWAP size = RAM size (capped at 8 GB)
- Minimal KDE Plasma with Wayland session (no bloatware)
- PipeWire autostart entries for OpenRC (no systemd user sessions)

---

## Requirements

- Booted from an **Artix Linux live ISO** (any init variant)
- Working **internet connection**
- Target disk will be **completely erased**

---

## Usage

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/artix-installer.git
cd artix-installer

# Make scripts executable
chmod +x artix-installer.sh lib/*.sh

# Run as root
sudo ./artix-installer.sh
```

The installer will guide you through:
1. Hardware detection (CPU + GPU)
2. Disk selection and automatic partitioning
3. Hostname, username, timezone, and passwords
4. Full system installation and configuration
5. Reboot

---

## Partition Layout

**UEFI (GPT):**
```
Part 1  512 MB   EFI   (FAT32)
Part 2  [RAM]GB  SWAP
Part 3  rest     ROOT  (ext4)
```

**BIOS (MBR):**
```
Part 1  [RAM]GB  SWAP
Part 2  rest     ROOT  (ext4, bootable)
```

---

## File Structure

```
artix-installer.sh      # Entry point
lib/
  common.sh             # Colors, logging, helper functions
  detect.sh             # CPU and GPU hardware detection
  disk.sh               # Disk selection, partitioning, formatting, mounting
  install.sh            # Package list construction and basestrap
  configure.sh          # Chroot orchestrator
  chroot-setup.sh       # Runs inside artix-chroot to configure the system
```

---

## After Installation

At the SDDM login screen, select **"Plasma (Wayland)"** from the session menu.

---

## License

[GPL-2.0](LICENSE)
