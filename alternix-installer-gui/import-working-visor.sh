#!/usr/bin/env bash
# Import a user-supplied, already-booting Visor EFI binary for the ISO build.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ $# -ne 1 ]]; then
    printf 'Usage: %s /mounted/old-ESP/EFI/visor/visor_x64.efi\n' "$0" >&2
    exit 2
fi
SRC="$1"
[[ -s "$SRC" ]] || { echo "Not a readable EFI file: $SRC" >&2; exit 1; }
command -v python3 >/dev/null || { echo 'python3 is required' >&2; exit 1; }
python3 "$HERE/visor/check-efi.py" "$SRC"
mkdir -p "$HERE/visor"
DST="$HERE/visor/visor_x64.efi"
if [[ "$SRC" != "$DST" ]]; then
    cp -- "$SRC" "$DST"
fi
chmod 0644 "$DST"
printf 'Imported working Visor EFI: %s\n' "$DST"
sha256sum "$DST"
echo 'Next: sudo bash build-iso.sh'
