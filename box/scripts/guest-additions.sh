#!/usr/bin/env bash
# Install VirtualBox Guest Additions from the ISO uploaded by Packer.
set -euxo pipefail

ISO="/home/${SSH_USERNAME}/VBoxGuestAdditions.iso"
MNT=/mnt/vbox

mkdir -p "$MNT"
mount -o loop,ro "$ISO" "$MNT"
# The installer exits non-zero when no X server is present; that is expected.
sh "$MNT/VBoxLinuxAdditions.run" --nox11 || true
umount "$MNT"
rm -rf "$MNT" "$ISO"

# Fail the build if the kernel module did not get built.
modinfo vboxguest >/dev/null
