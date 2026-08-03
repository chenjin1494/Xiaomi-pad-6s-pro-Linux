#!/bin/bash
set -euo pipefail

# =============================================================================
# sheng-steamos_build.sh — SteamOS-style Gaming System (Arch Linux ARM)
# =============================================================================
# Uses Arch Linux ARM as base. Components installed via pacman.
#
# Usage:
#   sudo ./sheng-steamos_build.sh [options]
#
# Options:
#   --desktop=<de>        gamescope|kde|gnome|server (default: gamescope)
#   --launcher=<type>     steam|retroarch|both (default: steam)
#   --boot=<mode>         single|dual (default: dual)
#   --autologin=<bool>    true|false (default: true)
#   --username=<name>     (default: gamer)
#   --hostname=<name>     (default: sheng-steamos)
#   --password=<pass>     (default: from env PASSWORD or 'password')
#   --output=<type>       image|sd|bootimg (default: image)
#   --mode=<build>        local|ci (default: local)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/rootfs-common.sh"

# Defaults
DESKTOP="gamescope"
LAUNCHER="steam"
BOOT_MODE="dual"
AUTOLOGIN="true"
USERNAME="gamer"
HOSTNAME="sheng-steamos"
PASSWORD="${PASSWORD:-password}"
OUTPUT_TYPE="image"
BUILD_MODE="local"

for arg in "$@"; do
    case "$arg" in
        --desktop=*)   DESKTOP="${arg#*=}" ;;
        --launcher=*)  LAUNCHER="${arg#*=}" ;;
        --boot=*)      BOOT_MODE="${arg#*=}" ;;
        --autologin=*) AUTOLOGIN="${arg#*=}" ;;
        --username=*)  USERNAME="${arg#*=}" ;;
        --hostname=*)  HOSTNAME="${arg#*=}" ;;
        --password=*)  PASSWORD="${arg#*=}" ;;
        --output=*)    OUTPUT_TYPE="${arg#*=}" ;;
        --mode=*)      BUILD_MODE="${arg#*=}" ;;
        -h|--help)
            sed -n '2,/^# ====/p' "$0" | head -n -1 | sed 's/^# //' | sed 's/^#//'
            exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

# Validate
case "$DESKTOP" in gamescope|kde|gnome|server) ;; *) echo "Invalid desktop: $DESKTOP" >&2; exit 1 ;; esac
case "$LAUNCHER" in steam|retroarch|both) ;; *) echo "Invalid launcher: $LAUNCHER" >&2; exit 1 ;; esac
case "$BOOT_MODE" in single|dual) ;; *) echo "Invalid boot mode: $BOOT_MODE" >&2; exit 1 ;; esac

IMAGE_SIZE="10G"
UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ROOTFS_IMG="sheng-steamos_${LAUNCHER}_${TIMESTAMP}.img"
[ "$BOOT_MODE" = "dual" ] && PARTLABEL="linux" || PARTLABEL="userdata"

echo ""
echo "============================================="
echo " SteamOS Gaming System (Arch Linux ARM)"
echo "============================================="
echo " Desktop:  $DESKTOP"
echo " Launcher: $LAUNCHER"
echo " Boot:     $BOOT_MODE (PARTLABEL=$PARTLABEL)"
echo " User:     $USERNAME"
echo " Output:   $OUTPUT_TYPE"
echo "============================================="

# ==========================================================================
# Step 1: Create image
# ==========================================================================
echo ""
echo "[1/9] Creating rootfs image ($IMAGE_SIZE)..."
ROOTDIR="rootdir"
create_image "$IMAGE_SIZE" "$ROOTFS_IMG" "$UUID"
setup_chroot_mounts "$ROOTDIR"
trap_teardown "$ROOTDIR"

# ==========================================================================
# Step 2: Install Arch Linux ARM base system
# ==========================================================================
echo ""
echo "[2/9] Installing Arch Linux ARM base system..."

ARCH_TAR="ArchLinuxARM-aarch64-latest.tar.gz"

if [ ! -f "$ARCH_TAR" ]; then
    echo "Downloading Arch Linux ARM aarch64 rootfs..."
    wget -nv -O "$ARCH_TAR" \
        "http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz" || \
    wget -nv -O "$ARCH_TAR" \
        "http://mirror.archlinuxarm.org/aarch64/ArchLinuxARM-aarch64-latest.tar.gz" || \
    wget -nv -O "$ARCH_TAR" \
        "https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/os/ArchLinuxARM-aarch64-latest.tar.gz" || \
    wget -nv -O "$ARCH_TAR" \
        "https://mirrors.ustc.edu.cn/archlinuxarm/os/ArchLinuxARM-aarch64-latest.tar.gz" || {
        echo "Error: All Arch Linux ARM mirrors failed" >&2; exit 1
    }
fi

echo "Extracting Arch Linux ARM rootfs..."
bsdtar -xpf "$ARCH_TAR" -C "$ROOTDIR/"

echo "Initializing pacman keyring..."
chroot "$ROOTDIR" pacman-key --init
chroot "$ROOTDIR" pacman-key --populate archlinuxarm

setup_dns "$ROOTDIR" 8.8.8.8 1.1.1.1

# Configure mirrors
cat > "$ROOTDIR/etc/pacman.d/mirrorlist" <<'MIRROR'
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo
Server = https://mirrors.ustc.edu.cn/archlinuxarm/$arch/$repo
Server = http://os.archlinuxarm.org/$arch/$repo
MIRROR

echo "Running system update..."
chroot "$ROOTDIR" pacman -Syu --noconfirm --needed

# ==========================================================================
# Step 3: Install kernel + firmware
# ==========================================================================
echo ""
echo "[3/9] Installing kernel + firmware..."

# Try injecting project kernel .deb/.rpm first
INJECTED=0
if ls "$SCRIPT_DIR"/linux-xiaomi-sheng*.deb &>/dev/null 2>&1; then
    echo "  -> Injecting .deb kernel packages"
    inject_deb_kernel "$ROOTDIR" "$SCRIPT_DIR/linux-xiaomi-sheng*.deb"
    INJECTED=1
elif ls "$SCRIPT_DIR"/rpm-output/*.rpm &>/dev/null 2>&1; then
    echo "  -> Injecting .rpm kernel packages"
    inject_rpm_packages "$ROOTDIR" "$SCRIPT_DIR/rpm-output/*.rpm"
    INJECTED=1
fi

if [ "$INJECTED" -eq 0 ]; then
    echo "  -> Using Arch Linux ARM repo kernel"
    chroot "$ROOTDIR" pacman -S --noconfirm --needed linux-aarch64
fi

# Generate initramfs
KERNEL_MODULE_DIR=$(detect_kernel_module_dir "$ROOTDIR")
if [ -n "$KERNEL_MODULE_DIR" ]; then
    echo "  Kernel: $KERNEL_MODULE_DIR"
    chroot "$ROOTDIR" mkinitcpio -P 2>/dev/null || \
        chroot "$ROOTDIR" mkinitcpio -k "$KERNEL_MODULE_DIR" -g /boot/initramfs-linux.img 2>/dev/null || true
fi

# Inject firmware
echo "Injecting device firmware..."
[ -d "$SCRIPT_DIR/firmware-xiaomi-sheng/usr/lib" ] && \
    cp -r "$SCRIPT_DIR/firmware-xiaomi-sheng/usr/lib"/* "$ROOTDIR/usr/lib/" 2>/dev/null || true
[ -d "$SCRIPT_DIR/firmware" ] && \
    cp -r "$SCRIPT_DIR/firmware"/* "$ROOTDIR/usr/lib/firmware/" 2>/dev/null || true

# Inject ALSA UCM
echo "Injecting ALSA UCM config..."
[ -d "$SCRIPT_DIR/alsa-xiaomi-sheng/usr/share/alsa/ucm2" ] && \
    cp -r "$SCRIPT_DIR/alsa-xiaomi-sheng/usr/share/alsa/ucm2"/* \
        "$ROOTDIR/usr/share/alsa/ucm2/" 2>/dev/null || true

# Inject .deb device packages (fastrpc, libssc, sensors, etc.)
echo "Injecting device .deb packages..."
DEB_DIR=$(mktemp -d)
for pattern in "*.deb"; do
    for f in "$SCRIPT_DIR"/$pattern; do
        [ -f "$f" ] && cp "$f" "$DEB_DIR/"
    done
done
[ -d "$SCRIPT_DIR/lib/debs" ] && cp "$SCRIPT_DIR/lib/debs"/*.deb "$DEB_DIR/" 2>/dev/null || true

DEB_COUNT=$(ls -1 "$DEB_DIR"/*.deb 2>/dev/null | wc -l)
if [ "$DEB_COUNT" -gt 0 ]; then
    echo "  Found $DEB_COUNT .deb packages, extracting..."
    set +o pipefail
    set +e
    for deb in "$DEB_DIR"/*.deb; do
        [ -f "$deb" ] || continue
        deb_name=$(basename "$deb")
        echo "    -> $deb_name"
        # Verify it's a valid .deb (ar archive)
        if ! file "$deb" | grep -q 'Debian\|ar archive' 2>/dev/null; then
            echo "      Skipping (not a valid .deb)"
            continue
        fi
        # Extract data.tar.* from .deb
        tmp_deb=$(mktemp -d)
        dpkg-deb --fsys-tarfile "$deb" > "$tmp_deb/data.tar" 2>/dev/null
        if [ -s "$tmp_deb/data.tar" ]; then
            tar -xf "$tmp_deb/data.tar" --keep-directory-symlink --warning=no-unknown-keyword -C "$ROOTDIR/" 2>/dev/null || true
        fi
        rm -rf "$tmp_deb"
    done
    set -e
    # Run postinst scripts
    for deb in "$DEB_DIR"/*.deb; do
        [ -f "$deb" ] || continue
        pkg_name=$(dpkg-deb -f "$deb" Package 2>/dev/null || echo "")
        [ -n "$pkg_name" ] || continue
        postinst="$ROOTDIR/var/lib/dpkg/info/${pkg_name}.postinst"
        if [ -f "$postinst" ]; then
            chroot "$ROOTDIR" bash "/var/lib/dpkg/info/${pkg_name}.postinst" configure 2>/dev/null || true
        fi
    done
fi
rm -rf "$DEB_DIR"

# ==========================================================================
# Step 4: Install base system packages
# ==========================================================================
echo ""
echo "[4/9] Installing base system packages..."

chroot "$ROOTDIR" pacman -S --noconfirm --needed \
    systemd sudo vim wget curl base-devel git xz \
    pciutils usbutils dialog yad xdg-user-dirs

# ==========================================================================
# Step 5: Install gaming components
# ==========================================================================
echo ""
echo "[5/9] Installing gaming components..."

# Gaming component installation — run in subshell to isolate errors
(
    set +e
    source "$SCRIPT_DIR/lib/gaming-packages.sh"

    install_gaming_base "$ROOTDIR"
    install_gamescope "$ROOTDIR"
    install_mangohud "$ROOTDIR"
    install_controller_support "$ROOTDIR"

    # Mesa from source (Turnip + Freedreno for Adreno 740)
    echo ""
    echo "  >>> Building Mesa from source (Turnip Vulkan + Freedreno)..."
    install_mesa_from_source "$ROOTDIR"

    # x86/x64 emulation layers
    echo ""
    echo "  >>> Installing FEX-Emu (x86/x64 translation)..."
    install_fex_emu "$ROOTDIR"

    echo ""
    echo "  >>> Installing Box64 (x86_64 emulation)..."
    install_box64 "$ROOTDIR"

    # Steam
    if [ "$LAUNCHER" = "steam" ] || [ "$LAUNCHER" = "both" ]; then
        echo ""
        echo "  >>> Installing Native ARM64 Steam + Proton ARM64..."
        install_steam "$ROOTDIR"
    fi

    # Nintendo Switch emulator
    echo ""
    echo "  >>> Installing Eden (Nintendo Switch emulator)..."
    install_eden "$ROOTDIR"

    # Emulators + gaming extras
    echo ""
    echo "  >>> Installing emulators (RetroArch, Dolphin, PPSSPP, etc.)..."
    install_emulators "$ROOTDIR"

    echo ""
    echo "  >>> Installing gaming extras (Lutris, Heroic, GameMode, etc.)..."
    install_gaming_extras "$ROOTDIR"

    if [ "$DESKTOP" = "kde" ] || [ "$DESKTOP" = "gnome" ]; then
        echo ""
        echo "  >>> Installing Desktop Mode ($DESKTOP)..."
        install_desktop_mode "$ROOTDIR" "$DESKTOP"
    fi

    exit 0
) || echo "  (Some gaming components had non-fatal errors)"

# ==========================================================================
# Step 6: System configuration
# ==========================================================================
echo ""
echo "[6/9] System configuration..."

# Users
chroot "$ROOTDIR" useradd -m -s /bin/bash -G wheel,audio,video,input,storage "$USERNAME" 2>/dev/null || true
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chroot "$ROOTDIR" chpasswd
printf 'root:%s\n' "$PASSWORD" | chroot "$ROOTDIR" chpasswd

echo "$HOSTNAME" > "$ROOTDIR/etc/hostname"
echo "127.0.1.1 $HOSTNAME" >> "$ROOTDIR/etc/hosts"

echo "%wheel ALL=(ALL:ALL) NOPASSWD: ***" > "$ROOTDIR/etc/sudoers.d/wheel"
chmod 440 "$ROOTDIR/etc/sudoers.d/wheel"

# fstab
echo "PARTLABEL=$PARTLABEL / ext4 defaults,noatime,errors=remount-ro 0 1" > "$ROOTDIR/etc/fstab"

# Network
chroot "$ROOTDIR" systemctl enable systemd-resolved NetworkManager 2>/dev/null || true

# Touchscreen
configure_touchscreen "$ROOTDIR"

# WiFi firmware
fix_wifi_firmware "$ROOTDIR"

# QRTR
setup_qrtr_service "$ROOTDIR"

# Serial console
setup_getty_ttyMSM0 "$ROOTDIR"

# First-boot auto-expand
cat > "$ROOTDIR/etc/systemd/system/resizefs.service" <<'EOF'
[Unit]
Description=Expand root filesystem to fill partition and self-destruct
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'exec /usr/sbin/resize2fs $(findmnt -nvo SOURCE /)'
ExecStartPost=/usr/bin/systemctl disable resizefs.service
ExecStartPost=/usr/bin/rm -f /etc/systemd/system/resizefs.service
ExecStartPost=/usr/bin/systemctl daemon-reload
RemainAfterExit=true

[Install]
WantedBy=default.target
EOF
chroot "$ROOTDIR" systemctl enable resizefs.service

# Default target
if [ "$DESKTOP" = "server" ]; then
    chroot "$ROOTDIR" systemctl set-default multi-user.target
else
    chroot "$ROOTDIR" systemctl set-default graphical.target
fi

# ==========================================================================
# Step 7: Configure gaming session
# ==========================================================================
echo ""
echo "[7/9] Configuring gaming session..."

source "$SCRIPT_DIR/lib/gaming-packages.sh"
setup_gaming_session "$ROOTDIR" "$LAUNCHER" "$DESKTOP" "$USERNAME"

# ==========================================================================
# Step 8: Cleanup
# ==========================================================================
echo ""
echo "[8/9] Cleaning up..."

set +e
chroot "$ROOTDIR" pacman -Scc --noconfirm 2>/dev/null
chroot "$ROOTDIR" rm -rf /var/cache/pacman/pkg/* 2>/dev/null
rm -f "$ROOTDIR/etc/resolv.conf"
set -e

capture_package_list "$ROOTDIR" "$(pwd)/sheng-steamos_packages_${TIMESTAMP}.txt" 2>/dev/null || true

teardown_mounts "$ROOTDIR" 2>/dev/null || true

# ==========================================================================
# Step 9: Package output
# ==========================================================================
echo ""
echo "[9/9] Packaging output..."

apply_fs_uuid "$UUID" "$ROOTFS_IMG"

case "$OUTPUT_TYPE" in
    image)
        echo "Converting to sparse image..."
        pack_sparse_image "$ROOTFS_IMG" "sheng-steamos_${LAUNCHER}_${TIMESTAMP}.7z"
        echo ""
        echo "============================================="
        echo " Done: sheng-steamos_${LAUNCHER}_${TIMESTAMP}.7z"
        echo "============================================="
        ;;
    sd)
        SD_DIR="sheng-steamos_sd_${TIMESTAMP}"
        ABL_PATH="abl/sm8550/abl_signed-SM8550.elf"
        [ ! -f "$ABL_PATH" ] && ABL_PATH=""
        create_sd_card_image "$ROOTFS_IMG" "$SD_DIR" "$ABL_PATH"
        echo ""
        echo "============================================="
        echo " SD card image: ${SD_DIR}/xiaomi-sheng-gaming-os.img"
        echo " Flash script:  ${SD_DIR}/flash_sd.sh"
        echo "============================================="
        ;;
    bootimg)
        echo "Generating boot.img..."
        build_sheng_bootimg "$ROOTFS_IMG" "$BOOT_MODE" "$PARTLABEL" \
            "sheng-steamos_boot_${TIMESTAMP}.img" || true
        pack_sparse_image "$ROOTFS_IMG" "sheng-steamos_${LAUNCHER}_${TIMESTAMP}.7z"
        echo ""
        echo "============================================="
        echo " rootfs: sheng-steamos_${LAUNCHER}_${TIMESTAMP}.7z"
        echo " boot:   sheng-steamos_boot_${TIMESTAMP}.img"
        echo "============================================="
        ;;
esac

echo ""
echo "Components:"
echo "  Base:         Arch Linux ARM"
echo "  Desktop:      $DESKTOP"
echo "  Launcher:     $LAUNCHER"
echo "  GPU Driver:   Mesa 25.1.5 (Turnip Vulkan + Freedreno, from source)"
echo "  x86 Layer:    FEX-Emu + Box64"
echo "  Steam:        Native ARM64 + Proton ARM64"
echo "  Switch:       Eden (Yuzu fork)"
echo "  Emulators:    RetroArch, Dolphin, PPSSPP, mGBA, Mupen64Plus,"
echo "                DOSBox, ScummVM, EmulationStation DE"
echo "  Gaming:       GameMode, MangoHud, Lutris, Heroic, vkBasalt"
echo "  User:         $USERNAME / $PASSWORD"
echo ""
trap - EXIT ERR INT TERM
echo "Build complete!"
