# Rocky Linux MongoDB box

A Packer build that turns the Rocky Linux 10.2 DVD into a minimal VirtualBox
VM and Vagrant box, and an Ansible role (`mongod`) that installs and tunes
MongoDB 8.0 Community on it.

## Layout

| Path | Purpose |
|---|---|
| `rocky.pkr.hcl` | Packer source (`virtualbox-iso`), build steps, Vagrant post-processor |
| `variables.pkr.hcl` | Build variables |
| `http/ks.cfg` | Kickstart file for the unattended installer |
| `scripts/base.sh` | OS update and Guest Additions build toolchain, then reboot |
| `scripts/guest-additions.sh` | Installs VirtualBox Guest Additions |
| `scripts/vagrant.sh` | Vagrant insecure SSH key for the `vagrant` user |
| `scripts/cleanup.sh` | Removes the toolchain, old kernels and caches; zeroes free space |

## Building

```bash
packer init .
packer build .                      # headless
packer build -var headless=false .  # watch the installer
```

Output goes to `output/rockylinux/` (the VM) and
`output/rockylinux-virtualbox.box` (the Vagrant box).

## Packer build

### Installation media

- ISO: `~/Downloads/Rocky-10.2-x86_64-dvd1.iso` (`iso_path`).
- Checksum: `file:~/Downloads/CHECKSUM` (`iso_checksum_file`). Packer finds the
  SHA256 line whose name matches the ISO file name.
- Packages come from the DVD itself (`cdrom` in the kickstart). Network is used
  only for `dnf update` and the Vagrant key.

### VM

| Setting | Value |
|---|---|
| Guest OS type | `RedHat_64` |
| Firmware | EFI |
| CPUs / memory | 2 / 4096 MB (`cpus`, `memory`) |
| Disk | 40960 MB, SATA (`disk_size`) |
| Graphics | `vmsvga`, 16 MB (driven by the in-kernel `vmwgfx` driver) |
| NAT | `--nat-localhostreachable1 on`; RTC set to UTC |

The boot command selects "Install Rocky Linux" in the EFI GRUB menu, which skips
the media test, adds `inst.text inst.ks=http://<packer>/ks.cfg` to the kernel
line, and boots with F10.

### Kickstart (`http/ks.cfg`)

| Area | Definition |
|---|---|
| Language / timezone | `en_US.UTF-8`, UTC |
| Keyboard | Brazilian ABNT2: `--vckeymap=br-abnt2 --xlayouts='br(abnt2)'` |
| Network | DHCP, hostname `rocky-box` |
| Firewall | enabled, SSH allowed |
| SELinux | enforcing |
| Users | root locked; `vagrant` / `vagrant` in clear text (Vagrant convention), in `wheel`, passwordless sudo |
| Disk | `autopart --type=plain --fstype=xfs --nohome`: XFS `/` and `/boot`, FAT `/boot/efi` (required by EFI), swap. No LVM. |
| Packages | `@^minimal-environment` (only the `core` group) plus `openssh-server`, `sudo`, `curl`, `tar`, `bzip2` |
| kdump | Disabled with `%addon com_redhat_kdump --disable`. Otherwise the installer adds `kdump-utils` and reserves crash kernel memory. |

`ssh_password` in `variables.pkr.hcl` must match the kickstart password.

### Excluded packages

Not needed in a VirtualBox guest:

| Category | Excluded |
|---|---|
| Firmware and microcode | `linux-firmware*`, `*-firmware`, `microcode_ctl` |
| Kernel crash dumps | `kdump-utils`, `kexec-tools`, `makedumpfile` |
| dracut add-ons | `dracut-config-rescue`, `dracut-network`, `dracut-squash` |
| Dictionaries | `hunspell*` |
| IRQ balancing | `irqbalance` (and with it `numactl-libs`) |
| RAID | `mdadm`, `udisks2` (the only package that pulls in `mdadm`) |
| Non-XFS file systems | `e2fsprogs`, `exfatprogs`, `mtools`, `grub2-tools-extra` (the only package that needs `mtools`) |
| Other | `perl` (full distribution, 182 packages) and `rsync` are no longer installed by `base.sh` |

Kept on purpose:

- `dracut`: `kernel-core` and `grub2-tools` require it to build the boot image (initramfs).
- `dosfstools`: check-and-repair tool for the FAT `/boot/efi` partition.
- `fuse-libs`: required by `grub2-tools-minimal`.
- `fwupd`: required by `shim-x64`, the first EFI boot stage.
- `tuned` is not installed: it is only in the `base`/`standard` groups,
  which the kickstart doesn't select.

Optional packages still installed, worth keeping:

- `rpm-plugin-selinux`: sets correct SELinux labels on files `dnf` installs.
- `audit`: `ausearch -m avc` reads the `auditd` log.
- `dnf-plugins-core`: needed for `dnf versionlock`.
- `openssh-clients`.

Candidates if you want to trim further: `sssd-kcm` and its ~20 dependencies,
`rsyslog` (run `mkdir -p /var/log/journal` first so the journal keeps logs across
reboots), `cronie`, `man-db`, `langpacks-en` (fonts), `NetworkManager-tui`,
`bluez`, `tpm2-tools`, `lshw`, `lsscsi`, `sg3_utils`, `parted`, `kernel-tools`,
`kernel-modules-extra`, `yum`, `python3-jsonschema`, `python3-pyyaml`.

### Provisioning flow

1. **`base.sh`**: `dnf update` and installs `gcc make kernel-devel kernel-headers
   elfutils-libelf-devel bzip2 tar`, both with `install_weak_deps=False` so a new
   kernel doesn't pull firmware back in. Sets `UseDNS no` for sshd, then reboots
   into the updated kernel.
2. **`guest-additions.sh`**: builds and installs Guest Additions for the running
   kernel. Fails the build if the `vboxguest` module is missing.
3. **`vagrant.sh`**: installs the Vagrant insecure public key and runs
   `restorecon` on `~/.ssh`.
4. **`cleanup.sh`**:
   - removes the build toolchain;
   - `dnf remove --oldinstallonly`, `autoremove`, `clean all`;
   - empties `machine-id` and deletes SSH host keys, both recreated on first boot;
   - clears logs and zeroes free space.
5. **Vagrant post-processor**: packages the VM as a box (compression level 9),
   keeping the VM output too.

### Guest Additions lifecycle

Rocky's kernel doesn't include the `vboxguest`/`vboxsf` drivers, so Guest
Additions builds them for one exact kernel version. Since the build toolchain is
removed:

- After a kernel update, the drivers can't be rebuilt. Shared folders (the
  default `/vagrant` synced folder) stop working, and the Guest Additions service
  likely fails at boot.
- **Rebuild the box rather than updating the kernel inside it.**
- For a headless box, Guest Additions mainly provides shared folders. chrony
  handles time sync.
