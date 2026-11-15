# mongodb_basic

This Ansible role implements the most basic configurations in a host to run MongoDB.

Configurations are generic and independent how is your setup (only replica sets or sharding).

## Implementation details

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
