#!/bin/bash
# Micron OS first boot. Runs once, with network, as root. Everything the
# owner did by hand on the first machine, done by the house itself.
set -e
FIRSTUSER=$(id -nu 1000)
HOMEDIR=$(eval echo "~$FIRSTUSER")
echo "== Micron OS first boot: preparing the house for $FIRSTUSER =="

# Alfred's engine
curl -fsSL https://ollama.com/install.sh | sh
runuser -l "$FIRSTUSER" -c 'ollama pull qwen2.5:7b' || \
  echo "model pull failed; will retry on next boot" 

# the house itself
# two repositories, one household
if [ ! -d "$HOMEDIR/Alfred" ]; then
  runuser -l "$FIRSTUSER" -c 'git clone https://github.com/Micron2005/Alfred.git Alfred'
fi
if [ ! -d "$HOMEDIR/micron-os" ]; then
  runuser -l "$FIRSTUSER" -c 'git clone https://github.com/Micron2005/MicronOS.git micron-os'
fi
runuser -l "$FIRSTUSER" -c 'pip install -r Alfred/requirements.txt --break-system-packages'
runuser -l "$FIRSTUSER" -c 'cd micron-os && ./deploy/install-micronos.sh core'
runuser -l "$FIRSTUSER" -c 'cd micron-os && ./deploy/install-micronos.sh sudo'
runuser -l "$FIRSTUSER" -c 'cd micron-os && ./deploy/install-micronos.sh harden'
runuser -l "$FIRSTUSER" -c 'cd micron-os && ./deploy/install-micronos.sh session'

# auto-login: power on = Micron OS, no prompt
sed -i "s/^#\?\s*AutomaticLoginEnable.*/AutomaticLoginEnable=true/" /etc/gdm3/custom.conf || true
sed -i "s/^#\?\s*AutomaticLogin\s*=.*/AutomaticLogin=$FIRSTUSER/" /etc/gdm3/custom.conf || true

touch /var/lib/micron-firstboot.done
systemctl disable micron-firstboot.service
echo "== Micron OS is ready. Reboot lands in the shell. =="
