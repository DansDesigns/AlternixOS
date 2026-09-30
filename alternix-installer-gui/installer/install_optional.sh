#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# install_optional.sh — optional components chosen in osm-install
#
# The graphical installer writes the selected component ids to
# ALTERNIX_OPTIONAL as a space-separated list. For each one this runs
# installer/optional/<id>.sh inside the target system.
#
# Telephony is not handled here. It is answered through the AlternixDE
# script's own prompt, via ALTERNIX_TELEPHONY in install_desktop.sh.
#
# WRITING A COMPONENT SCRIPT
#   · It runs inside the target as root, after the desktop is installed.
#   · TARGET_USER and HOME are set for the new user.
#   · DEBIAN_FRONTEND is noninteractive.
#   · stdin is /dev/null. It must not prompt: any read gets end of file.
#   · Exit 0 on success. A non-zero exit is reported as an error but
#     does not stop the rest of the install.
#
# A missing script is a warning, not a failure, so a component can be
# listed on the page before its installer is written.
# ═══════════════════════════════════════════════════════════════

install_optional_components() {
    local ids="${ALTERNIX_OPTIONAL:-}"
    [[ -z "${ids// /}" ]] && return 0

    section "Optional Components"

    # Network and device access for the scripts, same as the other
    # chroot stages. /dev/pts is not covered by the /dev bind and has
    # to be mounted separately or apt cannot write its log.
    local fs
    for fs in proc sys dev dev/pts; do
        mkdir -p "${ALTERNIX_MOUNT}/${fs}"
        mountpoint -q "${ALTERNIX_MOUNT}/${fs}" || \
            mount --bind "/${fs}" "${ALTERNIX_MOUNT}/${fs}" 2>/dev/null || true
    done
    cp /etc/resolv.conf "${ALTERNIX_MOUNT}/etc/resolv.conf" 2>/dev/null || true

    local id script staged rc
    for id in $ids; do
        # Ids come from the config file. Refuse anything that could
        # escape the optional/ directory.
        if [[ ! "$id" =~ ^[a-z0-9_-]+$ ]]; then
            warn "Ignoring invalid component id '${id}'."
            continue
        fi

        script="${INSTALLER_DIR}/optional/${id}.sh"
        if [[ ! -f "$script" ]]; then
            warn "No installer for '${id}' (expected optional/${id}.sh) — skipped."
            continue
        fi

        info "Installing optional component: ${id}"
        staged="/tmp/alternix-optional-${id}.sh"
        sed 's/\r$//' "$script" > "${ALTERNIX_MOUNT}${staged}"
        chmod 755 "${ALTERNIX_MOUNT}${staged}"

        chroot "$ALTERNIX_MOUNT" /usr/bin/env \
            DEBIAN_FRONTEND=noninteractive \
            DEBCONF_NONINTERACTIVE_SEEN=true \
            TARGET_USER="${ALTERNIX_USERNAME}" \
            HOME="/home/${ALTERNIX_USERNAME}" \
            TERM=xterm \
            /bin/bash "$staged" \
            < /dev/null 2>&1 | tee -a "$ALTERNIX_LOG"
        rc=${PIPESTATUS[0]}

        rm -f "${ALTERNIX_MOUNT}${staged}"

        if [[ $rc -eq 0 ]]; then
            ok "${id} installed."
        else
            err "${id} failed (exit ${rc}) — see the log above."
        fi
    done

    for fs in dev/pts dev sys proc; do
        umount "${ALTERNIX_MOUNT}/${fs}" 2>/dev/null || true
    done
}
