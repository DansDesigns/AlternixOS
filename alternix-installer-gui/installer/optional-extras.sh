#!/bin/bash
# AlternixOS optional Flatpak group, selected on osm-install's
# existing Optional components page. Runs inside the installed system's
# target chroot as root, after the desktop and Flatpak are configured.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This optional installer must run as root inside the target." >&2
    exit 1
fi
if ! command -v flatpak >/dev/null 2>&1; then
    # Non-Alternix desktops do not necessarily have Flatpak preinstalled.
    # Install the distribution package before adding the user's choices.
    echo "[Optional Flatpak] Installing the Flatpak package..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y flatpak
fi

# The selected group is an online installation, not part of ISO prebuild.
flatpak remote-add --system --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo

failed=0
for app in \
    page.codeberg.lo_vely.Nucleus \
    space.gaiasky.GaiaSky \
    io.github.leolost2605.emergency-alerts \
    no.bragefuglseth.Keypunch \
    de.haeckerfelix.Shortwave; do
    echo "[Optional Flatpak] Installing $app ..."
    if ! flatpak install --system --noninteractive -y flathub "$app"; then
        echo "ERROR: Could not install $app" >&2
        failed=1
    fi
done

if [ "$failed" -ne 0 ]; then
    echo "ERROR: One or more optional Flatpaks could not be installed." >&2
    exit 1
fi
echo "[Optional Flatpak] All selected applications installed."
