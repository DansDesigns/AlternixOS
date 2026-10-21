#!/bin/bash
set -e
clear

echo "===================================================================="
echo "                     Alternix Desktop Installer"
echo "                         (Devuan Edition)"
echo "===================================================================="
echo "           --------> Teaching Penguins to fly! <--------"
echo " "
echo "--------------------------------------------------------------------"
echo ""
echo " Setup can take a while, be sure to have a cuppa & some good music!"
echo ""
echo "--------------------------------------------------------------------"
echo ""
echo ""


# Root of the Alternix build repository (not the eventual user's home).
# Prefer the directory containing this installer; fall back to the original
# live-build layout (/root/Alternix when the ISO build runs as root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [ -d "$SCRIPT_DIR/Alternix" ]; then
    ALT_ROOT="$SCRIPT_DIR"
else
    ALT_ROOT="$HOME/Alternix"
fi

if [ ! -d "$ALT_ROOT" ]; then
    echo "ERROR: $ALT_ROOT not found. Please place install.sh inside ~/Alternix."
    exit 1
fi

# Ask for username
while true; do
    read -rp "Enter the username for Alternix: " TARGET_USER

    # Basic validation
    if [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        break
    else
        echo "Invalid username. Use only lowercase letters, digits, hyphens, and underscores."
    fi
done

# Check if user exists
if id "$TARGET_USER" >/dev/null 2>&1; then
    echo "User '$TARGET_USER' already exists. Skipping creation."
else
    echo "Creating user '$TARGET_USER'..."
    sudo useradd -m -s /bin/bash "$TARGET_USER"
    echo "User '$TARGET_USER' created."
fi


# Add to sudo (optional)
if ! groups "$TARGET_USER" | grep -q "\bsudo\b"; then
    echo "Adding '$TARGET_USER' to sudo group..."
    sudo usermod -aG sudo "$TARGET_USER"
fi

# Grant NOPASSWD now, up front — the rest of this script makes dozens of
# sudo calls (package installs, config copies, app builds/moves). Without
# this, the sudo credential cache expires mid-script (default 15 min) and
# a later sudo call fails silently under `set -e`, aborting the install
# partway through with no clear error.
echo "Setting NOPASSWD for $TARGET_USER..."
echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/alternix-nopasswd >/dev/null
sudo chmod 440 /etc/sudoers.d/alternix-nopasswd

echo ""
# Always use the selected account's actual home for user configuration,
# even if the ISO build/installer itself is running as root.
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    echo "ERROR: Could not locate home directory for user '$TARGET_USER'."
    exit 1
fi
as_target() { sudo -u "$TARGET_USER" -H "$@"; }

echo "User setup complete. Username set to: $TARGET_USER"
echo "• User home: $TARGET_HOME"
echo "• Build source: $ALT_ROOT"
echo ""




# ────────────────────────────────────────────────
# 1. Install apps & dependencies
# ────────────────────────────────────────────────
echo "[1/10] Installing system dependencies..."

echo "[System] Updating APT package lists.."
sudo apt update

echo "[System] Installing XLibre.."
sudo apt install -y ca-certificates curl

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://xlibre-deb.github.io/key.asc | sudo tee /etc/apt/keyrings/xlibre-deb.asc
sudo chmod a+r /etc/apt/keyrings/xlibre-deb.asc

# Use the dedicated Devuan repo — Devuan codenames used directly
DEVUAN_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
ARCH=$(dpkg --print-architecture)
echo "[System] Installing XLibre for Devuan '$DEVUAN_CODENAME'..."
sudo tee /etc/apt/sources.list.d/xlibre-deb.sources > /dev/null << XLIBRESRC
Types: deb deb-src
URIs: https://xlibre-deb.github.io/devuan/
Suites: ${DEVUAN_CODENAME}
Components: main
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/xlibre-deb.asc
XLIBRESRC

sudo apt update
sudo apt install xlibre -y
#sudo dpkg --add-architecture i386

echo "[System] Installing Required Components.."
sudo apt install -y \
    build-essential git qtbase5-dev qt5-qmake qtdeclarative5-dev xdg-utils cmake g++\
    fonts-noto-color-emoji libxcomposite-dev libxrender-dev libxfixes-dev fonts-freefont-ttf \
    xwallpaper pkg-config libpoppler-qt5-dev htop python3-pip python3-lxml fonts-urw-base35 \
    python3-venv qtile python3-cffi python3-xcffib picom redshift onboard fake-hwclock libcamera-ipa\
    samba xdotool alacritty sqlite3 fuse libmbim-utils libqmi-utils modemmanager libcamera-tools \
    synaptic brightnessctl pavucontrol pulseaudio alsa-utils mpg123 flatpak libevdev-dev \
    elogind libpam-elogind xserver-xlibre-input-libinput ssh mobile-broadband-provider-info \
    xprintidle libx11-dev libxtst-dev ntfs-3g aria2 x11-apps zip iio-sensor-proxy wmctrl \
    kalk vlc qt5-style-kvantum thermald network-manager aptitude timeshift tlp fonts-ubuntu \
    python3-yaml python3-dateutil python3-pyqt5 python3-packaging python3-requests \
    podman podman-compose gvfs gvfs-backends gvfs-fuse gvfs-daemons fuse3 dbus-x11 \
    sysvinit-utils pm-utils ntfs-3g exfatprogs exfat-fuse udisks2 pmount libxext-dev

echo ""
echo "[System] Installing Qtile, Qtile-Extras & mypy"
pip3 install qtile qtile-extras mypy --break-system-packages

echo "NOTE: snapd is NOT available on Devuan (it depends on systemd)."
echo "If snap packages are needed, use flatpak equivalents instead."
echo ""
echo ""



# ────────────────────────────────────────────────
#  Install Flatpaks
# ────────────────────────────────────────────────

echo "[System] Clearing space in /var/cache/apt/archive..."
sudo rm -rf /var/cache/apt/archives

echo "[System] Adding flatpak Components.."
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

echo "[System] Installing Flatpaks..."

flatpak install -y flathub com.github.joseexposito.touche
flatpak install -y flathub org.kde.kweather
flatpak install -y flathub org.kde.qrca
flatpak install -y flathub com.freerdp.FreeRDP
flatpak install -y flathub com.github.tchx84.Flatseal

# Flatpak Games:
#flatpak install -y flathub net.retrodeck.retrodeck
flatpak install -y flathub net.wz2100.wz2100

echo "[System] Installing Bauh Application Manager.."
sudo pip3 install bauh --break-system-packages


# ────────────────────────────────────────────────
# Install all .deb packages in ~/Alternix/installers/
# ────────────────────────────────────────────────
echo " "
echo "[System] Installing local .deb packages..."

INSTALLER_DIR="$ALT_ROOT/Alternix/installers"

if [ -d "$INSTALLER_DIR" ]; then
    DEB_COUNT=$(ls -1 "$INSTALLER_DIR"/*.deb 2>/dev/null | wc -l)

    if [ "$DEB_COUNT" -gt 0 ]; then
        echo "• Found $DEB_COUNT installer package(s). Installing..."
        sudo dpkg -i "$INSTALLER_DIR"/*.deb || true
        sudo apt -f install -y
        sudo dpkg -i "$INSTALLER_DIR"/*.deb || true
        echo "• Local installer packages installed."
    else
        echo "• No .deb files in installers folder, skipping."
    fi
else
    echo "• No installers folder found, skipping."
fi



# ────────────────────────────────────────────────
#            Curl Commands
# ────────────────────────────────────────────────

cd "$ALT_ROOT/Alternix"

echo "[System] Installing Starship prompt..."
curl -sS https://starship.rs/install.sh | sh -s -- --yes

if ! grep -Fxq 'eval "$(starship init bash)"' "$TARGET_HOME/.bashrc"; then
    echo 'eval "$(starship init bash)"' >> "$TARGET_HOME/.bashrc"
fi

echo "[System] Installing Brave Browser..."
curl -fsS https://dl.brave.com/install.sh | sh -s -- --yes

#echo "[System] Updating bash aliases..."
#echo 'alias sudo="osm-sudo sudo -S"' >> "$TARGET_HOME/.bashrc"

# ────────────────────────────────────────────────
# Copy ALL configs from ~/Alternix/configs → ~/.config
# ────────────────────────────────────────────────
echo " "
echo "[Config] Installing user configs..."

CONFIG_SRC="$ALT_ROOT/Alternix/configs"
CONFIG_DST="$TARGET_HOME/.config"

sudo cp "$ALT_ROOT/Alternix/configs/.alacritty.toml" "$TARGET_HOME/.alacritty.toml"

mkdir -p "$CONFIG_DST"

if [ -d "$CONFIG_SRC" ]; then
    echo "• Copying configs from $CONFIG_SRC → $CONFIG_DST"
    cp -r "$CONFIG_SRC/"* "$CONFIG_DST/"
    echo "• Configs installed."
else
    echo "• No configs folder found, skipping."
fi

sudo cp -r "$ALT_ROOT/Alternix/onboard" /usr/share/onboard



# ────────────────────────────────────────────────
# Install Fonts
# ────────────────────────────────────────────────
echo " "
echo "[Config] Installing Fonts..."

if [ -d "$ALT_ROOT/Alternix/fonts" ]; then
    sudo mkdir -p /usr/local/share/fonts/alternix
    sudo cp -r "$ALT_ROOT/Alternix/fonts/"* /usr/local/share/fonts/alternix/
    sudo fc-cache -f
    echo "• Fonts installed successfully."
else
    echo "• No fonts folder found, skipping."
fi

# ────────────────────────────────────────────────
# Install Wallpapers
# ────────────────────────────────────────────────
echo " "
echo "[Config] Installing Wallpapers..."

WALL_DST="$TARGET_HOME/Pictures/wallpapers"
mkdir -p "$WALL_DST"

if [ -d "$ALT_ROOT/Alternix/wallpapers" ]; then
    cp -r "$ALT_ROOT/Alternix/wallpapers/"* "$WALL_DST/"
    echo "• Wallpapers installed to $WALL_DST"
else
    echo "---------------------------------------"
    echo "• No wallpapers folder found, skipping."
    echo "---------------------------------------"
fi


# ────────────────────────────────────────────────
# Install Extras
# ────────────────────────────────────────────────
echo " "
echo "[Config] Installing Extras..."
mkdir -p "$TARGET_HOME/extras"

if [ -d "$ALT_ROOT/Alternix/extras" ]; then
    sudo cp -r "$ALT_ROOT/Alternix/extras/"* "$TARGET_HOME/extras/"

    echo "• Extras installed successfully."
else
    echo "--------------------------------"
    echo "• [ERROR] Installing Extras..."
    echo "--------------------------------"
fi


# ────────────────────────────────────────────────
# 2. Create & activate Qtile venv
# ────────────────────────────────────────────────
echo " "
echo "[2/10] Creating virtual environment (qtile_venv)..."

if [ ! -d "$TARGET_HOME/.qtile_venv" ]; then
    python3 -m venv "$TARGET_HOME/.qtile_venv"
fi

source "$TARGET_HOME/.qtile_venv/bin/activate"

echo "[3/10] Installing Python pip dependencies..."
# dbus-fast is what lets qtile hear elogind's sleep/resume signals.
# Without it @hook.subscribe.resume in config.py never fires, so the
# screen would not lock after waking from a lid-close suspend.
pip3 install qtile qtile-extras mypy dbus-fast --break-system-packages

# Symlink qtile binary to where udev rules expect it
sudo mkdir -p /usr/lib/udev
sudo ln -sf "$TARGET_HOME/.qtile_venv/bin/qtile" /usr/lib/udev/qtile

# Reloading udev rules only works against a running udevd — this script
# may run inside a chroot (e.g. the installer) where there's no
# udevd to talk to. udevadm exits non-zero in that case and would take
# down the rest of the install under `set -e`. Not fatal either way.
sudo udevadm control --reload-rules 2>/dev/null || true


# ────────────────────────────────────────────────
# 2a. Scripts
# ────────────────────────────────────────────────
echo " "
echo "[2a/10] Installing Scrolling Layout for Qtile..."

mkdir -p "$TARGET_HOME/.config/Alternix"
mkdir -p "$TARGET_HOME/.local/bin"
cp -r "$ALT_ROOT/Alternix/scripts" "$TARGET_HOME/.config/Alternix/"

cd "$TARGET_HOME/.config/Alternix/scripts"
chmod +x alternix-rotate-monitor.sh
chmod +x alternix-rotate-setup.sh
chmod +x alternix-rotate-toggle.sh
chmod +x alternix-audio-fix.sh

#echo "• [Configuring AlternixOS audio]..."
#bash "$TARGET_HOME/.config/Alternix/scripts/alternix-audio-fix.sh"

echo "• [Configuring AlternixOS touchscroll]..."
chmod +x alternix-touchscroll.py
cp alternix-touchscroll.py "$TARGET_HOME/.local/bin/alternix-touchscroll.py"

echo "• [Configuring AlternixOS Android layer]..."
chmod +x alternix-waydroid-session
sudo install -m 755 alternix-waydroid-session /usr/local/bin

echo "• [Configuring AlternixOS Windows layer]..."
chmod +x alternix-exe
sudo install -m 755 alternix-exe /usr/local/bin


# ────────────────────────────────────────────────
# 3. Configure xinitrc autostart
# ────────────────────────────────────────────────
echo " "
echo "[4/10] Creating .xinitrc autostart..."
cat <<EOF > "$TARGET_HOME/.xinitrc"
#!/bin/sh
. "\$HOME/.qtile_venv/bin/activate"
exec dbus-launch --exit-with-session "\$HOME/.qtile_venv/bin/qtile" start
EOF
chmod +x "$TARGET_HOME/.xinitrc"


# ────────────────────────────────────────────────
# 4. Bash profile auto startx
# ────────────────────────────────────────────────
echo " "
echo "[6/10] Creating ~/.bash_profile auto-start..."
cat <<EOF > "$TARGET_HOME/.bash_profile"
# auto-start X only on tty1 and only if not already running
if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    startx
fi
EOF

# ────────────────────────────────────────────────
# 5. Build Alternix Apps
# ────────────────────────────────────────────────
echo " "
echo "• Creating .local/share/applications folder..."
echo " "
mkdir -p "$TARGET_HOME/.local/share/applications"
echo "[7/10] Building Alternix apps..."
cd "$ALT_ROOT/Alternix" || { echo "ERROR: $ALT_ROOT not found"; exit 1; }

echo "• Building osm-launcher..."
g++ -O3 -fPIC apps/osm-launcher.cpp -o osm-launcher $(pkg-config --cflags --libs Qt5Widgets)
sudo install -m 755 osm-launcher /usr/local/bin/

echo "• Building osm-launcher-lock-cleaner..."
chmod +x osm-launcher-lockclean && sudo mv osm-launcher-lockclean /usr/local/bin/
#sudo install -m 755 osm-launcher-lockclean /usr/local/bin/

echo "• Building osm-lock..."
g++ apps/osm-lock.cpp -o osm-lock -fPIC $(pkg-config --cflags --libs Qt5Widgets)
sudo install -m 755 osm-lock /usr/local/bin/

echo "• Building osm-running..."
g++ apps/osm-running.cpp -o osm-running -fPIC -ldl $(pkg-config --cflags --libs Qt5Widgets) -lX11
sudo install -m 755 osm-running /usr/local/bin/

echo "• Building osm-notify..."
g++ -fPIC apps/osm-notify.cpp -o osm-notify $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core Qt5DBus) -lX11 -lXtst
sudo install -m 755 osm-notify /usr/local/bin/

echo "• Building osm-status..."
g++ -fPIC apps/osm-status.cpp -o osm-status -ldl $(pkg-config --cflags --libs Qt5Widgets Qt5DBus) -lX11
sudo install -m 755 osm-status /usr/local/bin/

echo "• Installing sounds..."
# Drop notify.* and alarm.* (wav/ogg/flac/mp3) in ~/.config/Alternix/sounds/
#mkdir -p "$TARGET_HOME/.config/Alternix/sounds"
cp -r "$ALT_ROOT/Alternix/sounds" "$TARGET_HOME/.config/Alternix/"


echo "• Building osm-clock..."
g++ apps/osm-clock.cpp -o osm-clock -fPIC -ldl $(pkg-config --cflags --libs Qt5Widgets) -lX11
sudo install -m 755 osm-clock /usr/local/bin/

cat <<EOF > "$TARGET_HOME/.local/share/applications/osm-clock.desktop"
[Desktop Entry]
Type=Application
Name=Clock
Comment=Clock, Alarms, Timer & Stopwatch for Alternix / OSM-Phone
Exec=/usr/local/bin/osm-clock
Icon=osm-clock
Terminal=false
Categories=Utility;Clock;
StartupNotify=false
EOF
chmod +x "$TARGET_HOME/.local/share/applications/osm-clock.desktop"

echo "• Building osm-paper..."
g++ -fPIC apps/osm-paper.cpp -o osm-paper $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core)
sudo install -m 755 osm-paper /usr/local/bin/

if [ -f "icons/osm-paper.png" ]; then
    sudo cp icons/osm-paper.png /usr/share/icons/hicolor/64x64/apps/osm-paper.png
fi

cat <<EOF > "$TARGET_HOME/.local/share/applications/osm-paper.desktop"
[Desktop Entry]
Type=Application
Name=Wallpapers
Comment=Picture Manager for Alternix / OSM-Phone
Exec=/usr/local/bin/osm-paper
Icon=osm-paper
Terminal=false
Categories=Utility;FileManager;
StartupNotify=false
EOF
chmod +x "$TARGET_HOME/.local/share/applications/osm-paper.desktop"

echo "• Installing osm-paper-restore..."
sudo install -m 755 apps/osm-paper-restore /usr/local/bin/

echo "• Building osm-styling..."
g++ -fPIC apps/osm-styling.cpp -o osm-styling $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core)
sudo install -m 755 osm-styling /usr/local/bin/

echo "• Building osm-files..."
g++ -fPIC apps/osm-files.cpp -o osm-files $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core)
sudo install -m 755 osm-files /usr/local/bin/

if [ -f "icons/osm-files.png" ]; then
    sudo cp icons/osm-files.png /usr/share/icons/hicolor/64x64/apps/osm-files.png
fi

cat <<EOF > "$TARGET_HOME/.local/share/applications/osm-files.desktop"
[Desktop Entry]
Type=Application
Name=Files
Comment=File Manager for Alternix / OSM-Phone
Exec=/usr/local/bin/osm-files
Icon=osm-files
Terminal=false
Categories=Utility;FileManager;
StartupNotify=false
EOF
chmod +x "$TARGET_HOME/.local/share/applications/osm-files.desktop"

echo "• Building osm-viewer..."
g++ -fPIC apps/osm-viewer.cpp -o osm-viewer $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core poppler-qt5) -Wno-deprecated-declarations
sudo install -m 755 osm-viewer /usr/local/bin/

if [ -f "icons/osm-viewer.png" ]; then
    sudo cp icons/osm-viewer.png /usr/share/icons/hicolor/64x64/apps/osm-viewer.png
fi

cat <<EOF > "$TARGET_HOME/.local/share/applications/osm-viewer.desktop"
[Desktop Entry]
Type=Application
Name=File Editor/Viewer
Comment=File Viewer for Alternix / OSM-Phone
Exec=/usr/local/bin/osm-viewer %U
Icon=osm-viewer
Terminal=false
MimeType=application/octet-stream;application/pdf;text/plain;image/*;inode/directory;
Categories=Utility;FileManager;
StartupNotify=false
EOF
chmod +x "$TARGET_HOME/.local/share/applications/osm-viewer.desktop"

echo "• Building osm-draw..."
g++ -fPIC apps/osm-draw.cpp -o osm-draw -std=c++17 $(pkg-config --cflags --libs Qt5Widgets)
sudo install -m 755 osm-draw /usr/local/bin/

if [ -f "icons/osm-draw.png" ]; then
    sudo cp icons/osm-draw.png /usr/share/icons/hicolor/64x64/apps/osm-draw.png
fi

cat <<EOF > "$TARGET_HOME/.local/share/applications/osm-draw.desktop"
[Desktop Entry]
Type=Application
Name=Draw
Comment=Drawing App for Alternix / OSM-Phone
Exec=/usr/local/bin/osm-draw %U
Icon=osm-draw
Terminal=false
Categories=Utility;Drawing;
StartupNotify=false
EOF
chmod +x "$TARGET_HOME/.local/share/applications/osm-draw.desktop"

echo "• Building osm-rocker..."
g++ -fPIC apps/osm-rocker.cpp -o osm-rocker $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core)
sudo install -m 755 osm-rocker /usr/local/bin/

echo "• Installing osm-sudo..."
sudo install -m 755 apps/osm-sudo /usr/local/bin/

echo "• Building osm-power..."
g++ -fPIC apps/osm-power.cpp -o osm-power $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core)
sudo install -m 755 osm-power /usr/local/bin/

echo "• Compiling osm-powerd..."
sudo g++ -O2 apps/osm-powerd.cpp -o osm-powerd
sudo install -m 755 osm-powerd /usr/local/bin/
sudo chown root:root /usr/local/bin/osm-powerd
sudo chmod 4755 /usr/local/bin/osm-powerd

echo "• Building osm-lockscreen..."
g++ -fPIC apps/osm-lockscreen.cpp -o osm-lockscreen $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core)
sudo install -m 755 osm-lockscreen /usr/local/bin/


# ────────────────────────────────────────────────
# 6. Build OSM Settings + modules
# ────────────────────────────────────────────────
echo " "
echo "[8/10] Building osm-settings..."

cd "$ALT_ROOT/Alternix/apps/osm-settings" || { echo "ERROR: apps/osm-settings folder missing"; exit 1; }

g++ osm-settings.cpp -o osm-settings -fPIC -ldl $(pkg-config --cflags --libs Qt5Widgets)
sudo install -m 755 osm-settings /usr/local/bin/

if [ -f "$ALT_ROOT/Alternix/icons/osm-settings.png" ]; then
    sudo cp "$ALT_ROOT/Alternix/icons/osm-settings.png" /usr/share/icons/hicolor/64x64/apps/osm-settings.png
fi

cat <<EOF > "$TARGET_HOME/.local/share/applications/osm-settings.desktop"
[Desktop Entry]
Type=Application
Name=Settings
Comment=Settings App for Alternix / OSM-Phone
Exec=/usr/local/bin/osm-settings
Icon=osm-settings
Terminal=false
Categories=Utility;
StartupNotify=false
EOF
chmod +x "$TARGET_HOME/.local/share/applications/osm-settings.desktop"

echo "• Building wifi.so..."
g++ -fPIC -shared wifi.cpp -o wifi.so $(pkg-config --cflags --libs Qt5Widgets)
sudo install -m755 wifi.so /usr/local/bin/

echo "• Building bluetooth.so..."
g++ -fPIC -shared bluetooth.cpp -o bluetooth.so $(pkg-config --cflags --libs Qt5Widgets)
sudo install -m755 bluetooth.so /usr/local/bin/

echo "• Building apps.so..."
g++ -fPIC -shared apps.cpp -o apps.so $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core)
sudo install -m755 apps.so /usr/local/bin/

echo "• Building mobile.so..."
g++ -fPIC -shared mobile.cpp -o mobile.so $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core)
sudo install -m755 mobile.so /usr/local/bin/

echo "• Building location.so..."
g++ location.cpp -o location.so -shared -fPIC -O2 $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core)
sudo install -m755 location.so /usr/local/bin/

echo "• Building battery.so..."
g++ -fPIC -shared battery.cpp -o battery.so $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core)
sudo install -m755 battery.so /usr/local/bin/

echo "• Building emulation.so..."
g++ emulation.cpp -o emulation.so -shared -fPIC $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core)
sudo install -m755 emulation.so /usr/local/bin/

echo "• Building security.so..."
g++ -shared -fPIC security.cpp -o security.so `pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core`
sudo install -m755 security.so /usr/local/bin/

echo "• Building ethernet.so..."
g++ -fPIC -shared ethernet.cpp -o ethernet.so $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core)
sudo install -m755 ethernet.so /usr/local/bin/

echo "• Building display.so..."
g++ display.cpp -o display.so -shared -fPIC $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core)
sudo install -m755 display.so /usr/local/bin/

echo "• Building sound.so..."
g++ -std=c++17 -fPIC -shared sound.cpp -o sound.so `pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core`
sudo install -m755 sound.so /usr/local/bin/

echo "• Building kernel.so..."
g++ -std=c++17 -fPIC -shared kernel.cpp -o kernel.so `pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core`
sudo install -m755 kernel.so /usr/local/bin/

echo "• Building storage.so..."
g++ -fPIC -shared storage.cpp -o storage.so $(pkg-config --cflags --libs Qt5Widgets)
sudo install -m755 storage.so /usr/local/bin/

echo "• Building accounts.so..."
g++ -std=c++11 accounts.cpp -o accounts.so -shared -fPIC $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core)
sudo install -m755 accounts.so /usr/local/bin/

echo "• Building system.so..."
g++ -fPIC -shared system.cpp -o system.so $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core)
sudo install -m755 system.so /usr/local/bin/

echo "• Building ui.so..."
g++ -fPIC -shared ui.cpp -o ui.so $(pkg-config --cflags --libs Qt5Widgets Qt5Gui Qt5Core)
sudo install -m755 ui.so /usr/local/bin/

echo "• Building reticulum.so..."
g++ -std=c++17 -Wall -Wextra -fPIC -shared -o reticulum.so reticulum.cpp $(pkg-config --cflags --libs Qt5Widgets)
sudo install -m755 reticulum.so /usr/local/bin/reticulum.so

# ────────────────────────────────────────────────
# 6b. Build OSM Widgets (desktop widget overlay)
# ────────────────────────────────────────────────
echo " "
echo "[8/10] Building osm-widgets..."

cd "$ALT_ROOT/Alternix/apps/osm-widgets" || { echo "ERROR: apps/osm-widgets folder missing"; exit 1; }

sudo mkdir -p /usr/local/lib/alternix/widgets

g++ -fPIC osm-widgets.cpp -o osm-widgets -ldl $(pkg-config --cflags --libs Qt5Widgets) -lX11 -lXext
sudo install -m 755 osm-widgets /usr/local/bin/

echo "• Building osm-widgets-settings..."
g++ osm-widgets-settings.cpp -o osm-widgets-settings -fPIC -ldl $(pkg-config --cflags --libs Qt5Widgets)
sudo install -m 755 osm-widgets-settings  /usr/local/bin/

echo "• Building clock.so widget..."
g++ -I. -fPIC -shared widgets/clock.cpp -o clock.so $(pkg-config --cflags --libs Qt5Widgets)
sudo mv clock.so /usr/local/lib/alternix/widgets/



if [ -f "$ALT_ROOT/Alternix/icons/osm-widgets.png" ]; then
    sudo cp "$ALT_ROOT/Alternix/icons/osm-widgets.png" /usr/share/icons/hicolor/64x64/apps/osm-widgets.png
fi

cat <<EOF > "$TARGET_HOME/.local/share/applications/osm-widgets.desktop"
[Desktop Entry]
Type=Application
Name=Widgets
Comment=Add and arrange widgets on the Alternix desktop
Exec=/usr/local/bin/osm-widgets-settings
Icon=osm-widgets
Terminal=false
Categories=Utility;
StartupNotify=false
EOF
chmod +x "$TARGET_HOME/.local/share/applications/osm-widgets.desktop"

# ────────────────────────────────────────────────
#            Custom App Shortcuts & Icons
# ────────────────────────────────────────────────
echo " "
echo "• Installing App Icons..."

cd "$ALT_ROOT/Alternix"

sudo install -Dm644 icons/*.png /usr/share/icons/hicolor/64x64/apps/

echo "• Creating htop.desktop launcher..."
sudo tee /usr/share/applications/htop.desktop >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=htop
Comment=System monitor
Exec=alacritty -e htop
Terminal=false
Icon=htop
Categories=System;
EOF

echo "• Creating fetch.desktop launcher..."
sudo tee /usr/share/applications/fetch.desktop >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=About
Comment=System monitor
Exec=alacritty -e fetch
Terminal=false
Icon=fetch
Categories=System;
EOF

echo "• Creating bauh Shortcut..."
sudo tee /usr/share/applications/bauh.desktop >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=Apps (bauh)
Comment=Application Manager
Exec=bauh
Icon=bauh
Categories=System;
EOF

echo "• Installing Alternix Updater..."
sudo install -m 755 "$ALT_ROOT/update/os-check-update" /usr/bin/
sudo install -D -m 644 "$ALT_ROOT/update/version.txt" /usr/share/alternix/version.txt


echo "• Creating Alternix Updater shortcut..."
sudo tee /usr/share/applications/os-check-update.desktop >/dev/null <<EOF
[Desktop Entry]
Name=System Update
Exec=alacritty -e /usr/bin/os-check-update
Icon=os-check-update
Type=Application
Terminal=true
Categories=System;
EOF



# ────────────────────────────────────────────────
# Create Brave YouTube WebApp launcher
# ────────────────────────────────────────────────
echo " "
echo "[System] Installing Brave WebApps..."

APP_DIR="$TARGET_HOME/.local/share/applications"
mkdir -p "$APP_DIR"

YOUTUBE_ICON="/usr/share/icons/hicolor/256x256/apps/youtube.png"
if [ -f "$ALT_ROOT/Alternix/icons/youtube.png" ]; then
    sudo cp "$ALT_ROOT/Alternix/icons/youtube.png" "$YOUTUBE_ICON"
fi

cat <<EOF > "$APP_DIR/youtube-webapp.desktop"
#!/usr/bin/env xdg-open
[Desktop Entry]
Version=1.0
Type=Application
Name=Youtube
Comment=Youtube WebApp (Brave)
Exec=brave-browser --app=https://www.youtube.com/ --new-window --disable-frame --force-device-scale-factor=1.3
Icon=youtube
Terminal=false
Categories=Network;WebBrowser;Utility;
StartupNotify=true
EOF
chmod +x "$APP_DIR/youtube-webapp.desktop"
echo "✓ YouTube WebApp installed."

echo "[Apps] Installing AlterniTech Forum WebApp..."
if [ -f "icons/alternitech-forum.png" ]; then
    sudo cp icons/alternitech-forum.png /usr/share/icons/hicolor/64x64/apps/alternitech-forum.png
fi

cat <<EOF > "$TARGET_HOME/.local/share/applications/alternitech-forums.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Alternitech Forums
Comment=Alternitech Community Forum WebApp (Brave)
Exec=brave-browser --app=https://alternitech.freeforums.net/ --new-window --force-device-scale-factor=1.3
Icon=alternitech-forum
Terminal=false
Categories=Network;WebBrowser;Utility;
StartupNotify=true
EOF
chmod +x "$TARGET_HOME/.local/share/applications/alternitech-forums.desktop"
echo "✓ Alternitech Forums WebApp installed."


echo "[Apps] Installing Breakout Game..."
if [ -f "extras/games/breakout.png" ]; then
    sudo cp "$ALT_ROOT/Alternix/extras/games/breakout.png" /usr/share/icons/hicolor/64x64/apps/breakout.png
fi

cat <<EOF > "$TARGET_HOME/.local/share/applications/breakout.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Breakout
Comment=Break the block game
Exec=brave-browser --app=file://$TARGET_HOME/extras/games/breakout.html --new-window --force-device-scale-factor=1.3
Icon=breakout
Terminal=false
Categories=Game;
StartupNotify=true
EOF
chmod +x "$TARGET_HOME/.local/share/applications/breakout.desktop"
echo "✓ Breakout Game installed."




echo "[Apps] Installing OpenStreetMap WebApp..."
if [ -f "icons/openmap.png" ]; then
    sudo cp icons/openmap.png /usr/share/icons/hicolor/64x64/apps/openmap.png
fi

cat <<EOF > "$TARGET_HOME/.local/share/applications/openmap.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=OpenStreetMap
Comment=OpenStreetMap WebApp (Brave)
Exec=brave-browser --app=https://openstreetmap.org/ --new-window --force-device-scale-factor=1.3
Icon=openmap
Terminal=false
Categories=Network;WebBrowser;Utility;
StartupNotify=true
EOF
chmod +x "$TARGET_HOME/.local/share/applications/openmap.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$TARGET_HOME/.local/share/applications" || true
fi
echo "• OpenStreetMap WebApp installed."


# ────────────────────────────────────────────────
# 7. Samba Network Updates
# ────────────────────────────────────────────────
echo " "
echo "• Updating /etc/samba/smb.conf..."
sudo sed -i '/workgroup = WORKGROUP/a client min protocol = NT1\nserver min protocol = NT1' /etc/samba/smb.conf

echo "• Restarting Samba service..."
# SysVinit: use service(8) instead of systemctl
sudo service smbd restart || true
sudo service nmbd restart || true


# ────────────────────────────────────────────────
# 8. OSM-Lockscreen Security Layer
# ────────────────────────────────────────────────
echo " "
echo "• Setting up lockscreen supervisor..."

# The lockscreen runs inside the user's own X session, started by
# osm-lockd from Qtile (login and resume) and from osm-power (Lock and
# Sleep). It used to also run as a system service under a separate
# "lockscreen" user, but that user had no access to the X display and
# `service` strips DISPLAY, so osm-lockscreen crashed on start and
# osm-lockd relaunched it every 0.05 s, forever. The service is gone.

# Install supervisor daemon (osm-lockd)
sudo tee /usr/local/bin/osm-lockd >/dev/null <<'LOCKD'
#!/bin/bash

# Only one lockscreen at a time. Waking and the Lock button can both
# start this, and a second copy would stack another lockscreen on top.
exec 9>"/tmp/osm-lockd-$(id -u).lock"
flock -n 9 || exit 0

FLAG="/tmp/osm_unlock_success"

while true; do
    rm -f "$FLAG"
    /usr/local/bin/osm-lockscreen 9>&-

    if [ -f "$FLAG" ]; then
        rm -f "$FLAG"
        # signal the user session (osm-status plays the boot sound once per boot)
        touch /tmp/osm_boot_unlocked 2>/dev/null
        chmod 666 /tmp/osm_boot_unlocked 2>/dev/null
        exit 0
    fi

    sleep 0.05
done
LOCKD
sudo chmod +x /usr/local/bin/osm-lockd

echo "[✓] Lockscreen supervisor installed."


# ────────────────────────────────────────────────
# 9. logind / elogind power key and sleep handling
# Devuan ships elogind as a drop-in for systemd-logind.
# Its config lives in /etc/elogind/logind.conf (same format).
# ────────────────────────────────────────────────
echo " "
echo "[X] Configuring elogind power key and sleep handling..."

sudo mkdir -p /etc/elogind/logind.conf.d /etc/elogind/sleep.conf.d

# Prevent unwanted tablet sleep from power/suspend keys, lid events and idle.
sudo tee /etc/elogind/logind.conf.d/alternix-power.conf >/dev/null <<'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF

# Disable elogind-managed suspend and hibernation on Devuan.
sudo tee /etc/elogind/sleep.conf.d/alternix-no-sleep.conf >/dev/null <<'EOF'
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
EOF

# Also update the main logind.conf as a fallback for older elogind versions
# that don't support drop-in dirs
sudo sed -i 's/^#*HandlePowerKey=.*/HandlePowerKey=ignore/' /etc/elogind/logind.conf 2>/dev/null || true

sudo service elogind restart || true

echo "[✓] elogind configured."


# ────────────────────────────────────────────────
# 10. Autologin via agetty override
# Devuan uses /etc/inittab (SysVinit) rather than systemd drop-ins.
# We replace the tty1 line to pass --autologin.
# ────────────────────────────────────────────────
echo " "
echo "[5/10] Enabling autologin on tty1 for user $TARGET_USER..."

INITTAB="/etc/inittab"

if [ -f "$INITTAB" ]; then
    # Back up inittab before editing
    sudo cp "$INITTAB" "${INITTAB}.bak"

    # Replace the tty1 getty line with an autologin version.
    # Typical Devuan line:  1:2345:respawn:/sbin/getty 38400 tty1
    # We change it to use agetty with --autologin.
    if grep -q "^1:.*getty.*tty1" "$INITTAB"; then
        sudo sed -i "s|^1:.*getty.*tty1.*|1:2345:respawn:/sbin/agetty --autologin $TARGET_USER --noclear tty1 linux|" "$INITTAB"
        echo "• inittab tty1 line updated for autologin."
    else
        # Line not found in expected format — append a safe fallback
        echo "1:2345:respawn:/sbin/agetty --autologin $TARGET_USER --noclear tty1 linux" | sudo tee -a "$INITTAB" >/dev/null
        echo "• Autologin line appended to inittab."
    fi

    # Changes will apply on next boot. Never HUP PID 1 from a live-build
    # chroot, since it may refer to the build host's init process.
    if [ ! -e /etc/debian_chroot ] && [ -e /run/initctl ]; then
        sudo telinit q 2>/dev/null || true
    fi
else
    echo "WARNING: /etc/inittab not found."
    echo "If using OpenRC or runit, configure autologin in your getty service config."
    echo "For OpenRC: edit /etc/conf.d/agetty.tty1 and set agetty_options."
fi

sudo usermod -aG video,input "$TARGET_USER"

# ────────────────────────────────────────────────
# 11. Cleanup Alternix folder
# ────────────────────────────────────────────────

echo " "
echo "[Cleanup] Removing Alternix source folder at $ALT_ROOT ..."
# Never remove the directory from which this shell is currently running.
cd /
rm -rf -- "$ALT_ROOT"

# Prepare a user-owned source checkout area for the third-party app installers.
# The old source repository and the new user checkout area are intentionally
# separate locations, even when the builder is running as root.
THIRD_PARTY_DIR="$TARGET_HOME/Alternix"
mkdir -p "$THIRD_PARTY_DIR"
chown "$TARGET_USER:$TARGET_GROUP" "$THIRD_PARTY_DIR"

# Build-time writes above must not leave the installed desktop owned by root.
for user_dir in "$TARGET_HOME/.config" "$TARGET_HOME/.local" \
                "$TARGET_HOME/.qtile_venv" "$TARGET_HOME/Pictures/wallpapers" \
                "$TARGET_HOME/extras"; do
    [ ! -e "$user_dir" ] || chown -R "$TARGET_USER:$TARGET_GROUP" "$user_dir"
done
for user_file in "$TARGET_HOME/.alacritty.toml" "$TARGET_HOME/.xinitrc" \
                 "$TARGET_HOME/.bash_profile" "$TARGET_HOME/.bashrc"; do
    [ ! -e "$user_file" ] || chown "$TARGET_USER:$TARGET_GROUP" "$user_file"
done

# Preserve existing clones when this installer is re-run.
clone_for_target() {
    local repo_url="$1" destination="$2"
    if [ -d "$destination/.git" ]; then
        echo "• Existing checkout found: $destination"
    elif [ -e "$destination" ]; then
        echo "ERROR: $destination already exists but is not a Git checkout."
        return 1
    else
        as_target git clone "$repo_url" "$destination"
    fi
}



# ────────────────────────────────────────────────
# 12. GLX compatibility check → patch picom.conf
# Detects whether the GPU supports GLX/OpenGL well
# enough for picom's glx backend. If not, switches
# picom.conf to xrender (safe on all hardware).
# ────────────────────────────────────────────────
echo " "
echo "•[Picom] Checking GLX compatibility..."

PICOM_CONF="$TARGET_HOME/.config/picom/picom.conf"
GLX_OK=false

# glxinfo must be available — install if missing
if ! command -v glxinfo >/dev/null 2>&1; then
    echo "• glxinfo not found, installing mesa-utils..."
    sudo apt install -y mesa-utils 2>/dev/null || true
fi

if command -v glxinfo >/dev/null 2>&1; then
    GL_RENDERER=$(glxinfo 2>/dev/null | grep "OpenGL renderer" | head -1)
    GL_VERSION=$(glxinfo 2>/dev/null | grep "OpenGL version" | head -1)

    echo "• Renderer : $GL_RENDERER"
    echo "• Version  : $GL_VERSION"

    # Extract the major OpenGL version number
    GL_MAJOR=$(echo "$GL_VERSION" | grep -oP 'OpenGL version string: \K[0-9]+' | head -1)

    # GLX backend requires OpenGL 2.0+ and a real renderer (not software/llvm)
    if [[ "$GL_MAJOR" -ge 2 ]] 2>/dev/null && \
       ! echo "$GL_RENDERER" | grep -qiE "llvmpipe|softpipe|software|swrast|virgl"; then
        GLX_OK=true
    fi
else
    echo "• glxinfo unavailable — assuming GLX not supported."
fi

if [ "$GLX_OK" = true ]; then
    echo "[✓] GLX compatible — picom will use glx backend."
else
    echo "[!] GLX not supported or too limited — switching picom to xrender backend."

    if [ -f "$PICOM_CONF" ]; then
        # Replace backend line if it exists
        if grep -q "^backend" "$PICOM_CONF"; then
            sed -i 's/^backend\s*=\s*"glx"/backend = "xrender"/' "$PICOM_CONF"
            sed -i 's/^backend\s*=\s*"egl"/backend = "xrender"/' "$PICOM_CONF"
        else
            # Prepend if no backend line found
            sed -i '1s/^/backend = "xrender";\n/' "$PICOM_CONF"
        fi

        # Disable vsync — unreliable with xrender on old Intel
        if grep -q "^vsync" "$PICOM_CONF"; then
            sed -i 's/^vsync\s*=\s*true/vsync = false/' "$PICOM_CONF"
        else
            echo "vsync = false;" >> "$PICOM_CONF"
        fi

        echo "[✓] picom.conf patched: backend = xrender, vsync = false"
    else
        echo "• $PICOM_CONF not found — creating minimal xrender config..."
        mkdir -p "$(dirname "$PICOM_CONF")"
        cat <<'PICOMCFG' > "$PICOM_CONF"
# picom config — xrender backend (auto-set: GLX not supported on this GPU)
backend = "xrender";
vsync = false;
PICOMCFG
        echo "[✓] Minimal xrender picom.conf created."
    fi
fi

# The installer may have written picom.conf as root while in the ISO chroot.
if [ -e "$PICOM_CONF" ]; then
    chown "$TARGET_USER:$TARGET_GROUP" "$PICOM_CONF"
fi

# ────────────────────────────────────────────────
# 13. 3D animated fetch (areofyl/fetch - used as "About")
# ────────────────────────────────────────────────
echo " "
echo "[SYSTEM] Starting 3rd Party Software Install... "
echo " "
echo "• Installing fetch (areofyl/fetch)..."
# Build fetch in temporary space; no dependence on $HOME or ALT_ROOT.
(
    set -e
    cd /
    FETCH_BUILD="$(mktemp -d /tmp/alternix-fetch.XXXXXX)"
    trap 'rm -rf -- "$FETCH_BUILD"' EXIT
    git clone --depth 1 https://github.com/areofyl/fetch.git "$FETCH_BUILD/fetch"
    make -C "$FETCH_BUILD/fetch"
    if [ "$(id -u)" -eq 0 ]; then
        make -C "$FETCH_BUILD/fetch" install
    else
        sudo make -C "$FETCH_BUILD/fetch" install
    fi
)
echo "[✓] 3D fetch Installed..."


# ──────────────────────────────────────────────── 
# 14. install rounded-corners
# ────────────────────────────────────────────────
echo " "

echo "• Installing rounded-corners..."
clone_for_target https://github.com/DansDesigns/rounded_corners "$THIRD_PARTY_DIR/rounded_corners"
cd "$THIRD_PARTY_DIR/rounded_corners"
chmod +x install_corners.sh
sudo ./install_corners.sh
echo "[✓] Rounded-Corers Installed..."


# ──────────────────────────────────────────────── 
# 15. install Merlin
# ────────────────────────────────────────────────
echo " "

echo "• Installing Merlin Browser..."
clone_for_target https://github.com/DansDesigns/merlin-browser "$THIRD_PARTY_DIR/merlin-browser"
cd "$THIRD_PARTY_DIR/merlin-browser"
chmod +x install.sh
as_target ./install.sh
echo "[✓] Merlin Browser Installed..."



# ────────────────────────────────────────────────
# 16. auto-cpufreq
# ────────────────────────────────────────────────
echo " "
echo "• Installing auto-cpufreq..."
clone_for_target https://github.com/AdnanHodzic/auto-cpufreq.git "$THIRD_PARTY_DIR/auto-cpufreq"
cd "$THIRD_PARTY_DIR/auto-cpufreq"
sudo ./auto-cpufreq-installer
sudo auto-cpufreq --install
echo "[✓] auto-cpufreq Installed..."


# ────────────────────────────────────────────────
# 17. Freehand Spatial Desktop
# ────────────────────────────────────────────────
echo " "
echo "• Installing Freehand Spatial Desktop..."
# Clone explicitly into lowercase 'hands' (Git would otherwise use 'Hands').
clone_for_target https://github.com/DansDesigns/Hands.git "$THIRD_PARTY_DIR/hands"
cd "$THIRD_PARTY_DIR/hands"
chmod +x install_linux.sh
as_target ./install_linux.sh
echo "[✓] Freehand Spatial Desktop Installed..."


# ────────────────────────────────────────────────
# 18. Wave PLayer
# ────────────────────────────────────────────────
echo " "
echo "• Installing Wave Music Player.."
clone_for_target https://github.com/DansDesigns/music_player "$TARGET_HOME/music_player"
cd "$TARGET_HOME/music_player"
chmod +x install_music_player.sh
as_target ./install_music_player.sh
echo "[✓] Wave PLayer Installed..."
cd /


# ────────────────────────────────────────────────
# Finish + prompt
# ────────────────────────────────────────────────
echo " "
echo " "
echo " "
echo " "
echo "=============================================="
echo "     Alternix installation complete!"
echo "     (Devuan / SysVinit Edition)"
echo "=============================================="
echo " "
echo ""
echo "Everything installed to /usr/local/bin/"
echo ""
echo "Autologin + startx enabled for user: $TARGET_USER"
echo ""
echo ".xinitrc configured for Qtile."
echo ""
echo "Init system: SysVinit  |  logind: elogind"
echo ""
echo "Press 1 to Restart"
echo "Press 2 to Continue"
echo ""

while true; do
    read -n 1 -s -r KEY
    if [[ "$KEY" == "1" ]]; then
        echo "Beginning Reboot Sequence..."
        echo " "
        echo "This window will self-destruct in 5 seconds..."
        sleep 1; echo "5.."
        sleep 1; echo "4.."
        sleep 1; echo "3.."
        sleep 1; echo "2.."
        sleep 1; echo "1.."
        sleep 1
        sudo reboot
        break
    elif [[ "$KEY" == "2" ]]; then
        echo ""
        echo "Continuing to shell..."
        break
    else
        echo ""
        echo "Invalid choice. Press 1 to Restart or 2 to Continue."
    fi
done
