#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# onboard-defaults.sh — default size, position and theme for onboard
#
#   onboard-defaults.sh <root> <height-percent> <theme-name> <screen-w> <screen-h>
#
# Writes a GSettings vendor override into the target and compiles it,
# so every user on the installed system starts with these values. A
# user's own changes in onboard's preferences still take priority, as
# with any GSettings default. Nothing needs a running session or D-Bus,
# so this works inside the install chroot.
#
# WHY ONBOARD STARTED "MASSIVE" — READ BEFORE CHANGING docking-enabled
# Undocked, onboard declares itself an ordinary window (window type
# NORMAL) under every window manager except Compiz. Qtile only floats
# utility, dialog, toolbar, splash and notification windows by default,
# so it tiled onboard and stretched it to fill a whole tile. Its own
# size settings were never used.
# Docked, onboard declares itself a DOCK window instead. Qtile does not
# tile dock windows: it leaves them where they ask to be and keeps other
# windows out of the space they reserve (backend/x11/core.py, "dock").
# So the keyboard is pinned to the bottom edge, full width, at the
# dock-height below. This is the same as ticking "Dock to screen edge"
# in onboard's preferences, which was the manual fix after install.
#
# Heights are worked out for both orientations, because tablets rotate
# and onboard keeps separate landscape and portrait sizes.
# ═══════════════════════════════════════════════════════════════

set -u

OVERRIDE_REL="usr/share/glib-2.0/schemas/90_alternix-onboard.gschema.override"
SCHEMA_REL="usr/share/glib-2.0/schemas/org.onboard.gschema.xml"
THEMES_REL="usr/share/onboard/themes"

_say()  { echo "  · onboard: $*"; }
_warn() { echo "  ! onboard: $*" >&2; }

# Prints the override file for the given values. Kept separate from the
# install steps so it can be checked against onboard's real schema.
write_override() {   # pct theme_path long short
    local pct="$1" theme="$2" long="$3" short="$4"
    # Landscape height is a share of the short side, portrait of the long.
    local lkh=$(( short * pct / 100 ))
    local pkh=$(( long  * pct / 100 ))

    cat <<EOF
# Written by the Alternix installer (installer/onboard-defaults.sh).
# Defaults only: changes made in onboard's own preferences override them.

[org.onboard]
theme='${theme}'
system-theme-tracking-enabled=false

[org.onboard.window]
docking-enabled=true
docking-edge='bottom'

[org.onboard.window.landscape]
dock-expand=true
dock-height=${lkh}

[org.onboard.window.portrait]
dock-expand=true
dock-height=${pkh}
EOF
}

# Native mode of the first connected screen, built-in panels first
# (eDP, LVDS, DSI), as "WxH". Empty if DRM has nothing to report.
panel_mode() {
    local c m
    for c in /sys/class/drm/card*-eDP-* /sys/class/drm/card*-LVDS-* \
             /sys/class/drm/card*-DSI-* /sys/class/drm/card*-*; do
        [[ -r "$c/status" && "$(cat "$c/status" 2>/dev/null)" == "connected" ]] || continue
        m=$(head -n1 "$c/modes" 2>/dev/null)
        m="${m%%[!0-9x]*}"
        [[ -n "$m" ]] && { echo "$m"; return 0; }
    done
    return 1
}

main() {
    local root="${1%/}" pct="${2:-}" theme_name="${3:-}" sw="${4:-}" sh="${5:-}"

    if [[ ! -f "${root}/${SCHEMA_REL}" ]]; then
        _warn "onboard is not installed in the target; skipping keyboard defaults."
        return 0
    fi

    [[ "$pct" =~ ^[0-9]+$ ]] && (( pct >= 10 && pct <= 60 )) || {
        _warn "invalid keyboard height '${pct}', using 30%"; pct=30; }

    # Screen size comes from the graphical installer. Without it (the
    # text installer) read the built-in panel's native mode from DRM,
    # and failing that assume a common tablet panel.
    if ! [[ "$sw" =~ ^[0-9]+$ && "$sh" =~ ^[0-9]+$ ]]; then
        local mode
        mode=$(panel_mode)
        if [[ "$mode" =~ ^([0-9]+)x([0-9]+)$ ]]; then
            sw="${BASH_REMATCH[1]}"; sh="${BASH_REMATCH[2]}"
        fi
    fi
    if ! [[ "$sw" =~ ^[0-9]+$ && "$sh" =~ ^[0-9]+$ ]] || (( sw < 320 || sh < 320 )); then
        _warn "screen size unknown, assuming 1280x800"
        sw=1280; sh=800
    fi
    local long=$(( sw > sh ? sw : sh )) short=$(( sw > sh ? sh : sw ))

    # Use the chosen theme if it exists in the target, else onboard's
    # own default, rather than pointing at a file that is not there.
    local theme_path=""
    if [[ -n "$theme_name" && -f "${root}/${THEMES_REL}/${theme_name}.theme" ]]; then
        theme_path="/${THEMES_REL}/${theme_name}.theme"
    else
        _warn "theme '${theme_name}' not found in the target; keeping onboard's default theme."
    fi

    write_override "$pct" "$theme_path" "$long" "$short" > "${root}/${OVERRIDE_REL}" || {
        _warn "could not write ${OVERRIDE_REL}"; return 1; }

    # Compile inside the target, with the target's own compiler.
    local gcs=""
    if [[ -x "${root}/usr/bin/glib-compile-schemas" ]]; then
        gcs="/usr/bin/glib-compile-schemas"
    else
        gcs=$(cd "$root" && ls usr/lib/*/glib-2.0/glib-compile-schemas 2>/dev/null | head -1)
        [[ -n "$gcs" ]] && gcs="/${gcs}"
    fi
    if [[ -z "$gcs" ]]; then
        _warn "glib-compile-schemas not found in the target; defaults written but not compiled."
        return 1
    fi
    if ! chroot "$root" "$gcs" /usr/share/glib-2.0/schemas; then
        _warn "glib-compile-schemas failed; onboard will use its built-in defaults."
        rm -f "${root}/${OVERRIDE_REL}"
        chroot "$root" "$gcs" /usr/share/glib-2.0/schemas >/dev/null 2>&1
        return 1
    fi

    local used="onboard default"
    [[ -n "$theme_path" ]] && used="$theme_name"
    _say "${pct}% height, theme ${used}, sized for ${long}x${short} (and portrait)."
    return 0
}

# Run only when executed, so write_override can be tested on its own.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
