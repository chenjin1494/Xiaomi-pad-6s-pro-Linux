#!/bin/bash
# =============================================================================
# gaming-packages.sh — SteamOS Gaming System Component Library (Arch Linux ARM)
# =============================================================================
# All functions accept <rootdir> as first argument.
# Execute package installs inside chroot via pacman.
# =============================================================================

# ---------------------------------------------------------------------------
# install_gaming_base — Gaming system base dependencies
# ---------------------------------------------------------------------------
install_gaming_base() {
    local rootdir="$1"
    echo "Installing gaming base dependencies..."

    chroot "$rootdir" pacman -Syu --noconfirm --needed \
        mesa vulkan-swrast vulkan-tools \
        pipewire pipewire-alsa pipewire-pulse wireplumber \
        alsa-utils alsa-ucm-conf \
        libinput libxkbcommon xorg-xwayland \
        qt5-wayland qt6-wayland \
        sdl2 libevdev libusb \
        fontconfig ttf-dejavu noto-fonts noto-fonts-cjk \
        networkmanager wpa_supplicant wireless-regdb \
        bluez bluez-utils \
        nss wget curl git base-devel

    chroot "$rootdir" systemctl --global enable pipewire pipewire-pulse wireplumber 2>/dev/null || true
    chroot "$rootdir" systemctl enable NetworkManager bluetooth 2>/dev/null || true

    echo "Gaming base dependencies installed"
}

# ---------------------------------------------------------------------------
# install_gamescope — Gamescope compositor
# ---------------------------------------------------------------------------
install_gamescope() {
    local rootdir="$1"
    echo "Installing Gamescope..."

    chroot "$rootdir" pacman -S --noconfirm --needed gamescope 2>/dev/null || {
        echo "  gamescope not in repos, trying AUR..."
        chroot "$rootdir" su -l "$USERNAME" -c "yay -S --noconfirm gamescope" 2>/dev/null || {
            echo "  Warning: gamescope install failed, using Weston fallback" >&2
            chroot "$rootdir" pacman -S --noconfirm --needed weston 2>/dev/null || true
        }
    }

    echo "Gamescope installed"
}

# ---------------------------------------------------------------------------
# install_steam — Native ARM64 Steam client + Proton ARM64 + FEX-Emu
# ---------------------------------------------------------------------------
install_steam() {
    set +e
    local rootdir="$1"
    echo "Installing Native ARM64 Steam + Proton ARM64..."

    # Dependencies
    chroot "$rootdir" pacman -S --noconfirm --needed \
        sdl2 libvpx libgtk2 nss libcurl-compat \
        steam-devices gamecontrollerdb 2>/dev/null || true

    local user="${USERNAME:-gamer}"
    local steam_dir="$rootdir/home/$user/.local/share/Steam"
    mkdir -p "$steam_dir"

    # ---- Native ARM64 Steam client ----
    echo "  >>> Downloading native ARM64 Steam client..."
    local steam_zip="bins_linuxarm64_linuxarm64.zip"
    local steam_url="https://client-update.steamstatic.com/bins_linuxarm64_linuxarm64.zip.f523fa87fc6b9b5435a5e7370cb0d664ef53b50b"

    wget -nv -O "/tmp/$steam_zip" "$steam_url" || {
        echo "Error: Failed to download ARM64 Steam client" >&2
        return 1
    }
    if file "/tmp/$steam_zip" | grep -q 'Zip archive\|data' 2>/dev/null; then
        bsdtar -xf "/tmp/$steam_zip" -C "$steam_dir/" || {
            echo "Warning: bsdtar extraction failed, trying unzip..."
            unzip -o "/tmp/$steam_zip" -d "$steam_dir/" 2>/dev/null || true
        }
    else
        echo "Warning: Downloaded file is not a valid zip" >&2
    fi
    rm -f "/tmp/$steam_zip"

    # Beta channel
    mkdir -p "$steam_dir/package"
    echo "publicbeta" > "$steam_dir/package/beta"
    chmod -R u+rwx "$steam_dir/steamrtarm64/" 2>/dev/null || true
    echo "  Native ARM64 Steam client installed"

    # ---- Proton ARM64 ----
    echo "  >>> Downloading Proton ARM64 + Steam Linux Runtime..."
    local proton_tar="arm-64proton-runtime-64.tar"
    local proton_url="https://archive.org/download/arm-64proton-runtime-64.tar"
    local compat_dir="$steam_dir/compatibilitytools.d"
    mkdir -p "$compat_dir"

    wget -nv -O "/tmp/$proton_tar" "$proton_url" || {
        echo "Warning: Failed to download Proton ARM64" >&2
    }
    if [ -f "/tmp/$proton_tar" ]; then
        # Verify it's a valid tar file
        if file "/tmp/$proton_tar" | grep -q 'tar archive' 2>/dev/null; then
            tar -xf "/tmp/$proton_tar" -C "$compat_dir/"
            echo "  Proton ARM64 installed"
        else
            echo "  Warning: Downloaded file is not a valid tar, skipping Proton ARM64" >&2
        fi
        rm -f "/tmp/$proton_tar"
    fi

    # ---- SDK symlink ----
    mkdir -p "$rootdir/home/$user/.steam"
    ln -sf "$steam_dir/linuxarm64" "$rootdir/home/$user/.steam/sdkarm64"

    # ---- libvpx compat symlink ----
    if [ -f "$rootdir/usr/lib/libvpx.so.9" ] && [ ! -f "$rootdir/usr/lib/libvpx.so.6" ]; then
        ln -sf libvpx.so.9 "$rootdir/usr/lib/libvpx.so.6"
    fi

    # ---- FEX-Emu ----
    echo "  >>> Installing FEX-Emu..."
    chroot "$rootdir" pacman -S --noconfirm --needed fex-emu 2>/dev/null || {
        echo "  FEX-Emu not in repos, trying AUR..."
        chroot "$rootdir" su -l "$user" -c "yay -S --noconfirm fex-emu" 2>/dev/null || {
            echo "  Trying manual FEX-Emu install..."
            local fex_ver="FEX-2605"
            local fex_url="https://github.com/FEX-Emu/FEX/releases/download/${fex_ver}/${fex_ver}-aarch64.tar.gz"
            wget -nv -O /tmp/fex.tar.gz "$fex_url" 2>/dev/null || true
            if [ -f /tmp/fex.tar.gz ]; then
                tar -xzf /tmp/fex.tar.gz -C "$rootdir/usr/local/"
                rm -f /tmp/fex.tar.gz
            fi
        }
    }

    # FEX rootfs
    chroot "$rootdir" bash -c "FEXRootFSFetcher --name Ubuntu_24_04 --rootfs-path /var/lib/FEX/rootfs" 2>/dev/null || true

    # ---- AppArmor userns fix ----
    cat > "$rootdir/etc/sysctl.d/99-steam-userns.conf" <<'SYSCTL'
kernel.apparmor_restrict_unprivileged_userns=0
SYSCTL

    # ---- Launch scripts ----
    cat > "$rootdir/usr/local/bin/steam-gamemode" <<'STEOF'
#!/bin/bash
# Steam Game Mode — Native ARM64 BPM
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

    # Permissions
    chroot "$rootdir" chown -R "$user:$user" "$steam_dir" "$rootdir/home/$user/.steam" 2>/dev/null || true

    echo "Native ARM64 Steam + Proton + FEX installed"
    set -e
    return 0
}

# ---------------------------------------------------------------------------
# install_retroarch — RetroArch + libretro cores
# ---------------------------------------------------------------------------
install_retroarch() {
    local rootdir="$1"
    echo "Installing RetroArch..."

    chroot "$rootdir" pacman -S --noconfirm --needed \
        retroarch retroarch-assets retroarch-database \
        libretro-beetle-pce-fast libretro-beetle-psx libretro-beetle-psx-hw \
        libretro-beetle-saturn libretro-beetle-supergrafx \
        libretro-blastem libretro-bsnes libretro-desmume \
        libretro-dolphin libretro-fceumm libretro-flycast \
        libretro-gambatte libretro-genesis-plus-gx libretro-mgba \
        libretro-mupen64plus-next libretro-nestopia \
        libretro-picodrive libretro-ppsspp libretro-snes9x \
        libretro-stella libretro-vba-next libretro-yabause \
        libretro-shaders-glsl libretro-shaders-slang 2>/dev/null || {
        echo "  Warning: Some libretro cores not available" >&2
    }

    echo "RetroArch installed"
}

# ---------------------------------------------------------------------------
# install_emulationstation — EmulationStation Desktop Edition
# ---------------------------------------------------------------------------
install_emulationstation() {
    local rootdir="$1"
    local es_version="3.1.6"
    local es_url="https://gitlab.com/es-de/emulationstation-de/-/releases/v${es_version}/downloads/EmulationStation-DE-x64_${es_version}.AppImage"

    echo "Installing EmulationStation DE ${es_version}..."

    wget -nv -O "$rootdir/usr/local/bin/EmulationStation.AppImage" "$es_url" || {
        echo "  ES-DE download failed, skipping" >&2
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
    echo "EmulationStation DE installed"
}

# ---------------------------------------------------------------------------
# install_mangohud — MangoHud performance overlay
# ---------------------------------------------------------------------------
install_mangohud() {
    local rootdir="$1"
    echo "Installing MangoHud..."

    chroot "$rootdir" pacman -S --noconfirm --needed mangohud 2>/dev/null || {
        echo "  MangoHud not available, skipping" >&2
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
    echo "MangoHud installed"
}

# ---------------------------------------------------------------------------
# install_controller_support — Gamepad support
# ---------------------------------------------------------------------------
install_controller_support() {
    local rootdir="$1"
    echo "Installing controller support..."

    chroot "$rootdir" pacman -S --noconfirm --needed \
        sdl2 steam-devices gamecontrollerdb 2>/dev/null || true

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

    echo "Controller support installed"
}

# ---------------------------------------------------------------------------
# install_desktop_mode — KDE Plasma or GNOME desktop
#   params: <rootdir> <desktop:kde|gnome>
# ---------------------------------------------------------------------------
install_desktop_mode() {
    local rootdir="$1"
    local desktop="${2:-kde}"
    echo "Installing desktop mode ($desktop)..."

    if [ "$desktop" = "kde" ]; then
        chroot "$rootdir" pacman -S --noconfirm --needed \
            plasma-desktop plasma-nm plasma-pa \
            konsole dolphin kate \
            sddm firefox \
            xdg-desktop-portal xdg-desktop-portal-kde \
            xdg-utils maliit-keyboard 2>/dev/null || {
            echo "  Warning: Some KDE packages failed, trying minimal..." >&2
            chroot "$rootdir" pacman -S --noconfirm --needed \
                plasma-desktop sddm konsole dolphin 2>/dev/null || true
        }

        # SDDM autologin
        mkdir -p "$rootdir/etc/sddm.conf.d"
        cat > "$rootdir/etc/sddm.conf.d/autologin.conf" <<EOF
[General]
DisplayServer=wayland

[Autologin]
User=${USERNAME:-gamer}
Session=plasma.desktop
EOF

        # KDE touchscreen optimization
        mkdir -p "$rootdir/home/${USERNAME:-gamer}/.config"
        cat > "$rootdir/home/${USERNAME:-gamer}/.config/kwinrc" <<'KWINRC'
[Wayland]
InputMethod=im.qtvirtualkeyboard

[Windows]
ElectricBorders=1
KWINRC

    elif [ "$desktop" = "gnome" ]; then
        chroot "$rootdir" pacman -S --noconfirm --needed \
            gnome gnome-extra gdm firefox \
            xdg-desktop-portal xdg-desktop-portal-gnome \
            xdg-utils 2>/dev/null || {
            chroot "$rootdir" pacman -S --noconfirm --needed \
                gnome gdm firefox 2>/dev/null || true
        }

        # GDM autologin
        mkdir -p "$rootdir/etc/gdm"
        cat > "$rootdir/etc/gdm/custom.conf" <<EOF
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=${USERNAME:-gamer}
EOF
    fi

    chroot "$rootdir" chown -R "${USERNAME:-gamer}:${USERNAME:-gamer}" \
        "/home/${USERNAME:-gamer}/.config" 2>/dev/null || true

    echo "Desktop mode ($desktop) installed"
}

# ---------------------------------------------------------------------------
# setup_gaming_session — Configure Game Mode / Desktop Mode switching
#   params: <rootdir> <launcher> <desktop> <username>
# ---------------------------------------------------------------------------
setup_gaming_session() {
    local rootdir="$1"
    local launcher="${2:-steam}"
    local desktop="${3:-gamescope}"
    local user="${4:-gamer}"

    echo "Configuring gaming session (launcher=$launcher, desktop=$desktop)..."

    # Mode flag directory
    mkdir -p "$rootdir/var/lib/sheng-steamos"

    # ---- Game Mode service (Gamescope + Steam BPM) ----
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

    # ---- Desktop Mode service ----
    if [ "$desktop" = "kde" ] || [ "$desktop" = "gnome" ]; then
        local desktop_exec
        [ "$desktop" = "kde" ] && desktop_exec="/usr/bin/startplasma-wayland" || desktop_exec="/usr/bin/gnome-session"

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

    # ---- Switch scripts ----
    cat > "$rootdir/usr/local/bin/switch-to-desktop" <<'S2D'
#!/bin/bash
set -euo pipefail
echo "Switching to Desktop Mode..."
sudo rm -f /var/lib/sheng-steamos/gamemode-active
sudo touch /var/lib/sheng-steamos/desktop-active
sudo systemctl stop steam-gamemode.service 2>/dev/null || true
sudo systemctl start desktop-mode.service 2>/dev/null || true
S2D
    chmod +x "$rootdir/usr/local/bin/switch-to-desktop"

    cat > "$rootdir/usr/local/bin/switch-to-gamemode" <<'S2G'
#!/bin/bash
set -euo pipefail
echo "Switching to Game Mode..."
sudo rm -f /var/lib/sheng-steamos/desktop-active
sudo touch /var/lib/sheng-steamos/gamemode-active
sudo systemctl stop desktop-mode.service 2>/dev/null || true
sudo systemctl start steam-gamemode.service 2>/dev/null || true
S2G
    chmod +x "$rootdir/usr/local/bin/switch-to-gamemode"

    # ---- Desktop shortcut ----
    mkdir -p "$rootdir/home/$user/Desktop"
    cat > "$rootdir/home/$user/Desktop/switch-to-gamemode.desktop" <<SGEOF
[Desktop Entry]
Type=Application
Name=Return to Game Mode
Exec=/usr/local/bin/switch-to-gamemode
Icon=steam
Terminal=false
Categories=Game;
SGEOF
    chmod +x "$rootdir/home/$user/Desktop/switch-to-gamemode.desktop"

    # ---- Steam BPM "Switch to Desktop" entry ----
    mkdir -p "$rootdir/home/$user/.local/share/applications"
    cat > "$rootdir/home/$user/.local/share/applications/switch-to-desktop.desktop" <<SDEOF
[Desktop Entry]
Type=Application
Name=Desktop Mode
Exec=/usr/local/bin/switch-to-desktop
Icon=desktop
Terminal=false
Categories=System;
SDEOF

    # ---- Sudoers for mode switching ----
    cat > "$rootdir/etc/sudoers.d/sheng-steamos-switch" <<SUDOERS
${user} ALL=(ALL) NOPASSWD: /usr/l…ktop
${user} ALL=(ALL) NOPASSWD: /usr/l…mode
${user} ALL=(ALL) NOPASSWD: /usr/b…mctl start steam-gamemode.service
${user} ALL=(ALL) NOPASSWD: /usr/b…mctl stop steam-gamemode.service
${user} ALL=(ALL) NOPASSWD: /usr/b…mctl start desktop-mode.service
${user} ALL=(ALL) NOPASSWD: /usr/b…mctl stop desktop-mode.service
${user} ALL=(ALL) NOPASSWD: *** /var/lib/sheng-steamos/*
${user} ALL=(ALL) NOPASSWD: *** /var/lib/sheng-steamos/*
SUDOERS
    chmod 440 "$rootdir/etc/sudoers.d/sheng-steamos-switch"

    # ---- Default: Game Mode ----
    touch "$rootdir/var/lib/sheng-steamos/gamemode-active"

    mkdir -p "$rootdir/etc/systemd/system/graphical.target.wants"
    ln -sf /etc/systemd/system/steam-gamemode.service \
        "$rootdir/etc/systemd/system/graphical.target.wants/steam-gamemode.service"

    # ---- Performance tuning ----
    cat > "$rootdir/etc/security/limits.d/99-gaming.conf" <<'GQEOF'
@audio   -  rtprio     95
@audio   -  memlock    unlimited
GQEOF

    cat > "$rootdir/etc/sysctl.d/99-gaming.conf" <<'GSYEOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
kernel.sched_autogroup_enabled=1
fs.inotify.max_user_watches=524288
GSYEOF

    cat > "$rootdir/etc/profile.d/gaming-env.sh" <<ENVEOF
export SDL_VIDEO_DRIVER=wayland
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland
export MOZ_ENABLE_WAYLAND=1
export FEX_ROOTFS=/var/lib/FEX/rootfs
export STEAM_FRAME_FORCE_CLOSE=1
ENVEOF

    # Permissions
    chroot "$rootdir" chown -R "$user:$user" \
        "/home/$user/Desktop" "/home/$user/.local" 2>/dev/null || true

    echo "Gaming session configured"
    echo "  Default: Game Mode (Gamescope + Steam BPM)"
    echo "  Switch:  BPM -> 'Desktop Mode' / Desktop -> 'Return to Game Mode'"
}
