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
| `mongod/` | Ansible role for MongoDB |

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

## Ansible role `mongod`

Requires `become: true`. Uses `ansible.builtin` modules plus
`ansible.posix.firewalld` (install the collection with
`ansible-galaxy collection install -r mongod/meta/requirements.yml`; it ships
with the full `ansible` package but not with `ansible-core`).

```yaml
- hosts: mongodb
  become: true
  roles:
    - mongod
```

### Tasks, in order

1. **Preflight**:
   - Rejects hosts that aren't RHEL-compatible x86_64.
   - Rejects kernels 6.19 through 7.0.13, where MongoDB's TCMalloc
     incompatibility makes `mongod` refuse to start. Rocky 10's 6.12 kernel is fine.
   - With the SELinux policy enabled, rejects a non-default `dbPath`, log path
     or port.
   - Rejects an unknown `mongod_cluster_role`, or a cluster role without a
     replica set name.
2. **Install**:
   - Adds the official repo
     (`https://repo.mongodb.org/yum/redhat/<major>/mongodb-org/8.0/x86_64/`,
     key `https://pgp.mongodb.com/server-8.0.asc`).
   - Installs `mongodb-org`; installs and enables `chronyd`.
3. **SELinux**:
   - Installs the build dependencies, then builds and installs
     `mongodb/mongodb-selinux`, pinned to commit `1818165`.
   - Upstream installs the module at priority 200, overriding the older
     `mongodb` module in `selinux-policy-targeted` (priority 100).
   - Rebuilds only when the source changes or the module is missing.
4. **Transparent Huge Pages**:
   - The `mongod-thp.service` unit sets `enabled=always`,
     `defrag=defer+madvise` and `khugepaged/max_ptes_none=0`.
   - It runs after `tuned.service` and before `mongod.service`.
   - If `tuned` is installed, a `mongodb` tuned profile is layered on the
     recommended base profile (normally `virtual-guest`).
5. **System tuning**:
   - `/etc/sysctl.d/90-mongod.conf`, see the variables below. Also sets
     `vm.force_cgroup_v2_swappiness=1`, which is skipped if the kernel doesn't
     have it.
   - udev rule: readahead 16 KiB (32 sectors) and the `none` I/O scheduler.
   - `noatime` added to the `/` entry in `/etc/fstab`, then a remount.
6. **Firewall** (only with `mongod_firewall`): overrides firewalld's bundled
   `mongodb` service with `/etc/firewalld/services/mongodb.xml`, written from a
   template so its port is `mongod_port` (a file in `/etc` takes precedence
   over the one of the same name in `/usr/lib/firewalld/services/`), reloads
   firewalld when the file changes (the running daemon has to read the new
   definition before the service can be enabled), then enables the `mongodb`
   service in the `mongod_firewall_zone` zone with `ansible.posix.firewalld`,
   permanently and in the running configuration. It also removes a plain
   `mongod_port/tcp` rule left by earlier versions of the role. Package updates
   don't touch `/etc`, so the override survives firewalld upgrades.
7. **Service**:
   - Writes `/etc/mongod.conf`, including the optional cache size, replication,
     sharding role and FTDC size limit.
   - systemd override:
     - limits: `LimitNOFILE`/`LimitNPROC` 64000, plus the other limits MongoDB
       recommends;
     - `GLIBC_TUNABLES=glibc.pthread.rseq=0`, so TCMalloc can use per-CPU caches
       with EL10's glibc;
     - ordering after `mongod-thp` and `chronyd`.
   - Starts `mongod` and waits for the port.
8. **Replica set** (only on the host with `mongod_replset_initiate`):
   - Runs `rs.initiate()` with `mongod_replset_members`, adding
     `configsvr: true` for a config server. Skipped if the set is already
     initiated.
   - Waits up to 120 s for a primary.
   - Needs every member's `mongod` running, which the linear strategy
     guarantees when all members are in the same play.
9. **Verify**:
   - THP values in sysfs.
   - `mongod` runs in the `mongod_t` SELinux domain.
   - `tcmalloc.usingPerCPUCaches` is true and `tcmalloc.tcmalloc.cpu_free` > 0.

### Variables (`mongod/defaults/main.yml`)

| Variable | Default |
|---|---|
| `mongod_version` | `"8.0"` |
| `mongod_port` / `mongod_bind_ip` | `27017` / `127.0.0.1` |
| `mongod_db_path` / `mongod_log_path` | `/var/lib/mongo` / `/var/log/mongodb/mongod.log` |
| `mongod_selinux_policy` | `true` |
| `mongod_selinux_version` | `18181652362a46fd4511a56f20c4055712deb252` |
| `mongod_thp_enabled` / `mongod_thp_defrag` | `always` / `defer+madvise` for 8.0+, `never` below 8.0 |
| `mongod_tuned_base_profile` | `""` (use `tuned-adm recommend`) |
| `mongod_glibc_rseq_disable` | `true` |
| `mongod_sysctl` | `vm.swappiness: 1`, `vm.overcommit_memory: 1`, `vm.zone_reclaim_mode: 0`, `net.ipv4.tcp_keepalive_time: 120` |
| `mongod_readahead_kb` / `mongod_io_scheduler` | `16` / `none` |
| `mongod_noatime` / `mongod_data_mount` | `true` / `/` |
| `mongod_limit_nofile` / `mongod_limit_nproc` | `64000` / `64000` |
| `mongod_cache_size_gb` / `mongod_ftdc_dir_size_mb` | `0` / `0` (MongoDB defaults) |
| `mongod_replset_name` / `mongod_oplog_size_mb` | `""` (standalone) / `0` (MongoDB default) |
| `mongod_replset_members` / `mongod_replset_initiate` | `[]` / `false` |
| `mongod_cluster_role` | `""`; `configsvr` or `shardsvr` in a sharded cluster |
| `mongod_firewall` / `mongod_firewall_zone` | `false` / `public` |

### SELinux policy scope

From MongoDB's install docs and the `mongodb-selinux` README:

- **Covers `mongod` only.** That includes shard members and config servers,
  which are the same binary started with `--shardsvr` or `--configsvr`. It does
  not cover `mongos`, `mongosh` or `mongocryptd`; a `mongos` started by systemd
  runs unconfined.
- **Labels:**

  | Path | Type |
  |---|---|
  | `/usr/bin/mongod` | `mongod_exec_t` |
  | `/var/lib/mongo` | `mongod_var_lib_t` |
  | `/var/log/mongodb` | `mongod_log_t` |
  | `/run/mongodb` | `mongod_runtime_t` |
  | `mongod.service` | `mongod_unit_file_t` |

  Ports come from `mongod_port_t`: TCP 27017–27019 and 28017–28019.
- **Defaults only.** Changing the port, `dbPath`, `systemLog.path` or
  `pidFilePath` is unsupported and needs a custom policy. That rules out several
  `mongod` instances on one VM.
- **RHEL 10:** the MongoDB docs say "RHEL7 or later", but the README lists only
  RHEL 7/8/9. The role's domain check tells you whether it works on Rocky 10.

### THP: why enabled

MongoDB 8.0 ships an upgraded TCMalloc and asks for THP **enabled**. The old
advice to disable THP applies to 7.0 and earlier.

## Open checks

Things not verified by a build or run yet:

- **Package list:** `rpm -qa | grep -E
  'firmware|kdump|kexec|hunspell|mdadm|e2fsprogs|irqbalance|numactl|gcc|perl'`
  should list nothing except possibly `perl-libs`.
- **Boot command:** confirm it works with the Rocky 10.2 EFI GRUB menu.
- **SELinux policy:** confirm it builds on Rocky 10 (`selinux-policy-devel`)
  and produces no denials (`ausearch -m avc -ts recent`).
- **TCMalloc check:** the `db.serverStatus({tcmalloc: 1})` call is inferred;
  MongoDB names the fields but not the command.

## Recommended further tuning (not applied by default)

For a small dataset in a local environment:

1. Cap the WiredTiger cache (`mongod_cache_size_gb`), e.g. `0.5`–`1`.
2. Run a replica set, even a single-node one (`mongod_replset_name`,
   `mongod_oplog_size_mb: 990`), to get transactions and change streams.
   `replicas/` and `sharding/` set both.
3. Turn on authentication (`security.authorization: enabled`).
4. Reach it from the host through Vagrant/VirtualBox port forwarding to
   127.0.0.1:27017. Only open firewalld if you bind to another interface.
5. Never put `dbPath` on a VirtualBox shared folder: they don't support
   directory `fsync()`.
6. Log rotation: `systemLog.logRotate: reopen` plus a logrotate rule that sends
   `SIGUSR1`.
7. Pin the version: `dnf versionlock mongodb-org*`.
8. Optional: `zstd` block compression.

Not needed in this VM: NUMA settings (single node), larger ulimits, further
readahead tuning.
