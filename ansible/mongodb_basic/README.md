# mongodb_basic

This Ansible role implements the most basic configurations in a host to run MongoDB.

The settings are generic and don't depend on the topology (replica set or
sharded cluster). It doesn't write `mongod.conf` or start `mongod`: a role that
depends on it does that, such as `mongodb_replica_set`.

## Implementation details

Requires `become: true`. Uses `ansible.builtin` modules plus
`ansible.posix.firewalld` and `ansible.posix.mount` (install the collection with
`ansible-galaxy collection install -r mongodb_basic/meta/requirements.yml`; it
ships with the full `ansible` package but not with `ansible-core`).

Use it through a role that lists it in `meta/main.yml` dependencies:

```yaml
- hosts: mongodb
  become: true
  roles:
    - mongodb_replica_set   # runs mongodb_basic first
```

### Tasks, in order

1. **Preflight**:
   - Rejects hosts that aren't RHEL-compatible x86_64.
   - Rejects kernels 6.19 through 7.0.13, where MongoDB's TCMalloc
     incompatibility makes `mongod` refuse to start. Rocky 10's 6.12 kernel is fine.
   - With the SELinux policy enabled, rejects a non-default `dbPath`, log path
     or port.
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
4. **Data disk** (only when `data_device` is set, e.g. `/dev/sdb`):
   - Fails if `data_device` isn't a block device.
   - Formats it with `data_fstype` (XFS) and the label `data_label`, but only if
     no file system with that label exists and the device is blank (`blkid -p`
     finds no signature). A disk with other data makes the role fail instead.
   - Fails if `dbPath` isn't a mount point yet but already holds files, which
     the mount would hide.
   - Mounts it at `dbPath` by label (so a device rename doesn't matter), with
     `noatime` when `noatime` is true, and adds it to `/etc/fstab`.
   - Sets the mount point to `mongod:mongod` `0755` and restores its SELinux
     label (`mongod_var_lib_t`); files `mongod` creates inherit it.
   - Runs after the install and the SELinux policy, because it needs the
     `mongod` user and the `dbPath` file context.
5. **Transparent Huge Pages**:
   - The `mongod-thp.service` unit sets `enabled=always`,
     `defrag=defer+madvise` and `khugepaged/max_ptes_none=0`.
   - It runs after `tuned.service` and before `mongod.service`.
   - If `tuned` is installed, a `mongodb` tuned profile is layered on the
     recommended base profile (normally `virtual-guest`).
6. **System tuning**:
   - `/etc/sysctl.d/90-mongod.conf`, see the variables below. Also sets
     `vm.force_cgroup_v2_swappiness=1`, which is skipped if the kernel doesn't
     have it.
   - udev rule: readahead 16 KiB (32 sectors) and the `none` I/O scheduler.
   - `noatime` added to the `data_mount` entry in `/etc/fstab` (`/`, or `dbPath`
     with a data disk, whose entry already has it), then a remount.
7. **Firewall** (only with `enable_firewall`): overrides firewalld's bundled
   `mongodb` service with `/etc/firewalld/services/mongodb.xml`, written from a
   template so its port is `mongod_port` (a file in `/etc` takes precedence
   over the one of the same name in `/usr/lib/firewalld/services/`), reloads
   firewalld when the file changes (the running daemon has to read the new
   definition before the service can be enabled), then enables the `mongodb`
   service in the `firewall_zone` zone with `ansible.posix.firewalld`,
   permanently and in the running configuration. Package updates
   don't touch `/etc`, so the override survives firewalld upgrades.
8. **Service**:
   - systemd override:
     - limits: `LimitNOFILE`/`LimitNPROC` 64000, plus the other limits MongoDB
       recommends;
     - `GLIBC_TUNABLES=glibc.pthread.rseq=0`, so TCMalloc can use per-CPU caches
       with EL10's glibc;
     - ordering after `mongod-thp` and `chronyd`;
     - with a data disk, `RequiresMountsFor=` `dbPath`, so `mongod` never starts
       on the empty directory of the root file system.
   - Reloads systemd when the override changes. The `Restart mongod` handler
     uses `systemctl try-restart`, so it only restarts a `mongod` that is
     already running and never starts one with the RPM's default config. It
     ignores "unit not found" (rc 5), so a playbook's `pre_tasks` can notify it
     before MongoDB is installed.

### Variables (`defaults/main.yml`)

| Variable | Default |
|---|---|
| `version` / `packages` | `"8.0"` / `[mongodb-org]` |
| `mongod_port` | `27017` |
| `db_path` / `log_path` | `/var/lib/mongo` / `/var/log/mongodb/mongod.log` |
| `selinux_policy` | `true` |
| `selinux_version` | `18181652362a46fd4511a56f20c4055712deb252` |
| `thp_enabled` / `thp_defrag` | `always` / `defer+madvise` for 8.0+, `never` below 8.0 |
| `tuned_base_profile` | `""` (use `tuned-adm recommend`) |
| `glibc_rseq_disable` | `true` |
| `sysctl` | `vm.swappiness: 1`, `vm.overcommit_memory: 1`, `vm.zone_reclaim_mode: 0`, `net.ipv4.tcp_keepalive_time: 120` |
| `readahead_kb` / `io_scheduler` | `16` / `none` |
| `data_device` | `""` (no dedicated disk; `dbPath` stays on `/`) |
| `data_label` / `data_fstype` | `mongodata` / `xfs` |
| `noatime` / `data_mount` | `true` / `dbPath` with `data_device`, else `/` |
| `limit_nofile` / `limit_nproc` | `64000` / `64000` |
| `enable_firewall` / `firewall_zone` | `false` / `public` |

`mongod_port`, `db_path` and `log_path` are shared with the roles that write
`mongod.conf`.

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
  RHEL 7/8/9. Check `ps -C mongod -o label=` shows `mongod_t` on Rocky 10.

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
- **THP and TCMalloc:** not checked by the role. By hand: the sysfs files under
  `/sys/kernel/mm/transparent_hugepage`, and `db.serverStatus({tcmalloc: 1})`
  for `tcmalloc.usingPerCPUCaches` true and `tcmalloc.tcmalloc.cpu_free` > 0.

## Recommended further tuning (not applied by default)

For a small dataset in a local environment:

1. Cap the WiredTiger cache (`cache_size_gb` in `mongodb_replica_set`), e.g. `0.5`–`1`.
2. Run a replica set, even a single-node one (`replica_set_name`,
   `oplog_size_mb: 990` in `mongodb_replica_set`), to get transactions and
   change streams.
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
