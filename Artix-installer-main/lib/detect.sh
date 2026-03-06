#!/bin/bash
# lib/detect.sh — hardware detection: CPU microcode and GPU drivers

detect_cpu() {
    log_section "CPU Detection"
    if grep -qi "intel" /proc/cpuinfo; then
        CPU_TYPE="intel"
        CPU_UCODE="intel-ucode"
        log_info "Intel CPU detected -> intel-ucode will be installed"
    elif grep -qi "amd" /proc/cpuinfo; then
        CPU_TYPE="amd"
        CPU_UCODE="amd-ucode"
        log_info "AMD CPU detected -> amd-ucode will be installed"
    else
        CPU_TYPE="generic"
        CPU_UCODE=""
        log_warn "Unknown CPU, no microcode package"
    fi
    export CPU_TYPE CPU_UCODE
}

detect_gpu() {
    log_section "GPU Detection"

    local gpu_info
    gpu_info=$(lspci 2>/dev/null | grep -iE "VGA compatible|3D controller|Display controller" || true)

    if [[ -z "$gpu_info" ]]; then
        log_warn "No GPU found via lspci, using generic fallback"
        GPU_TYPE="generic"
        GPU_PACKAGES="mesa xf86-video-vesa"
        export GPU_TYPE GPU_PACKAGES
        return
    fi

    log_step "Detected GPU(s):"
    echo "$gpu_info"
    echo ""

    # Check for hybrid Intel+NVIDIA first (most specific case)
    if echo "$gpu_info" | grep -qi "intel" && echo "$gpu_info" | grep -qi "nvidia"; then
        GPU_TYPE="hybrid-nvidia"
        GPU_PACKAGES="mesa vulkan-intel intel-media-driver libva-intel-driver lib32-mesa lib32-vulkan-intel nvidia-dkms nvidia-utils nvidia-prime lib32-nvidia-utils"
        log_info "Hybrid Intel+NVIDIA -> installing both drivers"

    elif echo "$gpu_info" | grep -qi "nvidia"; then
        GPU_TYPE="nvidia"
        GPU_PACKAGES="nvidia-dkms nvidia-utils nvidia-settings lib32-nvidia-utils"
        log_info "NVIDIA GPU -> proprietary driver (nvidia-dkms)"

    elif echo "$gpu_info" | grep -qi "amd\|radeon\|advanced micro devices"; then
        GPU_TYPE="amd"
        GPU_PACKAGES="mesa vulkan-radeon xf86-video-amdgpu libva-mesa-driver lib32-mesa lib32-vulkan-radeon"
        log_info "AMD GPU -> open-source drivers (mesa + amdgpu)"

    elif echo "$gpu_info" | grep -qi "intel"; then
        GPU_TYPE="intel"
        GPU_PACKAGES="mesa vulkan-intel intel-media-driver libva-intel-driver lib32-mesa lib32-vulkan-intel"
        log_info "Intel GPU -> open-source drivers (mesa)"

    else
        GPU_TYPE="generic"
        GPU_PACKAGES="mesa xf86-video-vesa"
        log_warn "Unknown GPU -> fallback drivers (mesa + vesa)"
    fi

    export GPU_TYPE GPU_PACKAGES
}
