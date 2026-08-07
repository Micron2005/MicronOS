#!/bin/bash
# Build the Micron OS install image from a stock Ubuntu 24.04 desktop ISO.
#   ./deploy/image/build-image.sh ~/Downloads/ubuntu-24.04.3-desktop-amd64.iso
# Produces: micron-os.iso next to it. Flash with Rufus/dd like any ISO.
set -e
SRC="$1"
[ -f "$SRC" ] || { echo "usage: $0 <ubuntu-24.04-desktop.iso>"; exit 1; }
command -v xorriso >/dev/null || { echo "need xorriso: sudo apt install -y xorriso"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
OUT="$(dirname "$SRC")/micron-os.iso"
echo "== extracting the stock ISO =="
xorriso -osirrox on -indev "$SRC" -extract / "$WORK" >/dev/null 2>&1
chmod -R u+w "$WORK"
echo "== seeding Micron OS =="
cp "$HERE/autoinstall.yaml" "$WORK/autoinstall.yaml"
mkdir -p "$WORK/micron"
cp "$HERE/firstboot.sh" "$HERE/micron-firstboot.service" "$WORK/micron/"
# tell the installer to read the seed
sed -i 's|---|autoinstall ---|g' "$WORK/boot/grub/grub.cfg"
echo "== repacking (this takes a minute) =="
xorriso -as mkisofs -r -V "MICRON_OS" \
  --grub2-mbr --interval:local_fs:0s-15s:zero_mbrpt,zero_gpt:"$SRC" \
  -partition_offset 16 \
  --mbr-force-bootable \
  -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b --interval:local_fs:appended_partition_2:all::"$SRC" \
  -appended_part_as_gpt \
  -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
  -c '/boot.catalog' \
  -b '/boot/grub/i386-pc/eltorito.img' \
  -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
  -eltorito-alt-boot \
  -e '--interval:appended_partition_2:::' \
  -no-emul-boot \
  -o "$OUT" "$WORK" >/dev/null 2>&1
rm -rf "$WORK"
echo "== done: $OUT =="
echo "Flash it like any ISO. Boot it, answer two questions (you, and the"
echo "disk), and the machine becomes Micron OS."
