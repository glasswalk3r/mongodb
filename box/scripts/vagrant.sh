#!/usr/bin/env bash
# Vagrant conventions: insecure public key for the vagrant user.
set -euxo pipefail

HOME_DIR="/home/${SSH_USERNAME}"
mkdir -p "$HOME_DIR/.ssh"
curl -fsSL https://raw.githubusercontent.com/hashicorp/vagrant/main/keys/vagrant.pub \
  -o "$HOME_DIR/.ssh/authorized_keys"
chmod 700 "$HOME_DIR/.ssh"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
chown -R "${SSH_USERNAME}:${SSH_USERNAME}" "$HOME_DIR/.ssh"
restorecon -R "$HOME_DIR/.ssh"
