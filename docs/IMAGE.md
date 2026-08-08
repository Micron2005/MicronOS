# The Micron OS install image (Stage 2)

One USB. Boot it, answer two questions — who you are, and which disk — and
the machine becomes Micron OS: base laid down, Alfred cloned and serviced,
model pulled, session installed, auto-login on. First boot lands in the
shell.

## Build (on any Ubuntu machine)
    sudo apt install -y xorriso
    ./deploy/image/build-image.sh ~/Downloads/ubuntu-24.04.3-desktop-amd64.iso
    # -> ~/Downloads/micron-os.iso ; flash with Rufus like any ISO

## How it works
- autoinstall.yaml is baked into the ISO; the Ubuntu installer reads it and
  automates everything except identity and disk choice (interactive on
  purpose — a person picks the disk; multi-disk machines taught us that).
- late-commands plant micron-firstboot.service into the installed system.
- On first boot, WITH network, it installs Ollama, pulls the model, clones
  the repo, runs the deploy roles (core/sudo/harden/session), and enables
  auto-login. Then it disables itself. Reboot -> the Micron OS session.

## Test procedure (the spare SSD is the test bed)
1. Build the ISO, flash the stick.
2. Boot the stick on the desktop; at disk choice pick ONLY the spare SSD
   (the 1TB with the leftover Windows) — this ERASES it.
3. Photograph any error at any step; the boot menu chooses between the two
   installs afterward.

## What the finished disc does now

- Boot the USB -> the menu says **Install Micron OS**.
- The installer asks two things: who you are, and which disk.
- First boot (with network): the OS assembles itself -- server, session,
  identity, boot splash -- then that helper retires forever.
- Every boot after: **MICRON OS** on a dark screen while it wakes, a
  3-second boot menu bearing its name, straight into the Micron OS session.
- No assistant anywhere unless the owner installs one afterwards.

## Honest limits, this stage
- The INSTALLER still wears Ubuntu's face and name; our skin covers the
  installed system, not yet the installer. Rebranding the installer and
  boot splash is Stage 1/2 polish, tracked in OWNERSHIP.md.
- The image installs FROM GitHub: the repo must be current before an image
  is built, or the image ships the past.
- First boot needs network for Ollama + model (~5GB).
