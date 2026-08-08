#!/bin/bash
# Micron OS first boot. Runs once, with network, as root. Everything the
# owner did by hand on the first machine, done by the house itself.
set -e
FIRSTUSER=$(id -nu 1000)
HOMEDIR=$(eval echo "~$FIRSTUSER")
echo "== Micron OS first boot: preparing the house for $FIRSTUSER =="

# the house itself
# The image installs MICRON OS -- the operating system, and only it.
# An assistant is the owner's own act afterwards, never bundled.
if [ ! -d "$HOMEDIR/micron-os" ]; then
  runuser -l "$FIRSTUSER" -c 'git clone https://github.com/Micron2005/MicronOS.git micron-os'
fi
runuser -l "$FIRSTUSER" -c 'cd micron-os && ./deploy/install-micronos.sh core'
runuser -l "$FIRSTUSER" -c 'cd micron-os && ./deploy/install-micronos.sh sudo'
runuser -l "$FIRSTUSER" -c 'cd micron-os && ./deploy/install-micronos.sh harden'
runuser -l "$FIRSTUSER" -c 'cd micron-os && ./deploy/install-micronos.sh session'
# identity + splash need root (os-release, grub, initramfs): run as root,
# from the user's clone. 'sudo' inside the roles is a no-op for root.
bash "$HOMEDIR/micron-os/deploy/install-micronos.sh" identity || true
bash "$HOMEDIR/micron-os/deploy/install-micronos.sh" splash || true
echo "Micron OS installed. To add an assistant later (Alfred is the reference):"
echo "  git clone https://github.com/Micron2005/Alfred.git ~/Alfred && ~/Alfred/install.sh"

# auto-login: power on = Micron OS, no prompt
sed -i "s/^#\?\s*AutomaticLoginEnable.*/AutomaticLoginEnable=true/" /etc/gdm3/custom.conf || true
sed -i "s/^#\?\s*AutomaticLogin\s*=.*/AutomaticLogin=$FIRSTUSER/" /etc/gdm3/custom.conf || true

touch /var/lib/micron-firstboot.done
systemctl disable micron-firstboot.service
echo "== Micron OS is ready. Reboot lands in the shell. =="
