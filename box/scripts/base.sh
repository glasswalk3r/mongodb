#!/usr/bin/env bash
# Base OS packages and settings.
set -euxo pipefail

# No weak dependencies: a new kernel would otherwise pull linux-firmware back in.
dnf -y --setopt=install_weak_deps=False update
dnf upgrade -y
dnf install -y which # required by Virtualbox Guest Additions commands

# Guest Additions build toolchain, removed again in cleanup.sh. kernel-devel
# matches the newest kernel, which is booted after the reboot below.
dnf -y --setopt=install_weak_deps=False install \
  gcc make kernel-devel kernel-headers elfutils-libelf-devel bzip2 tar

# Faster SSH logins (no reverse DNS lookups).
mkdir -p /etc/ssh/sshd_config.d
echo 'UseDNS no' > /etc/ssh/sshd_config.d/99-packer.conf

shutdown -r now
