#!/bin/bash
# ============================================================================
# THE MICRON OS FOUNDRY
# Assembles Micron OS from raw Debian parts. No Ubuntu anywhere -- not the
# installer, not the splash, not one string. Output: micron-os-foundry.iso,
# a live disc that BOOTS INTO MICRON OS and carries our own installer.
#
#   sudo ./deploy/foundry/foundry.sh
#
# Needs: network, ~10GB free, 30-60 minutes. Run from the micron-os repo.
# ============================================================================
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="${FOUNDRY_DIR:-$HOME/micron-foundry}"
ROOT="$BUILD/root"
ISODIR="$BUILD/iso"
OUT="$BUILD/micron-os-foundry.iso"
SUITE="${SUITE:-trixie}"
MIRROR="http://deb.debian.org/debian"
LOG="$BUILD/foundry.log"
mkdir -p "$BUILD"; : > "$LOG"
say(){ echo "== $* =="; }

say "stage 0: the foundry's own tools"
apt-get install -y debootstrap squashfs-tools xorriso mtools dosfstools \
  grub-pc-bin grub-efi-amd64-bin grub-common >>"$LOG" 2>&1

if [ ! -e "$ROOT/etc/os-release" ]; then
  say "stage 1: raw parts from Debian ($SUITE) -- the long download"
  debootstrap --arch=amd64 --components=main,contrib,non-free-firmware \
    "$SUITE" "$ROOT" "$MIRROR" >>"$LOG" 2>&1 || {
      echo "debootstrap failed -- tail of log:"; tail -12 "$LOG"; exit 1; }
else
  say "stage 1: base already forged, reusing"
fi

say "stage 2: the machine's organs (kernel, firmware, network, display)"
cat > "$ROOT/etc/apt/sources.list" << EOF
deb $MIRROR $SUITE main contrib non-free-firmware
deb $MIRROR ${SUITE}-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security ${SUITE}-security main contrib non-free-firmware
EOF
mount --bind /dev  "$ROOT/dev";  mount --bind /proc "$ROOT/proc"
mount --bind /sys  "$ROOT/sys";  mount --bind /run  "$ROOT/run" 2>/dev/null || true
cleanup(){ umount -l "$ROOT/dev" "$ROOT/proc" "$ROOT/sys" "$ROOT/run" 2>/dev/null || true; }
trap cleanup EXIT
chroot "$ROOT" env DEBIAN_FRONTEND=noninteractive bash -c "
  apt-get update &&
  apt-get install -y linux-image-amd64 firmware-linux firmware-amd-graphics \
    live-boot systemd-sysv network-manager sudo locales console-setup \
    python3 python3-pip git curl ca-certificates \
    cage firefox-esr fonts-dejavu \
    grub-efi-amd64 grub-pc-bin parted dosfstools rsync
" >>"$LOG" 2>&1 || { echo "organ install failed -- tail:"; tail -12 "$LOG"; exit 1; }

say "stage 3: the identity -- this machine is MICRON OS, natively"
cat > "$ROOT/usr/lib/os-release" << 'EOF'
PRETTY_NAME="Micron OS 0.1"
NAME="Micron OS"
VERSION_ID="0.1"
VERSION="0.1 (foundry)"
ID=micron
ID_LIKE=debian
HOME_URL="https://github.com/Micron2005/MicronOS"
EOF
ln -sf ../usr/lib/os-release "$ROOT/etc/os-release"
echo "micron-os" > "$ROOT/etc/hostname"
printf 'Micron OS 0.1 \\n \\l\n' > "$ROOT/etc/issue"

say "stage 4: the house moves in (server, shell, apps, session)"
rm -rf "$ROOT/opt/micron-os"
mkdir -p "$ROOT/opt/micron-os"
cp -r "$REPO/shell" "$REPO/apps" "$REPO/configs" "$REPO/docs" \
      "$REPO"/run_server.py "$REPO"/micron_lock.py "$REPO"/micron_files.py \
      "$REPO"/assistant_api.py "$REPO"/*.md "$ROOT/opt/micron-os/" 2>/dev/null
chroot "$ROOT" bash -c "id micron >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,netdev micron"
# live disc auto-login; installed systems get their own user via micron-install
cat > "$ROOT/etc/systemd/system/micronos.service" << 'EOF'
[Unit]
Description=Micron OS (shell, apps, settings)
After=network.target
[Service]
User=micron
WorkingDirectory=/opt/micron-os
ExecStart=/usr/bin/python3 /opt/micron-os/run_server.py --host 127.0.0.1
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
cat > "$ROOT/etc/systemd/system/micron-session.service" << 'EOF'
[Unit]
Description=Micron OS session (the face owns the screen)
After=systemd-user-sessions.service micronos.service
Conflicts=getty@tty1.service
[Service]
User=micron
PAMName=login
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
UtmpIdentifier=tty1
Environment=XDG_RUNTIME_DIR=/run/user/1000
ExecStartPre=/bin/sh -c 'mkdir -p /run/user/1000 && chown micron:micron /run/user/1000'
ExecStartPre=/bin/sh -c 'for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:8710/ && break; sleep 1; done'
ExecStart=/usr/bin/cage -d -- /usr/bin/firefox-esr --kiosk http://127.0.0.1:8710
Restart=always
[Install]
WantedBy=graphical.target
EOF
chroot "$ROOT" systemctl enable micronos.service micron-session.service NetworkManager >>"$LOG" 2>&1
chroot "$ROOT" systemctl set-default graphical.target >>"$LOG" 2>&1
install -m 0755 "$REPO/deploy/foundry/micron-install" "$ROOT/usr/local/sbin/micron-install"

say "stage 5: pressing the disc"
chroot "$ROOT" update-initramfs -u >>"$LOG" 2>&1
cleanup; trap - EXIT
rm -rf "$ISODIR"; mkdir -p "$ISODIR/live" "$ISODIR/boot/grub"
cp "$ROOT"/boot/vmlinuz-* "$ISODIR/live/vmlinuz"
cp "$ROOT"/boot/initrd.img-* "$ISODIR/live/initrd"
mksquashfs "$ROOT" "$ISODIR/live/filesystem.squashfs" -comp zstd -noappend >>"$LOG" 2>&1
cat > "$ISODIR/boot/grub/grub.cfg" << 'EOF'
set timeout=3
menuentry "Micron OS" {
    linux /live/vmlinuz boot=live quiet
    initrd /live/initrd
}
menuentry "Micron OS (verbose, for debugging)" {
    linux /live/vmlinuz boot=live
    initrd /live/initrd
}
EOF
grub-mkrescue -o "$OUT" "$ISODIR" -volid MICRON_OS >>"$LOG" 2>&1 || {
  echo "disc pressing failed -- tail:"; tail -12 "$LOG"; exit 1; }
say "done: $OUT"
echo "Flash it (dd, same as before), boot it: the machine wakes as Micron OS"
echo "with no other name aboard. Install to a disk from within: sudo micron-install"
