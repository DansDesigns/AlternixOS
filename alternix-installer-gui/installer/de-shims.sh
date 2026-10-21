#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# de-shims.sh — temporary wrappers for running the AlternixDE script
#
#   de-shims.sh add    <root>    install the wrappers into <root>
#   de-shims.sh remove <root>    take them out again
#
# <root> is the target mount during an install, or / when called from
# inside the ISO build chroot. install-alternix_devuan.sh itself is never
# modified; these sit in front of two commands it runs and are removed
# as soon as it finishes.
#
# WHY EACH ONE EXISTS — DO NOT REMOVE WITHOUT READING
#
# 1. sudo  (in SHIM_DIR, which the caller must put first in PATH)
#    The script runs `sudo ./auto-cpufreq-installer` with no arguments,
#    so the installer prompts "[I]nstall/[R]emove" on stdin. Under the
#    graphical installer stdin is a pre-made answer stream, and any
#    earlier command that reads stdin takes the answer meant for this
#    prompt. The installer then gets "2", prints "Unknown key,
#    aborting" and exits 1, and `set -e` ends the whole desktop build.
#    The installer accepts --install, which skips the prompt entirely,
#    so this wrapper adds it. If the script is later changed to pass
#    --install itself, the call no longer matches and goes straight
#    through unchanged.
#
# 2. sudo auto-cpufreq --install (in SHIM_DIR)
#    auto-cpufreq itself checks /sys CPU frequency governors before
#    registering its daemon. In an ISO/target chroot those governors are
#    not necessarily exposed, so the command exits 1 even AFTER the
#    application successfully installs. Instead copy the upstream OpenRC
#    service file and enable it via rc-update (which works in a chroot).
#    The actual daemon starts only after boot on real hardware. This
#    preserves auto-cpufreq in the prebuilt OS without a false failure.
#
# 3. rc-service  (in /usr/local/sbin, first on sudo's secure_path)
#    Some dependency installers attempt to start OpenRC services during
#    the chroot build. Block only start/restart, not service enablement.
# ═══════════════════════════════════════════════════════════════

set -u

SHIM_DIR_REL="usr/local/lib/alternix-de-shims"
RCSVC_REL="usr/local/sbin/rc-service"
MARKER="# ALTERNIX-DE-BUILD-SHIM"

_add() {
    local root="${1%/}"
    mkdir -p "${root}/${SHIM_DIR_REL}" "${root}/usr/local/sbin" || return 1

    if [[ -x "${root}/usr/bin/sudo" ]]; then
        cat > "${root}/${SHIM_DIR_REL}/sudo" <<EOF
#!/bin/sh
${MARKER} — see installer/de-shims.sh. Removed after the build.
if [ "\$#" -eq 1 ] && [ "\$1" = "./auto-cpufreq-installer" ]; then
    exec /usr/bin/sudo ./auto-cpufreq-installer --install
fi
# The application is installed, but checking CPU governors and starting
# a daemon inside live-build's chroot cannot work reliably.
if [ "\$#" -eq 2 ] && [ "\$1" = "auto-cpufreq" ] && [ "\$2" = "--install" ]; then
    if [ ! -x /usr/local/bin/auto-cpufreq ]; then
        echo "auto-cpufreq: executable missing after installation" >&2
        exit 1
    fi
    src=/usr/local/share/auto-cpufreq/scripts/auto-cpufreq-openrc
    if [ ! -f "\$src" ] && [ -f ./scripts/auto-cpufreq-openrc ]; then
        src=./scripts/auto-cpufreq-openrc
    fi
    if [ ! -f "\$src" ]; then
        echo "auto-cpufreq: upstream OpenRC service definition missing" >&2
        exit 1
    fi
    echo "auto-cpufreq: installing OpenRC service (CPU checks deferred to real boot)"
    /usr/bin/sudo install -m 0755 "\$src" /etc/init.d/auto-cpufreq || exit \$?
    /usr/bin/sudo rc-update add auto-cpufreq default || exit \$?
    exit 0
fi
exec /usr/bin/sudo "\$@"
EOF
        chmod 755 "${root}/${SHIM_DIR_REL}/sudo"
    fi

    # Never overwrite a real file that happens to be at this path.
    if [[ -e "${root}/${RCSVC_REL}" ]] && ! grep -q "$MARKER" "${root}/${RCSVC_REL}" 2>/dev/null; then
        echo "de-shims: ${RCSVC_REL} already exists and is not ours; leaving it alone" >&2
    else
        cat > "${root}/${RCSVC_REL}" <<EOF
#!/bin/sh
${MARKER} — see installer/de-shims.sh. Removed after the build.
for a in "\$@"; do
    case "\$a" in
        start|restart)
            echo "rc-service \$*: skipped during installation (no running OpenRC); runs from the next boot"
            exit 0 ;;
    esac
done
for r in /usr/sbin/rc-service /sbin/rc-service; do
    [ -x "\$r" ] && exec "\$r" "\$@"
done
exit 0
EOF
        chmod 755 "${root}/${RCSVC_REL}"
    fi
}

_remove() {
    local root="${1%/}"
    # root is empty when called with "/", so no ${root:?} here; the
    # directory name is a fixed constant, so the path is always safe.
    rm -rf "${root}/${SHIM_DIR_REL}"
    if [[ -f "${root}/${RCSVC_REL}" ]] && grep -q "$MARKER" "${root}/${RCSVC_REL}" 2>/dev/null; then
        rm -f "${root}/${RCSVC_REL}"
    fi
}

case "${1:-}" in
    add)    _add    "${2:?usage: de-shims.sh add <root>}" ;;
    remove) _remove "${2:?usage: de-shims.sh remove <root>}" ;;
    *)      echo "usage: de-shims.sh add|remove <root>" >&2; exit 2 ;;
esac
