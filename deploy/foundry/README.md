# The Foundry: Micron OS from raw parts

No Ubuntu. Assembled from Debian's unbranded parts bin: kernel, firmware,
network, one compositor, one browser engine -- and the house on top. The
system's identity is natively `ID=micron`. The disc boots INTO Micron OS
and carries our own installer (`sudo micron-install`).

Build (network + ~10GB + 30-60 min):
    cd ~/micron-os && sudo ./deploy/foundry/foundry.sh
    -> ~/micron-foundry/micron-os-foundry.iso

Flash with dd like any disc. This is Stage 3/4 of OWNERSHIP.md pulled
forward: the Ubuntu remaster (deploy/image/) remains as the works-today
fallback; the Foundry is the true road.

Honest status: first firing WILL hit bumps (drivers, package names shift
between Debian releases) -- that is what the spare SSD and the verbose boot
menu entry are for. Photos of anything strange; we tune the recipe.

## Secure Boot (first-firing lesson, Aug 2026)

Firmware with Secure Boot ON only launches Microsoft-signed bootloaders.
Ubuntu's discs carry that signature; a self-forged OS does not — the result
is `prohibited by secure boot policy` + grub rescue. Fix on your own
machine: disable Secure Boot in firmware. For distributing to others:
either document that step (many independent distros do) or adopt the
shim/MOK signing chain — tracked as a Stage 2 polish item.
