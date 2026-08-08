#!/bin/bash
# Build the Micron OS install image from a stock Ubuntu desktop ISO.
#   ./deploy/image/build-image.sh ~/Downloads/ubuntu-XX.04-desktop-amd64.iso
# Produces micron-os.iso beside it. Method: MODIFY the original ISO --
# xorriso replays its boot machinery verbatim (version-proof) and we swap in
# only our seed files and the branded boot menu.
set -e
SRC="$1"
[ -f "$SRC" ] || { echo "usage: $0 <ubuntu-desktop.iso>"; exit 1; }
command -v xorriso >/dev/null || { echo "need xorriso: sudo apt install -y xorriso"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(dirname "$SRC")/micron-os.iso"
WORK="$(mktemp -d "$(dirname "$SRC")/micron-forge.XXXXXX")"
LOG="$WORK.log"
trap 'rm -rf "$WORK"' EXIT
# room for the output ISO (~ same size as the source)
NEED_GB=8
AVAIL_GB=$(df -BG --output=avail "$(dirname "$SRC")" | tail -1 | tr -dc '0-9')
if [ "${AVAIL_GB:-0}" -lt "$NEED_GB" ]; then
  echo "Not enough space in $(dirname "$SRC"): ${AVAIL_GB}G free, need ${NEED_GB}G"; exit 1
fi
rm -f "$OUT"

echo "== reading the stock boot menu =="
if ! xorriso -osirrox on -indev "$SRC" \
     -extract /boot/grub/grub.cfg "$WORK/grub.cfg" >"$LOG" 2>&1; then
  echo "READ FAILED -- last lines of the log:"; tail -8 "$LOG"; exit 1
fi
chmod u+w "$WORK/grub.cfg"

echo "== branding it: Micron OS =="
sed -i 's|---|autoinstall ---|g' "$WORK/grub.cfg"
sed -i 's|Try or Install Ubuntu|Install Micron OS|g' "$WORK/grub.cfg"
sed -i 's|Ubuntu (safe graphics)|Micron OS (safe graphics)|g' "$WORK/grub.cfg"
sed -i 's|set timeout=30|set timeout=5|' "$WORK/grub.cfg" || true

echo "== forging micron-os.iso (writes ~6GB; several minutes) =="
if ! xorriso -indev "$SRC" -outdev "$OUT" \
     -boot_image any replay \
     -volid MICRON_OS \
     -map "$HERE/autoinstall.yaml" /autoinstall.yaml \
     -map "$HERE/firstboot.sh" /micron/firstboot.sh \
     -map "$HERE/micron-firstboot.service" /micron/micron-firstboot.service \
     -map "$WORK/grub.cfg" /boot/grub/grub.cfg \
     >>"$LOG" 2>&1; then
  echo "FORGE FAILED -- last lines of the log:"; tail -10 "$LOG"; exit 1
fi
echo "== done: $OUT =="
echo "Flash it like any ISO. Boot it, answer two questions (you, and the"
echo "disk), and the machine becomes Micron OS."
