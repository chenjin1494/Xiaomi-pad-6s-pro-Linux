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

# Ensure mkbootimg is available
if ! command -v mkbootimg &>/dev/null && [ ! -f ./mkbootimg ]; then
    echo "Downloading mkbootimg..."
    wget -nv -O mkbootimg "https://github.com/nicolerey/mkbootimg/raw/master/mkbootimg" 2>/dev/null || true
    [ -f mkbootimg ] && chmod +x mkbootimg
fi
MKBOOTIMG=""
command -v mkbootimg &>/dev/null && MKBOOTIMG="mkbootimg"
[ -f ./mkbootimg ] && MKBOOTIMG="./mkbootimg"

# ==========================================================================
# Step 1: Create image
# ==========================================================================
echo ""
echo "[1/10] Creating rootfs image ($IMAGE_SIZE)..."
ROOTDIR="rootdir"
create_image "$IMAGE_SIZE" "$ROOTFS_IMG" "$UUID"
setup_chroot_mounts "$ROOTDIR"
trap_teardown "$ROOTDIR"

# ==========================================================================
# Step 2: Install Arch Linux ARM base system
# ==========================================================================
echo ""
echo "[2/10] Installing Arch Linux ARM base system..."

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

# Skip linux-firmware globally (we inject device-specific firmware)
sed -i '/^\[options\]/a IgnorePkg = linux-firmware' "$ROOTDIR/etc/pacman.conf"

echo "Running system update..."
chroot "$ROOTDIR" pacman -Syu --noconfirm --needed

# ==========================================================================
# Step 3: Install kernel + firmware
# ==========================================================================
echo ""
echo "[3/10] Installing kernel + firmware..."

# Only use ianchb's kernel - do NOT install Arch stock kernel
if ls "$SCRIPT_DIR"/linux-xiaomi-sheng*.deb &>/dev/null 2>&1; then
    echo "  -> Injecting ianchb kernel .deb"
    for deb in "$SCRIPT_DIR"/linux-xiaomi-sheng*.deb; do
        echo "    Extracting: $(basename "$deb")"
        dpkg-deb --fsys-tarfile "$deb" | tar -x --keep-directory-symlink -C "$ROOTDIR/" 2>/dev/null || true
    done
    # Move modules from /lib to /usr/lib (Arch path)
    for mod_dir in "$ROOTDIR"/lib/modules/*; do
        [ -d "$mod_dir" ] || continue
        kver=$(basename "$mod_dir")
        if [ ! -d "$ROOTDIR/usr/lib/modules/$kver" ]; then
            echo "    Moving modules: /lib/modules/$kver -> /usr/lib/modules/$kver"
            mkdir -p "$ROOTDIR/usr/lib/modules"
            mv "$mod_dir" "$ROOTDIR/usr/lib/modules/"
        fi
    done
else
    echo "  ERROR: linux-xiaomi-sheng*.deb not found!" >&2
    echo "  Kernel is required. Aborting." >&2
    exit 1
fi

# Generate initramfs for ianchb kernel
KERNEL_MODULE_DIR=$(detect_kernel_module_dir "$ROOTDIR")
if [ -n "$KERNEL_MODULE_DIR" ]; then
    echo "  Kernel: $KERNEL_MODULE_DIR"

    # Create mkinitcpio preset for this kernel
    mkdir -p "$ROOTDIR/etc/mkinitcpio.d"
    cat > "$ROOTDIR/etc/mkinitcpio.d/linux.preset" <<PRESET
ALL_kver="$KERNEL_MODULE_DIR"
PRESET_image="/boot/initramfs-linux.img"
PRESET_options=""
PRESET

    # Generate initramfs
    echo "  Generating initramfs..."
    chroot "$ROOTDIR" mkinitcpio -k "$KERNEL_MODULE_DIR" -g /boot/initramfs-linux.img 2>/dev/null || {
        echo "  mkinitcpio failed, trying manual initramfs..."
        # Fallback: create minimal initramfs
        chroot "$ROOTDIR" bash -c "cd /usr/lib/modules/$KERNEL_MODULE_DIR && \
            find . | cpio -o -H newc 2>/dev/null | gzip > /boot/initramfs-linux.img" 2>/dev/null || true
    }

    echo "  Initramfs: $(ls -lh $ROOTDIR/boot/initramfs-linux.img 2>/dev/null | awk '{print $5}')"
else
    echo "  WARNING: No kernel modules found!" >&2
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
echo "[4/10] Installing base system packages..."

chroot "$ROOTDIR" pacman -S --noconfirm --needed \
    systemd sudo vim wget curl base-devel git xz \
    pciutils usbutils dialog yad xdg-user-dirs

# ==========================================================================
# Step 5: Create users (before gaming components, so chown works)
# ==========================================================================
echo ""
echo "[5/10] Creating users..."

chroot "$ROOTDIR" useradd -m -s /bin/bash -G wheel,audio,video,input,storage "$USERNAME" 2>/dev/null || true
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chroot "$ROOTDIR" chpasswd
printf 'root:%s\n' "$PASSWORD" | chroot "$ROOTDIR" chpasswd

echo "$HOSTNAME" > "$ROOTDIR/etc/hostname"
echo "127.0.1.1 $HOSTNAME" >> "$ROOTDIR/etc/hosts"
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ***" > "$ROOTDIR/etc/sudoers.d/wheel"
chmod 440 "$ROOTDIR/etc/sudoers.d/wheel"

# ==========================================================================
# Step 6: Install gaming components
# ==========================================================================
echo ""
echo "[6/10] Installing gaming components..."

# Gaming component installation — run in subshell to isolate errors
(
    set +e
    source "$SCRIPT_DIR/lib/gaming-packages.sh"

    install_gaming_base "$ROOTDIR"
    install_gamescope "$ROOTDIR"
    install_mangohud "$ROOTDIR"
    install_controller_support "$ROOTDIR"

    # Mesa + Vulkan drivers from repos
    echo ""
    echo "  >>> Installing Mesa + Vulkan drivers..."
    chroot "$ROOTDIR" pacman -S --noconfirm --needed \
        mesa vulkan-swrast vulkan-tools \
        vulkan-freedreno \
        lib32-mesa lib32-vulkan-swrast 2>/dev/null || true

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

    # Console emulators
    echo ""
    echo "  >>> Installing RPCS3 (PlayStation 3 emulator)..."
    install_rpcs3 "$ROOTDIR"

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
# Step 7: System configuration (users already created in Step 5)
# ==========================================================================
echo ""
echo "[7/10] System configuration..."

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
# Step 8: Configure gaming session
# ==========================================================================
echo ""
echo "[8/10] Configuring gaming session..."

source "$SCRIPT_DIR/lib/gaming-packages.sh"
setup_gaming_session "$ROOTDIR" "$LAUNCHER" "$DESKTOP" "$USERNAME"

# ==========================================================================
# Step 9: Cleanup
# ==========================================================================
echo ""
echo "[9/10] Cleaning up..."

set +e
chroot "$ROOTDIR" pacman -Scc --noconfirm 2>/dev/null
chroot "$ROOTDIR" rm -rf /var/cache/pacman/pkg/* 2>/dev/null
rm -f "$ROOTDIR/etc/resolv.conf"
set -e

capture_package_list "$ROOTDIR" "$(pwd)/sheng-steamos_packages_${TIMESTAMP}.txt" 2>/dev/null || true

teardown_mounts "$ROOTDIR" 2>/dev/null || true

# ==========================================================================
# Step 10: Package output
# ==========================================================================
echo ""
echo "[10/10] Packaging output..."

apply_fs_uuid "$UUID" "$ROOTFS_IMG"

# Generate boot.img from rootfs kernel files
BOOT_IMG="sheng-steamos_boot_${TIMESTAMP}.img"
echo "Generating boot.img..."
if [ -n "$MKBOOTIMG" ]; then
    # Extract kernel + DTB + initramfs from rootfs
    MNT=$(mktemp -d)
    mount -o loop,ro "$ROOTFS_IMG" "$MNT" 2>/dev/null || true

    KERNEL_FILE=$(find "$MNT/boot" -maxdepth 1 -type f \( -name "vmlinuz*" -o -name "Image*" \) 2>/dev/null | head -1)
    INITRD_FILE=$(find "$MNT/boot" -maxdepth 1 -type f -name "initramfs*" 2>/dev/null | head -1)
    DTB_FILE=$(find "$MNT/boot" -maxdepth 1 -name "sm8550-xiaomi-sheng.dtb" 2>/dev/null | head -1)

    if [ -n "$KERNEL_FILE" ]; then
        TMPDIR=$(mktemp -d)
        cp "$KERNEL_FILE" "$TMPDIR/kernel"
        [ -n "$INITRD_FILE" ] && cp "$INITRD_FILE" "$TMPDIR/initrd.img"

        # Append DTB to kernel if available
        if [ -n "$DTB_FILE" ]; then
            cat "$TMPDIR/kernel" "$DTB_FILE" > "$TMPDIR/kernel+dtb"
            KERNEL_PAYLOAD="$TMPDIR/kernel+dtb"
        else
            KERNEL_PAYLOAD="$TMPDIR/kernel"
        fi

        MKBOOTIMG_CMD="$MKBOOTIMG --kernel \"$KERNEL_PAYLOAD\""
        MKBOOTIMG_CMD+=" --cmdline \"root=PARTLABEL=$PARTLABEL rootwait console=tty0 console=ttyMSM0,115200n8\""
        MKBOOTIMG_CMD+=" --base 0x00000000 --kernel_offset 0x00008000 --tags_offset 0x01e00000 --pagesize 4096"
        [ -f "$TMPDIR/initrd.img" ] && MKBOOTIMG_CMD+=" --ramdisk \"$TMPDIR/initrd.img\" --ramdisk_offset 0x01000000"
        MKBOOTIMG_CMD+=" -o \"$BOOT_IMG\""

        eval "$MKBOOTIMG_CMD" && echo "  boot.img: $BOOT_IMG" || echo "  Warning: mkbootimg failed"
        rm -rf "$TMPDIR"
    else
        echo "  Warning: No kernel found in rootfs"
    fi
    umount "$MNT" 2>/dev/null; rmdir "$MNT"
else
    echo "  Warning: mkbootimg not available, skipping boot.img"
    BOOT_IMG=""
fi

case "$OUTPUT_TYPE" in
    image)
        echo "Converting to sparse image..."
        pack_sparse_image "$ROOTFS_IMG" "sheng-steamos_${LAUNCHER}_${TIMESTAMP}.7z"
        echo ""
        echo "============================================="
        echo " Done: sheng-steamos_${LAUNCHER}_${TIMESTAMP}.7z"
        [ -n "$BOOT_IMG" ] && echo " Boot: $BOOT_IMG"
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
echo "  PS3:          RPCS3 v0.0.42"
echo "  Emulators:    RetroArch, Dolphin, PPSSPP, mGBA, Mupen64Plus,"
echo "                DOSBox, ScummVM, EmulationStation DE"
echo "  Gaming:       GameMode, MangoHud, Lutris, Heroic, vkBasalt"
echo "  User:         $USERNAME / $PASSWORD"
echo ""
trap - EXIT ERR INT TERM
echo "Build complete!"
