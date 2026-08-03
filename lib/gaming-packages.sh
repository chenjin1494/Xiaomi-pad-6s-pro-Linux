#!/bin/bash
# =============================================================================
# gaming-packages.sh — SteamOS 风格游戏系统组件库 (Debian arm64)
# =============================================================================
# 所有安装函数接受 <rootdir> 作为第一个参数。
# 在 chroot 环境中执行 apt-get 安装。
# =============================================================================

# ---------------------------------------------------------------------------
# install_gaming_base  — 游戏系统基础依赖
# ---------------------------------------------------------------------------
install_gaming_base() {
    local rootdir="$1"
    echo "安装游戏基础依赖..."

    chroot "$rootdir" apt-get update
    chroot "$rootdir" apt-get install -y --no-install-recommends \
        alsa-utils \
        pipewire \
        pipewire-alsa \
        pipewire-pulse \
        wireplumber \
        libevdev2 \
        libinput10 \
        libdrm2 \
        libglvnd0 \
        libgl1-mesa-dri \
        libegl1-mesa \
        libgles2-mesa \
        libxkbcommon0 \
        libxcb1 \
        libx11-6 \
        libxcursor1 \
        libxfixes3 \
        libxi6 \
        libxrandr2 \
        libxrender1 \
        libxss1 \
        fontconfig \
        fonts-dejavu-core \
        fonts-noto \
        libpng16-16 \
        zlib1g \
        libbz2-1.0 \
        xz-utils \
        wget \
        curl \
        sudo \
        dbus-x11 \
        xdg-utils \
        joystick \
        gamecontrollerdb \
        udev

    # 启用 PipeWire
    chroot "$rootdir" systemctl --global enable pipewire pipewire-pulse wireplumber 2>/dev/null || true

    echo "游戏基础依赖安装完成"
}

# ---------------------------------------------------------------------------
# install_gamescope  — Gamescope 微合成器
# ---------------------------------------------------------------------------
install_gamescope() {
    local rootdir="$1"
    echo "安装 Gamescope..."

    chroot "$rootdir" apt-get install -y --no-install-recommends gamescope 2>/dev/null || {
        echo "  gamescope 不在标准仓库，尝试 backports..."
        local suite
        suite=$(chroot "$rootdir" cat /etc/debian_version | tr -d '\n')
        if [ -f "$rootdir/etc/apt/sources.list" ]; then
            local main_line
            main_line=$(grep "^deb " "$rootdir/etc/apt/sources.list" | head -1)
            local backports_line="${main_line%% *}-backports ${main_line#* }"
            echo "$backports_line" > "$rootdir/etc/apt/sources.list.d/backports.list"
            chroot "$rootdir" apt-get update
            chroot "$rootdir" apt-get install -y -t ${suite}-backports gamescope 2>/dev/null || {
                echo "  警告: gamescope 安装失败，使用 Weston 替代" >&2
                chroot "$rootdir" apt-get install -y --no-install-recommends weston
            }
        fi
    }

    echo "Gamescope 安装完成"
}

# ---------------------------------------------------------------------------
# install_steam  — 原生 ARM64 Steam 客户端 + Proton ARM64 + FEX-Emu
# ---------------------------------------------------------------------------
install_steam() {
    local rootdir="$1"
    echo "安装原生 ARM64 Steam 客户端..."

    # 依赖
    chroot "$rootdir" apt-get install -y --no-install-recommends \
        libsdl2-2.0-0 \
        libvpx7 \
        libnss3 \
        libcurl4 \
        libgtk2.0-common \
        steam-devices 2>/dev/null || true

    local steam_dir="$rootdir/home/${USERNAME:-gamer}/.local/share/Steam"
    mkdir -p "$steam_dir"

    # ---- 原生 ARM64 Steam 客户端 ----
    echo "  >>> 下载原生 ARM64 Steam 客户端..."
    local steam_zip="bins_linuxarm64_linuxarm64.zip"
    local steam_url="https://client-update.steamstatic.com/bins_linuxarm64_linuxarm64.zip.f523fa87fc6b9b5435a5e7370cb0d664ef53b50b"

    wget -nv -O "/tmp/$steam_zip" "$steam_url" || {
        echo "错误: 下载 ARM64 Steam 客户端失败" >&2
        return 1
    }
    bsdtar -xf "/tmp/$steam_zip" -C "$steam_dir/"
    rm -f "/tmp/$steam_zip"

    # beta 通道
    mkdir -p "$steam_dir/package"
    echo "publicbeta" > "$steam_dir/package/beta"

    # 权限
    chmod -R u+rwx "$steam_dir/steamrtarm64/" 2>/dev/null || true

    echo "  原生 ARM64 Steam 客户端安装完成"

    # ---- Proton ARM64 ----
    echo "  >>> 下载 Proton ARM64 + Steam Linux Runtime..."
    local proton_tar="arm-64proton-runtime-64.tar"
    local proton_url="https://archive.org/download/arm-64proton-runtime-64.tar"
    local compat_dir="$steam_dir/compatibilitytools.d"
    mkdir -p "$compat_dir"

    wget -nv -O "/tmp/$proton_tar" "$proton_url" || {
        echo "警告: 下载 Proton ARM64 失败" >&2
    }
    if [ -f "/tmp/$proton_tar" ]; then
        tar -xf "/tmp/$proton_tar" -C "$compat_dir/"
        rm -f "/tmp/$proton_tar"
        echo "  Proton ARM64 安装完成"
    fi

    # ---- SDK symlink ----
    mkdir -p "$rootdir/home/${USERNAME:-gamer}/.steam"
    ln -sf "$steam_dir/linuxarm64" "$rootdir/home/${USERNAME:-gamer}/.steam/sdkarm64"

    # ---- libvpx 兼容性 ----
    if [ -f "$rootdir/usr/lib/aarch64-linux-gnu/libvpx.so.9" ] && \
       [ ! -f "$rootdir/usr/lib/aarch64-linux-gnu/libvpx.so.6" ]; then
        ln -sf libvpx.so.9 "$rootdir/usr/lib/aarch64-linux-gnu/libvpx.so.6"
    fi

    # ---- FEX-Emu ----
    echo "  >>> 安装 FEX-Emu..."
    chroot "$rootdir" apt-get install -y fex-emu 2>/dev/null || {
        echo "  FEX-Emu 不在仓库中，尝试手动安装..."
        local fex_ver="FEX-2605"
        local fex_url="https://github.com/FEX-Emu/FEX/releases/download/${fex_ver}/${fex_ver}-aarch64.tar.gz"
        wget -nv -O /tmp/fex.tar.gz "$fex_url" 2>/dev/null || true
        if [ -f /tmp/fex.tar.gz ]; then
            tar -xzf /tmp/fex.tar.gz -C "$rootdir/usr/local/"
            rm -f /tmp/fex.tar.gz
        fi
    }

    # FEX rootfs
    chroot "$rootdir" bash -c "FEXRootFSFetcher --name Ubuntu_24_04 --rootfs-path /var/lib/FEX/rootfs" 2>/dev/null || true

    # ---- AppArmor userns 修复 ----
    cat > "$rootdir/etc/sysctl.d/99-steam-userns.conf" <<'SYSCTL'
kernel.apparmor_restrict_unprivileged_userns=0
SYSCTL

    # ---- 启动脚本 ----
    cat > "$rootdir/usr/local/bin/steam-gamemode" <<'STEOF'
#!/bin/bash
# Steam Game Mode — 原生 ARM64 BPM
export XDG_RUNTIME_DIR=/run/user/1000
export SDL_VIDEO_DRIVER=wayland
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland
export MOZ_ENABLE_WAYLAND=1
export FEX_ROOTFS=/var/lib/FEX/rootfs
export STEAM_FRAME_FORCE_CLOSE=1

STEAM_DIR="$HOME/.local/share/Steam"

for i in $(seq 1 30); do
    [ -e /dev/dri/card0 ] && break
    sleep 1
done

if [ -x "$STEAM_DIR/steamrtarm64/steam" ]; then
    exec gamescope --adaptive-sync --rt -e -- \
        "$STEAM_DIR/steamrtarm64/steam" -tenfoot -fulldesktopres -gamepadui -steamos3
else
    exec gamescope --adaptive-sync --rt -e -- \
        FEXBash steam -tenfoot -fulldesktopres -gamepadui -steamos3
fi
STEOF
    chmod +x "$rootdir/usr/local/bin/steam-gamemode"

    cat > "$rootdir/usr/local/bin/steam-desktop" <<'SDEOF'
#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/1000
export FEX_ROOTFS=/var/lib/FEX/rootfs
STEAM_DIR="$HOME/.local/share/Steam"
if [ -x "$STEAM_DIR/steamrtarm64/steam" ]; then
    exec "$STEAM_DIR/steamrtarm64/steam" "$@"
else
    exec FEXBash steam "$@"
fi
SDEOF
    chmod +x "$rootdir/usr/local/bin/steam-desktop"

    # 权限
    chroot "$rootdir" chown -R "${USERNAME:-gamer}:${USERNAME:-gamer}" \
        "$steam_dir" \
        "$rootdir/home/${USERNAME:-gamer}/.steam" 2>/dev/null || true

    echo "原生 ARM64 Steam + Proton + FEX 安装完成"
}

# ---------------------------------------------------------------------------
# install_retroarch  — RetroArch + libretro 核心
# ---------------------------------------------------------------------------
install_retroarch() {
    local rootdir="$1"
    echo "安装 RetroArch..."

    chroot "$rootdir" apt-get install -y --no-install-recommends \
        retroarch \
        retroarch-assets \
        libretro-core-info 2>/dev/null || {
        echo "  RetroArch 不在仓库中，跳过" >&2
        return 1
    }

    echo "RetroArch 安装完成"
}

# ---------------------------------------------------------------------------
# install_emulationstation  — EmulationStation Desktop Edition
# ---------------------------------------------------------------------------
install_emulationstation() {
    local rootdir="$1"
    local es_version="3.1.6"
    local es_url="https://gitlab.com/es-de/emulationstation-de/-/releases/v${es_version}/downloads/EmulationStation-DE-x64_${es_version}.AppImage"

    echo "安装 EmulationStation DE ${es_version}..."

    wget -nv -O "$rootdir/usr/local/bin/EmulationStation.AppImage" "$es_url" || {
        echo "  ES-DE 下载失败，跳过" >&2
        return 1
    }
    chmod +x "$rootdir/usr/local/bin/EmulationStation.AppImage"

    local user="${USERNAME:-gamer}"
    mkdir -p "$rootdir/home/$user/ES-DE/roms"
    mkdir -p "$rootdir/home/$user/ES-DE/downloaded_media"
    mkdir -p "$rootdir/home/$user/ES-DE/gamelists"

    cat > "$rootdir/home/$user/ES-DE/es_settings.xml" <<'ESEOF'
<?xml version="1.0"?>
<settings>
    <string name="ThemeSet" value="linear-es-de" />
    <string name="UIMode" value="full" />
    <bool name="FullscreenMode" value="true" />
    <string name="ROMDirectory" value="~/ES-DE/roms" />
</settings>
ESEOF

    chroot "$rootdir" chown -R "$user:$user" "/home/$user/ES-DE"

    echo "EmulationStation DE 安装完成"
}

# ---------------------------------------------------------------------------
# install_mangohud  — MangoHud 性能覆盖层
# ---------------------------------------------------------------------------
install_mangohud() {
    local rootdir="$1"
    echo "安装 MangoHud..."

    chroot "$rootdir" apt-get install -y --no-install-recommends mangohud 2>/dev/null || {
        echo "  MangoHud 不在仓库中，跳过" >&2
        return 1
    }

    local user="${USERNAME:-gamer}"
    mkdir -p "$rootdir/home/$user/.config/MangoHud"
    cat > "$rootdir/home/$user/.config/MangoHud/MangoHud.conf" <<'MH'
fps
gpu_stats
cpu_stats
ram
temp
frame_timing
MH
    chroot "$rootdir" chown -R "$user:$user" "/home/$user/.config/MangoHud"

    echo "MangoHud 安装完成"
}

# ---------------------------------------------------------------------------
# install_controller_support  — 手柄支持
# ---------------------------------------------------------------------------
install_controller_support() {
    local rootdir="$1"
    echo "安装手柄支持..."

    chroot "$rootdir" apt-get install -y --no-install-recommends \
        joystick \
        gamecontrollerdb 2>/dev/null || true

    cat > "$rootdir/etc/udev/rules.d/99-gamepad.rules" <<'GEOF'
SUBSYSTEM=="input", ATTRS{name}=="*Xbox*", MODE="0666", ENV{ID_INPUT_JOYSTICK}="1"
SUBSYSTEM=="input", ATTRS{name}=="*PlayStation*", MODE="0666", ENV{ID_INPUT_JOYSTICK}="1"
SUBSYSTEM=="input", ATTRS{name}=="*DualSense*", MODE="0666", ENV{ID_INPUT_JOYSTICK}="1"
SUBSYSTEM=="input", ATTRS{name}=="*DualShock*", MODE="0666", ENV{ID_INPUT_JOYSTICK}="1"
SUBSYSTEM=="input", ATTRS{name}=="*Nintendo*", MODE="0666", ENV{ID_INPUT_JOYSTICK}="1"
SUBSYSTEM=="input", ATTRS{name}=="*Gamepad*", MODE="0666", ENV{ID_INPUT_JOYSTICK}="1"
SUBSYSTEM=="input", ATTRS{name}=="*Controller*", MODE="0666", ENV{ID_INPUT_JOYSTICK}="1"
SUBSYSTEM=="input", ATTRS{name}=="*8BitDo*", MODE="0666", ENV{ID_INPUT_JOYSTICK}="1"
SUBSYSTEM=="input", ATTRS{name}=="*Steam*", MODE="0666", ENV{ID_INPUT_JOYSTICK}="1"
GEOF

    echo "手柄支持安装完成"
}

# ---------------------------------------------------------------------------
# setup_gaming_session  — 配置游戏会话 (Game Mode / Desktop Mode 切换)
#   参数: <rootdir> <launcher> <desktop> <username>
# ---------------------------------------------------------------------------
setup_gaming_session() {
    local rootdir="$1"
    local launcher="${2:-steam}"
    local desktop="${3:-gamescope}"
    local user="${4:-gamer}"

    echo "配置游戏会话 (launcher=$launcher, desktop=$desktop)..."

    # ---- 模式标志目录 ----
    mkdir -p "$rootdir/var/lib/sheng-steamos"

    # ---- Game Mode 服务 (Gamescope + Steam BPM) ----
    cat > "$rootdir/etc/systemd/system/steam-gamemode.service" <<GMSVC
[Unit]
Description=Steam Game Mode (Gamescope + BPM)
After=systemd-user-sessions.service NetworkManager.service
After=systemd-logind.service
ConditionPathExists=/var/lib/sheng-steamos/gamemode-active

[Service]
User=${user}
PAMName=login
TTYPath=/dev/tty1
UnsetEnvironment=TERM

Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_SESSION_CLASS=user
Environment=XDG_SEAT=seat0
Environment=SDL_VIDEO_DRIVER=wayland
Environment=QT_QPA_PLATFORM=wayland
Environment=GDK_BACKEND=wayland
Environment=MOZ_ENABLE_WAYLAND=1
Environment=FEX_ROOTFS=/var/lib/FEX/rootfs

ExecStart=/usr/local/bin/steam-gamemode
Restart=always
RestartSec=3

[Install]
WantedBy=graphical.target
GMSVC

    # ---- Desktop Mode 服务 ----
    if [ "$desktop" = "kde" ] || [ "$desktop" = "gnome" ]; then
        local desktop_exec
        if [ "$desktop" = "kde" ]; then
            desktop_exec="/usr/bin/startplasma-wayland"
        else
            desktop_exec="/usr/bin/gnome-session"
        fi

        cat > "$rootdir/etc/systemd/system/desktop-mode.service" <<DMSVC
[Unit]
Description=Desktop Mode (${desktop})
After=systemd-user-sessions.service NetworkManager.service
After=systemd-logind.service
Conflicts=steam-gamemode.service
ConditionPathExists=/var/lib/sheng-steamos/desktop-active

[Service]
User=${user}
PAMName=login
TTYPath=/dev/tty1
UnsetEnvironment=TERM

Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_SESSION_CLASS=user
Environment=XDG_SEAT=seat0

ExecStart=${desktop_exec}
Restart=always
RestartSec=3

[Install]
WantedBy=graphical.target
DMSVC
    fi

    # ---- 切换脚本 ----
    cat > "$rootdir/usr/local/bin/switch-to-desktop" <<'S2D'
#!/bin/bash
set -euo pipefail
echo "切换到桌面模式..."
sudo rm -f /var/lib/sheng-steamos/gamemode-active
sudo touch /var/lib/sheng-steamos/desktop-active
sudo systemctl stop steam-gamemode.service 2>/dev/null || true
sudo systemctl start desktop-mode.service 2>/dev/null || true
S2D
    chmod +x "$rootdir/usr/local/bin/switch-to-desktop"

    cat > "$rootdir/usr/local/bin/switch-to-gamemode" <<'S2G'
#!/bin/bash
set -euo pipefail
echo "切换到游戏模式..."
sudo rm -f /var/lib/sheng-steamos/desktop-active
sudo touch /var/lib/sheng-steamos/gamemode-active
sudo systemctl stop desktop-mode.service 2>/dev/null || true
sudo systemctl start steam-gamemode.service 2>/dev/null || true
S2G
    chmod +x "$rootdir/usr/local/bin/switch-to-gamemode"

    # ---- 桌面快捷方式 ----
    mkdir -p "$rootdir/home/$user/Desktop"
    cat > "$rootdir/home/$user/Desktop/switch-to-gamemode.desktop" <<SGEOF
[Desktop Entry]
Type=Application
Name=返回游戏模式
Comment=Switch back to Steam Game Mode
Exec=/usr/local/bin/switch-to-gamemode
Icon=steam
Terminal=false
Categories=Game;
SGEOF
    chmod +x "$rootdir/home/$user/Desktop/switch-to-gamemode.desktop"

    # ---- Steam BPM 中的 "切换到桌面" ----
    mkdir -p "$rootdir/home/$user/.local/share/applications"
    cat > "$rootdir/home/$user/.local/share/applications/switch-to-desktop.desktop" <<SDEOF
[Desktop Entry]
Type=Application
Name=Desktop Mode
Comment=Switch to Desktop
Exec=/usr/local/bin/switch-to-desktop
Icon=desktop
Terminal=false
Categories=System;
SDEOF

    # ---- sudoers ----
    cat > "$rootdir/etc/sudoers.d/sheng-steamos-switch" <<SUDOERS
${user} ALL=(ALL) NOPASSWD: /usr/local/bin/switch-to-desktop
${user} ALL=(ALL) NOPASSWD: /usr/local/bin/switch-to-gamemode
${user} ALL=(ALL) NOPASSWD: /usr/bin/systemctl start steam-gamemode.service
${user} ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop steam-gamemode.service
${user} ALL=(ALL) NOPASSWD: /usr/bin/systemctl start desktop-mode.service
${user} ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop desktop-mode.service
${user} ALL=(ALL) NOPASSWD: /usr/bin/touch /var/lib/sheng-steamos/*
${user} ALL=(ALL) NOPASSWD: /usr/bin/rm /var/lib/sheng-steamos/*
SUDOERS
    chmod 440 "$rootdir/etc/sudoers.d/sheng-steamos-switch"

    # ---- 默认 Game Mode ----
    touch "$rootdir/var/lib/sheng-steamos/gamemode-active"

    mkdir -p "$rootdir/etc/systemd/system/graphical.target.wants"
    ln -sf /etc/systemd/system/steam-gamemode.service \
        "$rootdir/etc/systemd/system/graphical.target.wants/steam-gamemode.service"

    # ---- 性能调优 ----
    cat > "$rootdir/etc/security/limits.d/99-gaming.conf" <<'GQEOF'
@audio   -  rtprio     95
@audio   -  memlock    unlimited
${user}  -  nice       -10
GQEOF

    cat > "$rootdir/etc/sysctl.d/99-gaming.conf" <<'GSYEOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
kernel.sched_autogroup_enabled=1
fs.inotify.max_user_watches=524288
GSYEOF

    # ---- 环境变量 ----
    cat > "$rootdir/etc/profile.d/gaming-env.sh" <<ENVEOF
export SDL_VIDEO_DRIVER=wayland
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland
export MOZ_ENABLE_WAYLAND=1
export FEX_ROOTFS=/var/lib/FEX/rootfs
export STEAM_FRAME_FORCE_CLOSE=1
ENVEOF

    # ---- 权限 ----
    chroot "$rootdir" chown -R "$user:$user" \
        "/home/$user/Desktop" \
        "/home/$user/.local" 2>/dev/null || true

    echo "游戏会话配置完成"
    echo "  默认: Game Mode (Gamescope + Steam BPM)"
    echo "  切换: BPM → 'Desktop Mode' / 桌面 → '返回游戏模式'"
}
