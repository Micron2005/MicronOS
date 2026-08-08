#!/usr/bin/env bash
# QUARANTINE ZONE (see OWNERSHIP.md, "The portability rule"): this file is
# the ONLY place Micron OS may touch the base distro directly (apt, GNOME,
# gdm). Swapping off Ubuntu = rewriting this file and nothing else.
# Micron OS installer — the house goes on the machine; Alfred runs it.
#   ./deploy/install-alfredos.sh core     (desktop: shell server at boot)
#   ./deploy/install-alfredos.sh worker   (any other machine: hands at boot)
#   ./deploy/install-alfredos.sh kiosk    (also: shell opens fullscreen at login)
set -euo pipefail
ROLE="${1:-core}"
ME="$(whoami)"

install_unit () {
  sudo cp "deploy/alfred-$1.service" "/etc/systemd/system/alfred-$1@.service"
  sudo systemctl daemon-reload
  sudo systemctl enable "alfred-$1@${ME}.service"
  # restart, not enable --now: a replaced unit must replace the PROCESS too
  sudo systemctl restart "alfred-$1@${ME}.service"
  echo "alfred-$1 running as ${ME}; logs: journalctl -u alfred-$1@${ME} -f"
}

case "$ROLE" in
  core)
    # Micron OS installs ITSELF, and only itself. An assistant is a program
    # the owner installs separately (Alfred/install.sh is the reference).
    sudo cp "deploy/micronos.service" "/etc/systemd/system/micronos@.service"
    sudo systemctl daemon-reload
    # migrate off the old fused unit if present
    sudo systemctl disable --now "alfred-core@${ME}.service" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/alfred-core@.service"
    sudo systemctl daemon-reload
    sudo systemctl enable "micronos@${ME}.service"
    sudo systemctl restart "micronos@${ME}.service"
    echo "Micron OS running as ${ME}; logs: journalctl -u micronos@${ME} -f"
    echo "Micron OS shell: http://localhost:8710"
    if [ -d "$HOME/Alfred/alfred" ]; then
      echo "Assistant detected at ~/Alfred: hosted in service."
    else
      echo "No assistant installed. Micron OS runs standalone."
      echo "To add Alfred: git clone https://github.com/Micron2005/Alfred.git ~/Alfred && ~/Alfred/install.sh"
    fi ;;
  worker)
    echo "Workers are the assistant's hands and install from HIS repository:"
    echo "  git clone https://github.com/Micron2005/Alfred.git ~/Alfred && ~/Alfred/install.sh worker"
    exit 1 ;;
  kiosk|device)
    # kiosk: this screen opens the shell at login (desktop itself).
    # device: a household terminal — worker service AND kiosk, with the
    #         shell pointed at the core machine. One Alfred, many doors.
    CORE_HOST="${2:-localhost}"
    if [ "$ROLE" = "device" ]; then
      install_unit worker
    fi
    SHELL_URL="http://${CORE_HOST}:8710/?device=$(hostname -s)"
    mkdir -p ~/.config/autostart
    cat > ~/.config/autostart/micronos-shell.desktop << DESKTOP
[Desktop Entry]
Type=Application
Name=Micron OS Shell
Comment=Open the Micron OS shell fullscreen at login
Exec=sh -c 'sleep 4; chromium --app=${SHELL_URL} --start-fullscreen 2>/dev/null || google-chrome --app=${SHELL_URL} --start-fullscreen 2>/dev/null || firefox --kiosk ${SHELL_URL}'
X-GNOME-Autostart-enabled=true
DESKTOP
    echo "This machine is now a Micron OS terminal -> ${SHELL_URL}"
    echo "Undo kiosk with: rm ~/.config/autostart/micronos-shell.desktop" ;;
  splash)
    # THE BOOT SCREEN: powering on shows MICRON OS on a clean dark screen
    # with a pulse, not Ubuntu's text scroll. Script-based Plymouth theme --
    # no binary assets, lives entirely in this role. Reversible; rescue at
    # the end. Worst case if a theme ever misbehaves: boot continues with
    # text only. The splash cannot brick the machine.
    sudo mkdir -p /usr/share/plymouth/themes/micron
    sudo tee /usr/share/plymouth/themes/micron/micron.plymouth > /dev/null << 'PLY'
[Plymouth Theme]
Name=Micron OS
Description=The machine, waking as itself
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/micron
ScriptFile=/usr/share/plymouth/themes/micron/micron.script
PLY
    sudo tee /usr/share/plymouth/themes/micron/micron.script > /dev/null << 'SCRIPT'
// Micron OS boot splash: dark steel, the wordmark, a quiet pulse.
Window.SetBackgroundTopColor(0.05, 0.07, 0.09);
Window.SetBackgroundBottomColor(0.03, 0.04, 0.06);

wordmark.image = Image.Text("M I C R O N   O S", 0.90, 0.93, 0.95, 1, "Sans 26");
wordmark.sprite = Sprite(wordmark.image);
wordmark.sprite.SetX(Window.GetWidth()/2 - wordmark.image.GetWidth()/2);
wordmark.sprite.SetY(Window.GetHeight()/2 - wordmark.image.GetHeight()/2);

sub.image = Image.Text("the machine is waking", 0.45, 0.50, 0.56, 1, "Sans 11");
sub.sprite = Sprite(sub.image);
sub.sprite.SetX(Window.GetWidth()/2 - sub.image.GetWidth()/2);
sub.sprite.SetY(Window.GetHeight()/2 + wordmark.image.GetHeight());

counter = 0;
fun refresh(){
  counter++;
  opacity = 0.55 + 0.45 * Math.Sin(counter / 18);
  wordmark.sprite.SetOpacity(opacity);
}
Plymouth.SetRefreshFunction(refresh);

// password prompts (disk encryption etc.) still work, plainly
fun DisplayQuestionCallback(prompt, entry){
  q.image = Image.Text(prompt, 0.9, 0.93, 0.95);
  q.sprite = Sprite(q.image);
  q.sprite.SetX(Window.GetWidth()/2 - q.image.GetWidth()/2);
  q.sprite.SetY(Window.GetHeight()*0.72);
}
Plymouth.SetDisplayQuestionFunction(DisplayQuestionCallback);
SCRIPT
    sudo update-alternatives --install /usr/share/plymouth/themes/default.plymouth \
      default.plymouth /usr/share/plymouth/themes/micron/micron.plymouth 200
    sudo update-alternatives --set default.plymouth \
      /usr/share/plymouth/themes/micron/micron.plymouth
    echo "Rebuilding the boot image (initramfs) -- takes a minute..."
    sudo update-initramfs -u
    echo ""
    echo "Micron OS boot splash installed. Reboot to see the machine wake as itself."
    echo "Rescue (restore Ubuntu's splash):"
    echo "  sudo update-alternatives --set default.plymouth /usr/share/plymouth/themes/bgrt/bgrt.plymouth && sudo update-initramfs -u"
    ;;

  identity)
    # THE NAME: the machine identifies as Micron OS everywhere an OS states
    # its name — boot menu, About screen, login banner, terminal issue line.
    # Additive and reversible: originals are backed up once; ID=ubuntu stays
    # intact underneath so apt and drivers keep working (the portability
    # rule: the base is plumbing, the identity is ours).
    [ -f /etc/os-release.base.bak ] || sudo cp /etc/os-release /etc/os-release.base.bak
    sudo python3 - << 'PYID'
import re
base = open('/etc/os-release.base.bak').read()
base = re.sub(r'^PRETTY_NAME=.*$', 'PRETTY_NAME="Micron OS 0.1"', base, flags=re.M)
base = re.sub(r'^NAME=.*$', 'NAME="Micron OS"', base, flags=re.M)
base = re.sub(r'^HOME_URL=.*$', 'HOME_URL="https://github.com/Micron2005/MicronOS"', base, flags=re.M)
open('/etc/os-release','w').write(base)
PYID
    echo "Micron OS 0.1 \n \l" | sudo tee /etc/issue > /dev/null
    # boot menu: entries say Micron OS
    [ -f /etc/default/grub.base.bak ] || sudo cp /etc/default/grub /etc/default/grub.base.bak
    if grep -q '^GRUB_DISTRIBUTOR' /etc/default/grub; then
      sudo sed -i 's|^GRUB_DISTRIBUTOR=.*|GRUB_DISTRIBUTOR="Micron OS"|' /etc/default/grub
    else
      echo 'GRUB_DISTRIBUTOR="Micron OS"' | sudo tee -a /etc/default/grub > /dev/null
    fi
    # a PROPER boot menu: visible for 3 seconds, named Micron OS, house colors
    sudo sed -i 's|^GRUB_TIMEOUT_STYLE=.*|GRUB_TIMEOUT_STYLE=menu|' /etc/default/grub
    sudo sed -i 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=3|' /etc/default/grub
    grep -q '^GRUB_COLOR_NORMAL' /etc/default/grub || \
      echo 'GRUB_COLOR_NORMAL="light-gray/black"' | sudo tee -a /etc/default/grub > /dev/null
    grep -q '^GRUB_COLOR_HIGHLIGHT' /etc/default/grub || \
      echo 'GRUB_COLOR_HIGHLIGHT="white/blue"' | sudo tee -a /etc/default/grub > /dev/null
    sudo update-grub
    # login screen: the name above the prompt
    sudo mkdir -p /etc/gdm3
    if [ -f /etc/gdm3/greeter.dconf-defaults ]; then
      sudo sed -i "s|^#\?\s*banner-message-enable=.*|banner-message-enable=true|" /etc/gdm3/greeter.dconf-defaults
      sudo sed -i "s|^#\?\s*banner-message-text=.*|banner-message-text='M I C R O N   O S'|" /etc/gdm3/greeter.dconf-defaults
    fi
    echo ""
    echo "The machine now calls itself Micron OS: boot menu, About, login,"
    echo "terminal. Originals backed up: /etc/os-release.base.bak,"
    echo "/etc/default/grub.base.bak — restore either to undo."
    ;;

  session)
    # STAGE 1 PROPER: Micron OS as its own login session. Not an app over
    # GNOME — the session IS the shell. cage (a Wayland kiosk compositor)
    # draws exactly one program fullscreen: the Micron OS face. There is no
    # desktop behind it; the Super key has nothing to reveal.
    #
    # Safety valve: plain Ubuntu stays installed and selectable via the gear
    # icon at the login screen. This role touches NO bootloader, NO kernel,
    # NO partitions — worst case is picking Ubuntu at login.
    sudo apt install -y cage
    sudo tee /usr/local/bin/micronos-session > /dev/null << 'SESH'
#!/bin/bash
# Micron OS session: wait for the core, then the face takes the machine.
for i in $(seq 1 90); do
  curl -s -o /dev/null http://localhost:8710/ && break
  sleep 1
done
export MOZ_ENABLE_WAYLAND=1
exec cage -d -- firefox --kiosk http://localhost:8710
SESH
    sudo chmod +x /usr/local/bin/micronos-session
    sudo tee /usr/share/wayland-sessions/micronos.desktop > /dev/null << 'DESK'
[Desktop Entry]
Name=Micron OS
Comment=The machine, wearing its own face
Exec=/usr/local/bin/micronos-session
Type=Application
DesktopNames=MicronOS
DESK
    # Make Micron OS this user's default session (what auto-login launches)
    printf '[User]\nSession=micronos\nXSession=micronos\nSystemAccount=false\n' \
      | sudo tee "/var/lib/AccountsService/users/$USER" > /dev/null
    # Retire the interim in-GNOME kiosk autostart, if present
    rm -f "$HOME/.config/autostart/micronos.desktop"
    echo ""
    echo "Micron OS session installed. Enable auto-login (Settings -> Users),"
    echo "reboot, and the machine boots INTO Micron OS — no desktop beneath it."
    echo ""
    echo "Safety valves, write these down:"
    echo "  - Login screen gear icon -> 'Ubuntu' = the old desktop, any time."
    echo "  - If the session ever breaks with auto-login on: Ctrl+Alt+F3,"
    echo "    log in by name, then run:"
    echo "    sudo sed -i 's/AutomaticLoginEnable=true/AutomaticLoginEnable=false/' /etc/gdm3/custom.conf && sudo systemctl restart gdm3"
    ;;

  kiosk)
    # The cover: power on -> auto-login -> Micron OS takes the whole screen.
    # Ubuntu keeps running underneath, invisible. This is the interim Stage 1;
    # the full version (no GNOME at all, Plymouth emblem) comes later.
    # kiosk [host] — no host: this machine runs the core (the desktop).
    # With a host: this machine is a TERMINAL — a face for the one Alfred
    # who lives at that address. Nothing else is installed here.
    CORE_HOST="${2:-localhost}"
    mkdir -p "$HOME/.local/bin" "$HOME/.config/autostart"
    cat > "$HOME/.local/bin/micronos-kiosk.sh" << KIOSK
#!/bin/bash
# Micron OS face: wait for the core at $CORE_HOST, then take the screen.
for i in \$(seq 1 60); do
  curl -s -o /dev/null http://$CORE_HOST:8710/ && break
  sleep 1
done
exec firefox --kiosk http://$CORE_HOST:8710
KIOSK
    chmod +x "$HOME/.local/bin/micronos-kiosk.sh"
    cat > "$HOME/.config/autostart/micronos.desktop" << DESK
[Desktop Entry]
Type=Application
Name=Micron OS
Comment=The face of the machine
Exec=$HOME/.local/bin/micronos-kiosk.sh
X-GNOME-Autostart-enabled=true
DESK
    echo "Kiosk installed: next login opens straight into Micron OS full-screen."
    echo "For the full power-on-to-face experience, also enable auto-login:"
    echo "  Settings -> System -> Users -> Unlock -> Automatic Login ON"
    echo "To step out of the cover at any time: Alt+F4 (or Super) reveals Ubuntu."
    ;;

  sudo)
    # Scoped, passwordless sudo for exactly the two binaries the os.apply
    # catalog uses. Deliberately NOT "NOPASSWD: ALL" — the catalog plus this
    # scope is the whole blast radius of an approved change.
    echo "${ME} ALL=(root) NOPASSWD: /usr/bin/apt-get, /usr/bin/systemctl" \
      | sudo tee /etc/sudoers.d/micronos-scoped >/dev/null
    sudo chmod 440 /etc/sudoers.d/micronos-scoped
    echo "scoped sudo installed for ${ME} (apt-get, systemctl only)"
    echo "remove with: sudo rm /etc/sudoers.d/micronos-scoped" ;;
  harden)
    # The layers that actually carry the weight, per SECURITY.md. None of
    # these can lock the owner out; all are standard Ubuntu hygiene.
    echo "Enabling the firewall (deny incoming, allow outgoing)..."
    sudo apt-get install -y ufw >/dev/null 2>&1 || true
    sudo ufw --force enable
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    # SSH only if you actually use it to reach this machine:
    # sudo ufw allow ssh
    echo "Enabling automatic security updates..."
    sudo apt-get install -y unattended-upgrades >/dev/null 2>&1 || true
    sudo dpkg-reconfigure -f noninteractive unattended-upgrades || true
    echo
    echo "Done. Alfred already binds to localhost by default, so nothing off"
    echo "this machine can reach him unless you pass --host 0.0.0.0 AND open a"
    echo "port above. The firewall + auto-updates are the real perimeter." ;;
  *) echo "usage: $0 core|worker|kiosk [host]|device <host>|session|identity|splash|sudo|harden"; exit 1 ;;
esac
