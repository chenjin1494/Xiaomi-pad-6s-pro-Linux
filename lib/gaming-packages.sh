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

    # FEX-Emu is installed separately via install_fex_emu()

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
# install_mesa_from_source — Build Mesa with Turnip (Adreno) Vulkan driver
#   params: <rootdir>
#   Reference: ROCKNIX mesa package.mk
#   Builds: freedreno (gallium) + turnip (vulkan) for SM8550 Adreno 740
# ---------------------------------------------------------------------------
install_mesa_from_source() {
    local rootdir="$1"
    echo "Building Mesa from mainline git (Turnip + Freedreno)..."

    # Install build dependencies
    chroot "$rootdir" pacman -S --noconfirm --needed \
        base-devel \
        meson \
        ninja \
        python-mako \
        python-pyyaml \
        libdrm \
        libxml2 \
        libx11 \
        libxcb \
        libxshmfence \
        libxrandr \
        libxdamage \
        libxfixes \
        libxxf86vm \
        xorgproto \
        wayland \
        wayland-protocols \
        llvm \
        llvm-libs \
        elfutils \
        expat \
        zlib \
        zstd \
        vulkan-headers \
        vulkan-icd-loader \
        glslang \
        spirv-tools \
        spirv-llvm-translator \
        clang \
        cmake \
        pkgconf \
        python-packaging 2>/dev/null || true

    # Clone Mesa mainline
    local build_dir="/tmp/mesa-build"
    mkdir -p "$rootdir$build_dir"
    git clone --depth=1 https://gitlab.freedesktop.org/mesa/mesa.git "$rootdir$build_dir/mesa" || {
        echo "Error: Failed to clone Mesa" >&2
        return 1
    }

    local src_dir="$build_dir/mesa"
    local mesa_version
    mesa_version=$(cd "$rootdir$build_dir/mesa" && git describe --tags --always 2>/dev/null || echo "git")

    # Configure with meson — Turnip + Freedreno for Adreno 740
    # Performance optimizations:
    #   - release buildtype with b_lto for link-time optimization
    #   - shader-cache for reduced stuttering
    #   - draw-use-llvm=false (faster CPU-side, freedreno doesn't need it)
    chroot "$rootdir" bash -c "cd $src_dir && \
        meson setup build \
            --prefix=/usr \
            --libdir=lib \
            --buildtype=release \
            -Db_lto=true \
            -Db_pgo=off \
            -Dplatforms=wayland,x11 \
            -Dgallium-drivers=freedreno,softpipe,llvmpipe,virgl \
            -Dvulkan-drivers=freedreno \
            -Dgles1=disabled \
            -Dgles2=enabled \
            -Degl=enabled \
            -Dgbm=enabled \
            -Dopengl=true \
            -Dllvm=enabled \
            -Dshared-llvm=enabled \
            -Dshader-cache=enabled \
            -Dgallium-extra-hud=true \
            -Dgallium-rusticl=false \
            -Dgallium-va=disabled \
            -Dgallium-vdpau=disabled \
            -Dgallium-xa=disabled \
            -Dva-api=disabled \
            -Dvdpau=disabled \
            -Dvalgrind=disabled \
            -Dlibunwind=disabled \
            -Dlmsensors=disabled \
            -Dbuild-tests=false \
            -Dtools=[] \
            -Ddraw-use-llvm=false" 2>/dev/null || {
        echo "Warning: Mesa meson setup failed" >&2
        return 1
    }

    # Build
    chroot "$rootdir" bash -c "cd $src_dir && ninja -C build" 2>/dev/null || {
        echo "Warning: Mesa build failed" >&2
        return 1
    }

    # Install
    chroot "$rootdir" bash -c "cd $src_dir && ninja -C build install" 2>/dev/null || {
        echo "Warning: Mesa install failed" >&2
        return 1
    }

    # Cleanup build dir
    chroot "$rootdir" rm -rf "$build_dir"

    echo "Mesa ${mesa_version} (Turnip + Freedreno, LTO) built and installed"
}

# ---------------------------------------------------------------------------
# install_rpcs3 — RPCS3 PlayStation 3 emulator
#   params: <rootdir>
# ---------------------------------------------------------------------------
install_rpcs3() {
    local rootdir="$1"
    echo "Installing RPCS3 (PlayStation 3 emulator)..."

    local rpcs3_url="https://github.com/RPCS3/rpcs3-binaries-linux-arm64/releases/download/build-daa437904edaddc746a466d7a3c76e415bba5c00/rpcs3-v0.0.42-19689-daa43790_linux_aarch64.AppImage"
    wget -nv -O "$rootdir/usr/local/bin/rpcs3.AppImage" "$rpcs3_url" || {
        echo "Warning: RPCS3 download failed" >&2
        return 1
    }
    chmod +x "$rootdir/usr/local/bin/rpcs3.AppImage"

    # Create desktop entry
    local user="${USERNAME:-gamer}"
    mkdir -p "$rootdir/home/$user/.config/rpcs3"
    mkdir -p "$rootdir/home/$user/.local/share/rpcs3"
    cat > "$rootdir/usr/local/share/applications/rpcs3.desktop" <<'RPDEOF'
[Desktop Entry]
Type=Application
Name=RPCS3
Comment=PlayStation 3 Emulator
Exec=/usr/local/bin/rpcs3.AppImage %f
Icon=rpcs3
Terminal=false
Categories=Game;Emulator;
MimeType=application/x-ps3-rom;
RPDEOF
    chmod +x "$rootdir/usr/local/share/applications/rpcs3.desktop"

    chroot "$rootdir" chown -R "$user:$user" \
        "/home/$user/.config/rpcs3" \
        "/home/$user/.local/share/rpcs3"

    echo "RPCS3 installed"
}

# ---------------------------------------------------------------------------
# install_eden — Eden Nintendo Switch emulator (fork of Yuzu)
#   params: <rootdir>
# ---------------------------------------------------------------------------
install_eden() {
    local rootdir="$1"
    echo "Installing Eden v0.2.1 (Nintendo Switch emulator)..."

    # Download from stable.eden-emu.dev
    local eden_url="https://stable.eden-emu.dev/v0.2.1/Eden-Linux-v0.2.1-aarch64-clang-pgo.AppImage"
    wget -nv -O "$rootdir/usr/local/bin/eden.AppImage" "$eden_url" || {
        echo "Warning: Eden download failed, trying AUR fallback..."
        chroot "$rootdir" pacman -S --noconfirm --needed eden-bin 2>/dev/null || {
            echo "Warning: Eden install failed" >&2
            return 1
        }
    }
    chmod +x "$rootdir/usr/local/bin/eden.AppImage" 2>/dev/null || true

    # Eden config directory
    local user="${USERNAME:-gamer}"
    mkdir -p "$rootdir/home/$user/.config/eden"
    mkdir -p "$rootdir/home/$user/.local/share/eden"
    chroot "$rootdir" chown -R "$user:$user" \
        "/home/$user/.config/eden" \
        "/home/$user/.local/share/eden"

    echo "Eden installed"
}

# ---------------------------------------------------------------------------
# install_box64 — Box64 x86_64 emulator for aarch64
# ---------------------------------------------------------------------------
install_box64() {
    local rootdir="$1"
    echo "Installing Box64..."

    chroot "$rootdir" pacman -S --noconfirm --needed box64 2>/dev/null || {
        echo "  box64 not in repos, trying AUR..."
        chroot "$rootdir" su -l "${USERNAME:-gamer}" -c "yay -S --noconfirm box64" 2>/dev/null || {
            echo "  Trying manual Box64 install..."
            local box64_url="https://github.com/ptitSeb/box64/releases/latest/download/box64-aarch64.tar.gz"
            wget -nv -O /tmp/box64.tar.gz "$box64_url" 2>/dev/null || true
            if [ -f /tmp/box64.tar.gz ]; then
                tar -xzf /tmp/box64.tar.gz -C "$rootdir/usr/local/" 2>/dev/null || true
                rm -f /tmp/box64.tar.gz
            fi
        }
    }

    # Box64 environment
    cat > "$rootdir/etc/profile.d/box64-env.sh" <<'BOX64ENV'
export BOX64_DYNAREC=1
export BOX64_DYNAREC_STRONGMEM=2
export BOX64_DYNAREC_BIGBLOCK=1
BOX64ENV

    echo "Box64 installed"
}

# ---------------------------------------------------------------------------
# install_fex_emu — FEX-Emu x86_64 emulator (standalone install)
# ---------------------------------------------------------------------------
install_fex_emu() {
    local rootdir="$1"
    echo "Installing FEX-Emu..."

    chroot "$rootdir" pacman -S --noconfirm --needed fex-emu 2>/dev/null || {
        echo "  FEX-Emu not in repos, trying manual install..."
        local fex_ver="FEX-2605"
        local fex_url="https://github.com/FEX-Emu/FEX/releases/download/${fex_ver}/${fex_ver}-aarch64.tar.gz"
        wget -nv -O /tmp/fex.tar.gz "$fex_url" 2>/dev/null || true
        if [ -f /tmp/fex.tar.gz ]; then
            tar -xzf /tmp/fex.tar.gz -C "$rootdir/usr/local/" 2>/dev/null || true
            rm -f /tmp/fex.tar.gz
        fi
    }

    # FEX rootfs
    chroot "$rootdir" bash -c "FEXRootFSFetcher --name Ubuntu_24_04 --rootfs-path /var/lib/FEX/rootfs" 2>/dev/null || true

    echo "FEX-Emu installed"
}

# ---------------------------------------------------------------------------
# install_emulators — RetroArch + standalone emulators
# ---------------------------------------------------------------------------
install_emulators() {
    local rootdir="$1"
    echo "Installing emulators..."

    # RetroArch + libretro cores
    install_retroarch "$rootdir"

    # Standalone emulators via pacman
    chroot "$rootdir" pacman -S --noconfirm --needed \
        dolphin-emu \
        ppsspp \
        pcsx2 \
        rpcs3 \
        yuzu \
        citra \
        mgba \
        desmume \
        snes9x \
        mupen64plus \
        duckstation \
        flycast \
        dosbox \
        dosbox-staging \
        scummvm \
        wine \
        winetricks \
        gamemode \
        vkbasalt 2>/dev/null || {
        echo "  Warning: Some emulators not available in repos, skipping unavailable ones"
        # Try individual installs for what's available
        for pkg in dolphin-emu ppsspp mgba mupen64plus dosbox-staging scummvm wine winetricks gamemode; do
            chroot "$rootdir" pacman -S --noconfirm --needed "$pkg" 2>/dev/null || true
        done
    }

    # EmulationStation DE
    install_emulationstation "$rootdir"

    echo "Emulators installed"
}

# ---------------------------------------------------------------------------
# install_gaming_extras — Additional gaming tools and launchers
# ---------------------------------------------------------------------------
install_gaming_extras() {
    local rootdir="$1"
    echo "Installing gaming extras..."

    # Gaming tools
    chroot "$rootdir" pacman -S --noconfirm --needed \
        gamemode \
        vkbasalt \
        mangohud \
        goverlay \
        steam-devices \
        gamecontrollerdb \
        lib32-mesa \
        lib32-vulkan-swrast \
        lib32-sdl2 2>/dev/null || {
        echo "  Warning: Some gaming extras not available"
        for pkg in gamemode mangohud steam-devices gamecontrollerdb; do
            chroot "$rootdir" pacman -S --noconfirm --needed "$pkg" 2>/dev/null || true
        done
    }

    # Lutris (game manager)
    chroot "$rootdir" pacman -S --noconfirm --needed lutris 2>/dev/null || true

    # Heroic Games Launcher (Epic/GOG)
    chroot "$rootdir" pacman -S --noconfirm --needed heroic-games-launcher-bin 2>/dev/null || {
        echo "  Heroic not in repos, trying manual install..."
        local heroic_url="https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/releases/latest/download/Heroic-x86_64.AppImage"
        wget -nv -O "$rootdir/usr/local/bin/heroic.AppImage" "$heroic_url" 2>/dev/null || true
        chmod +x "$rootdir/usr/local/bin/heroic.AppImage" 2>/dev/null || true
    }

    echo "Gaming extras installed"
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
    mkdir -p "$rootdir/etc/security/limits.d"
    mkdir -p "$rootdir/etc/sysctl.d"
    mkdir -p "$rootdir/etc/profile.d"
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
