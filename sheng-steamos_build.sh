#!/bin/bash
set -euo pipefail

# =============================================================================
# sheng-steamos_build.sh — SteamOS 风格游戏系统构建器 (debootstrap)
# =============================================================================
# 参考 debian-sheng 架构，使用 debootstrap 创建纯净基础系统，
# 所有组件以 .deb 包形式安装。
#
# 模式:
#   local    — 单脚本本地构建 (适合开发者)
#   ci       — CI 环境，假设 .deb 已由上游 Job 构建好
#
# 用法:
#   sudo ./sheng-steamos_build.sh [options]
#
#   选项:
#     --suite=<ver>         Debian 版本 (默认: trixie)
#     --desktop=<de>        桌面环境: gamescope|kde|gnome|server (默认: gamescope)
#     --launcher=<type>     游戏启动器: steam|retroarch|both (默认: steam)
#     --boot=<mode>         启动模式: single|dual (默认: dual)
#     --autologin=<bool>    自动登录 (默认: true)
#     --username=<name>     用户名 (默认: gamer)
#     --hostname=<name>     主机名 (默认: sheng-steamos)
#     --password=<pass>     密码 (默认: 通过环境变量 PASSWORD 或默认值)
#     --kernel=<ver>        内核版本 (默认: latest)
#     --output=<type>       输出: image|sd|bootimg (默认: image)
#     --mode=<build>        构建模式: local|ci (默认: local)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/rootfs-common.sh"

# --- 默认值 ---
SUITE="trixie"
DESKTOP="gamescope"
LAUNCHER="steam"
BOOT_MODE="dual"
AUTOLOGIN="true"
USERNAME="gamer"
HOSTNAME="sheng-steamos"
PASSWORD="${PASSWORD:-gamer}"
KERNEL_VERSION="latest"
OUTPUT_TYPE="image"
BUILD_MODE="local"

# 解析参数
for arg in "$@"; do
    case "$arg" in
        --suite=*)      SUITE="${arg#*=}" ;;
        --desktop=*)    DESKTOP="${arg#*=}" ;;
        --launcher=*)   LAUNCHER="${arg#*=}" ;;
        --boot=*)       BOOT_MODE="${arg#*=}" ;;
        --autologin=*)  AUTOLOGIN="${arg#*=}" ;;
        --username=*)   USERNAME="${arg#*=}" ;;
        --hostname=*)   HOSTNAME="${arg#*=}" ;;
        --password=*)   PASSWORD="${arg#*=}" ;;
        --kernel=*)     KERNEL_VERSION="${arg#*=}" ;;
        --output=*)     OUTPUT_TYPE="${arg#*=}" ;;
        --mode=*)       BUILD_MODE="${arg#*=}" ;;
        -h|--help)
            sed -n '2,/^# ====/p' "$0" | head -n -1 | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *) echo "未知选项: $arg" >&2; exit 1 ;;
    esac
done

# 校验
case "$DESKTOP" in
    gamescope|kde|gnome|server) ;;
    *) echo "错误: 无效桌面 '$DESKTOP'" >&2; exit 1 ;;
esac
case "$LAUNCHER" in
    steam|retroarch|both) ;;
    *) echo "错误: 无效启动器 '$LAUNCHER'" >&2; exit 1 ;;
esac
case "$BOOT_MODE" in
    single|dual) ;;
    *) echo "错误: 无效启动模式 '$BOOT_MODE'" >&2; exit 1 ;;
esac

IMAGE_SIZE="10G"
UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ROOTFS_IMG="sheng-steamos_${SUITE}_${LAUNCHER}_${TIMESTAMP}.img"

if [ "$BOOT_MODE" = "dual" ]; then
    PARTLABEL="linux"
else
    PARTLABEL="userdata"
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║       SteamOS 风格游戏系统 — debootstrap 构建                   ║"
echo "╠═══════════════════════════════════════════════════════════════════╣"
echo "║  基础: Debian ${SUITE} (arm64)                                     "
echo "║  桌面: ${DESKTOP} | 启动器: ${LAUNCHER}                            "
echo "║  启动: ${BOOT_MODE} (PARTLABEL=${PARTLABEL})                      "
echo "║  用户: ${USERNAME} | 自动登录: ${AUTOLOGIN}                       "
echo "║  输出: ${OUTPUT_TYPE}                                             "
echo "╚═══════════════════════════════════════════════════════════════════╝"

# ===========================================================================
# Step 1: 创建镜像
# ===========================================================================
echo ""
echo "━━━ [1/9] 创建 rootfs 镜像 (${IMAGE_SIZE}) ━━━"
ROOTDIR="rootdir"
create_image "$IMAGE_SIZE" "$ROOTFS_IMG" "$UUID"
setup_chroot_mounts "$ROOTDIR"
trap_teardown "$ROOTDIR"

# ===========================================================================
# Step 2: debootstrap — 安装纯净 Debian 基础系统
# ===========================================================================
echo ""
echo "━━━ [2/9] debootstrap (${SUITE}, arm64) ━━━"

# debootstrap 需要网络 DNS
cp /etc/resolv.conf "$ROOTDIR/etc/resolv.conf"

debootstrap \
    --arch=arm64 \
    --components=main,contrib,non-free-firmware \
    --include=systemd,systemd-sysv \
    "$SUITE" \
    "$ROOTDIR" \
    http://deb.debian.org/debian/

setup_dns "$ROOTDIR" 8.8.8.8 1.1.1.1

# ===========================================================================
# Step 3: 安装 .deb 组件包
# ===========================================================================
echo ""
echo "━━━ [3/9] 安装设备组件 .deb 包 ━━━"

# 收集所有 .deb (CI 模式从当前目录收集，local 模式从各处收集)
DEB_DIR=$(mktemp -d)
DEB_COUNT=0

collect_debs() {
    local dir="$1" pattern="$2"
    for f in "$dir"/$pattern; do
        if [ -f "$f" ]; then
            cp "$f" "$DEB_DIR/"
            DEB_COUNT=$((DEB_COUNT + 1))
        fi
    done
}

# 从工作目录收集 (CI 产出的 artifact)
collect_debs "$SCRIPT_DIR" "*.deb"
collect_debs "$SCRIPT_DIR/rpm-output" "*.rpm" 2>/dev/null || true

# 从 lib/debs 目录收集 (预打包的 .deb)
if [ -d "$SCRIPT_DIR/lib/debs" ]; then
    collect_debs "$SCRIPT_DIR/lib/debs" "*.deb"
fi

echo "  共收集 ${DEB_COUNT} 个 .deb 包"

if [ "$DEB_COUNT" -gt 0 ]; then
    cp "$DEB_DIR"/*.deb "$ROOTDIR/tmp/" 2>/dev/null || true
    chroot "$ROOTDIR" bash -c "apt-get update && apt-get install -y /tmp/*.deb 2>&1 || apt-get install -f -y"
    chroot "$ROOTDIR" rm -f /tmp/*.deb
fi
rm -rf "$DEB_DIR"

# ===========================================================================
# Step 4: 内核注入
# ===========================================================================
echo ""
echo "━━━ [4/9] 内核注入 ━━━"

# 检查内核 .deb 是否已安装
KERNEL_INSTALLED=false
if chroot "$ROOTDIR" dpkg -l | grep -q "linux-xiaomi-sheng" 2>/dev/null; then
    KERNEL_INSTALLED=true
    echo "  ✅ 内核 .deb 已安装"
fi

if [ "$KERNEL_INSTALLED" = false ]; then
    # 尝试从预编译 .deb 安装
    if ls "$SCRIPT_DIR"/linux-xiaomi-sheng*.deb &>/dev/null 2>&1; then
        echo "  -> 从本地 .deb 安装内核"
        chroot "$ROOTDIR" apt-get install -y /tmp/linux-xiaomi-sheng*.deb 2>/dev/null || true
    else
        echo "  -> 使用 Debian 仓库内核"
        chroot "$ROOTDIR" apt-get install -y linux-image-arm64 || {
            echo "  警告: 仓库内核安装失败，跳过" >&2
        }
    fi
fi

# 生成 initramfs
KERNEL_MODULE_DIR=$(detect_kernel_module_dir "$ROOTDIR")
if [ -n "$KERNEL_MODULE_DIR" ]; then
    echo "  内核版本: $KERNEL_MODULE_DIR"
    chroot "$ROOTDIR" update-initramfs -c -k "$KERNEL_MODULE_DIR" 2>/dev/null || true
fi

# ===========================================================================
# Step 5: 安装桌面环境
# ===========================================================================
echo ""
echo "━━━ [5/9] 安装桌面环境 (${DESKTOP}) ━━━"

case "$DESKTOP" in
    gamescope)
        # Gamescope 作为主合成器 (SteamOS 模式)
        # 先装最小 X/Wayland 基础
        chroot "$ROOTDIR" apt-get install -y --no-install-recommends \
            xwayland \
            libgl1-mesa-dri \
            libvulkan1 \
            mesa-vulkan-drivers \
            fonts-noto \
            fonts-dejavu-core || true

        # Gamescope 需要从 backports 或自行编译
        chroot "$ROOTDIR" apt-get install -y --no-install-recommends \
            gamescope 2>/dev/null || {
            echo "  警告: gamescope 不在仓库中，尝试 backports..."
            echo "deb http://deb.debian.org/debian ${SUITE}-backports main" > \
                "$ROOTDIR/etc/apt/sources.list.d/backports.list"
            chroot "$ROOTDIR" apt-get update
            chroot "$ROOTDIR" apt-get install -y -t ${SUITE}-backports gamescope 2>/dev/null || {
                echo "  警告: gamescope 安装失败，使用 Weston 替代"
                chroot "$ROOTDIR" apt-get install -y --no-install-recommends weston
            }
        }
        ;;
    kde)
        chroot "$ROOTDIR" apt-get install -y --no-install-recommends \
            plasma-desktop plasma-workspace plasma-nm \
            sddm konsole dolphin kate \
            firefox-esr \
            pipewire-alsa \
            xdg-desktop-portal-kde \
            kde-config-plymouth plymouth-theme-breeze 2>/dev/null || {
            # fallback: 最小 KDE
            chroot "$ROOTDIR" apt-get install -y --no-install-recommends \
                plasma-desktop sddm konsole dolphin pipewire-alsa
        }
        ;;
    gnome)
        chroot "$ROOTDIR" apt-get install -y --no-install-recommends \
            gnome-shell gnome-session gnome-terminal \
            gdm3 gnome-control-center \
            firefox-esr \
            pipewire-alsa 2>/dev/null || {
            chroot "$ROOTDIR" apt-get install -y --no-install-recommends \
                gnome-shell gdm3 gnome-terminal pipewire-alsa
        }
        ;;
    server)
        echo "  无桌面环境 (server 模式)"
        ;;
esac

# ===========================================================================
# Step 6: 安装游戏组件
# ===========================================================================
echo ""
echo "━━━ [6/9] 安装游戏组件 (launcher=${LAUNCHER}) ━━━"

source "$SCRIPT_DIR/lib/gaming-packages.sh"

# 游戏基础 (音频、输入、显示)
install_gaming_base "$ROOTDIR"

# MangoHud + 手柄
install_mangohud "$ROOTDIR" 2>/dev/null || true
install_controller_support "$ROOTDIR" 2>/dev/null || true

# Steam
if [ "$LAUNCHER" = "steam" ] || [ "$LAUNCHER" = "both" ]; then
    echo ""
    echo "  >>> 安装原生 ARM64 Steam + Proton ARM64..."
    install_steam "$ROOTDIR"
fi

# RetroArch
if [ "$LAUNCHER" = "retroarch" ] || [ "$LAUNCHER" = "both" ]; then
    echo ""
    echo "  >>> 安装 RetroArch + EmulationStation..."
    install_retroarch "$ROOTDIR" 2>/dev/null || true
    install_emulationstation "$ROOTDIR" 2>/dev/null || true
fi

# ===========================================================================
# Step 7: 系统配置
# ===========================================================================
echo ""
echo "━━━ [7/9] 系统配置 ━━━"

# 用户
chroot "$ROOTDIR" useradd -m -s /bin/bash -G sudo,audio,video,input "$USERNAME" 2>/dev/null || true
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chroot "$ROOTDIR" chpasswd
printf 'root:%s\n' "$PASSWORD" | chroot "$ROOTDIR" chpasswd

# 主机名
echo "$HOSTNAME" > "$ROOTDIR/etc/hostname"
echo "127.0.1.1 $HOSTNAME" >> "$ROOTDIR/etc/hosts"

# sudoers 免密
echo "%sudo ALL=(ALL:ALL) NOPASSWD: ***" > "$ROOTDIR/etc/sudoers.d/sudo-nopasswd"
chmod 440 "$ROOTDIR/etc/sudoers.d/sudo-nopasswd"

# fstab
echo "PARTLABEL=$PARTLABEL / ext4 defaults,noatime,errors=remount-ro 0 1" > "$ROOTDIR/etc/fstab"

# 网络
chroot "$ROOTDIR" systemctl enable NetworkManager systemd-resolved 2>/dev/null || true

# 触摸屏校准
configure_touchscreen "$ROOTDIR"

# WiFi 固件
fix_wifi_firmware "$ROOTDIR"

# QRTR
setup_qrtr_service "$ROOTDIR"

# 串口 console
setup_getty_ttyMSM0 "$ROOTDIR"

# 首次启动自动扩容
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

# 默认 target
if [ "$DESKTOP" = "server" ]; then
    chroot "$ROOTDIR" systemctl set-default multi-user.target
else
    chroot "$ROOTDIR" systemctl set-default graphical.target
fi

# ===========================================================================
# Step 8: 配置游戏会话
# ===========================================================================
echo ""
echo "━━━ [8/9] 配置游戏会话 ━━━"

setup_gaming_session "$ROOTDIR" "$LAUNCHER" "$DESKTOP" "$USERNAME"

# ===========================================================================
# Step 9: 清理 & 打包
# ===========================================================================
echo ""
echo "━━━ [9/9] 清理 & 打包 ━━━"

chroot "$ROOTDIR" apt-get clean 2>/dev/null || true
chroot "$ROOTDIR" rm -rf /var/cache/apt/archives/* 2>/dev/null || true
rm -f "$ROOTDIR/etc/resolv.conf"

# 记录包列表
chroot "$ROOTDIR" dpkg -l > "sheng-steamos_packages_${TIMESTAMP}.txt" 2>/dev/null || true

teardown_mounts "$ROOTDIR"

# 输出
apply_fs_uuid "$UUID" "$ROOTFS_IMG"

case "$OUTPUT_TYPE" in
    image)
        echo "正在转换为 sparse 镜像..."
        pack_sparse_image "$ROOTFS_IMG" "sheng-steamos_${SUITE}_${LAUNCHER}_${TIMESTAMP}.7z"
        echo ""
        echo "╔═══════════════════════════════════════════════════════════════╗"
        echo "║  ✅ rootfs 镜像构建完成                                      ║"
        echo "║  文件: sheng-steamos_${SUITE}_${LAUNCHER}_${TIMESTAMP}.7z    "
        echo "╚═══════════════════════════════════════════════════════════════╝"
        ;;
    sd)
        SD_DIR="sheng-steamos_sd_${TIMESTAMP}"
        ABL_PATH="abl/sm8550/abl_signed-SM8550.elf"
        [ ! -f "$ABL_PATH" ] && ABL_PATH=""
        create_sd_card_image "$ROOTFS_IMG" "$SD_DIR" "$ABL_PATH"
        echo ""
        echo "╔═══════════════════════════════════════════════════════════════╗"
        echo "║  ✅ SD 卡镜像构建完成                                        ║"
        echo "║  镜像: ${SD_DIR}/xiaomi-sheng-gaming-os.img                   "
        echo "║  刷写: ${SD_DIR}/flash_sd.sh                                  "
        echo "╚═══════════════════════════════════════════════════════════════╝"
        ;;
    bootimg)
        echo "正在生成 boot.img..."
        build_sheng_bootimg "$ROOTFS_IMG" "$BOOT_MODE" "$PARTLABEL" \
            "sheng-steamos_boot_${TIMESTAMP}.img" || true
        pack_sparse_image "$ROOTFS_IMG" "sheng-steamos_${SUITE}_${LAUNCHER}_${TIMESTAMP}.7z"
        echo ""
        echo "╔═══════════════════════════════════════════════════════════════╗"
        echo "║  ✅ boot.img + rootfs 构建完成                                ║"
        echo "║  rootfs: sheng-steamos_${SUITE}_${LAUNCHER}_${TIMESTAMP}.7z  "
        echo "║  boot:   sheng-steamos_boot_${TIMESTAMP}.img                  "
        echo "╚═══════════════════════════════════════════════════════════════╝"
        ;;
esac

echo ""
echo "组件:"
echo "  基础系统:  Debian ${SUITE} (debootstrap)"
echo "  桌面:      ${DESKTOP}"
echo "  启动器:    ${LAUNCHER}"
echo "  用户:      ${USERNAME} / ${PASSWORD} | root / ${PASSWORD}"
echo ""
trap - EXIT ERR INT TERM
echo "构建完成 🎮"
