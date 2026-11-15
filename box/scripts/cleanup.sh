#!/usr/bin/env bash
# Shrink the image before export.
set -euxo pipefail

# Remove the Guest Additions build toolchain (and, through autoremove, its
# dependencies). The vbox kernel modules stay built for the running kernel only:
# after a kernel update they can't be rebuilt, so rebuild the box instead.
dnf -y remove gcc make kernel-devel kernel-headers elfutils-libelf-devel

# Keep only the running kernel.
dnf -y remove --oldinstallonly || true
dnf -y autoremove
dnf -y clean all
rm -rf /var/cache/dnf/* /tmp/* /var/tmp/*

# Regenerate machine-id and SSH host keys on first boot so clones are unique.
truncate -s 0 /etc/machine-id
rm -f /etc/ssh/ssh_host_*

rm -f /root/anaconda-ks.cfg /root/original-ks.cfg
journalctl --rotate && journalctl --vacuum-time=1s || true

# Zero free space so the disk compresses well.
dd if=/dev/zero of=/EMPTY bs=1M status=none || true
rm -f /EMPTY
sync
