# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Infrastructure only, no application code:

- `box/`: a Packer build that turns the Rocky Linux 10.2 DVD ISO into a minimal EFI VirtualBox VM and Vagrant box.
- `ansible/`: Ansible roles. `mongodb_basic` installs and tunes MongoDB 8.0 Community; `mongodb_replica_set` depends on it and configures a replica set member; `mongodb_sharding` is an empty skeleton so far.
- `replicas/`: three-VM replica set `foobar` (`moe`, `larry`, `curly` as `<name>.alceu.org`, 192.168.56.11–13, port 27017).
- `sharding/`: two-shard cluster with single-member replica sets: `config` (192.168.56.21; config server `cfgrs` on 27019 plus `mongos` on 27017), `shard1` and `shard2` (192.168.56.22–23; `shard1rs`/`shard2rs` on 27018). **Not migrated yet:** its playbook and `group_vars/` still use the old `mongod` role and `mongod_*` variables, which no longer exist, so it doesn't run.
- `Vagrantfile` (repo root): a single VM from the box, no provisioner.

All Vagrantfiles use the box registered locally as `RockyLinux`.

`box/SUMMARY.md` is the detailed design doc for the box: the reasons for every package exclusion and the kickstart settings. `ansible/mongodb_basic/README.md` covers that role's task order and variables, SELinux policy scope, open checks, and tuning that is deliberately not applied. Read them before changing the build or the roles, and keep them in sync when you change behavior.

## Commands

Run Packer from `box/` (paths in `rocky.pkr.hcl` such as `http/` and `scripts/` are relative to it):

```bash
packer init .
packer validate .
packer build .                      # headless
packer build -var headless=false .  # watch the installer
```

Inputs are read from `~/Downloads/Rocky-10.2-x86_64-dvd1.iso` and `~/Downloads/CHECKSUM` (`iso_path`, `iso_checksum_file`). Output: `box/output/rockylinux/` (VM) and `box/output/rockylinux-virtualbox.box`. Load it for the root Vagrantfile with `vagrant box add --name RockyLinux box/output/rockylinux-virtualbox.box --force`.

Run the test environments from their directory (`replicas/` or `sharding/`):

```bash
vagrant up                    # boots all VMs; the last one runs the playbook on all of them
vagrant provision <last-vm>   # re-run the playbook (curly or shard2)
vagrant destroy -f
```

Lint the role and the playbooks (the role uses `# noqa` annotations). Run from an environment directory so its `ansible.cfg` resolves the role:

```bash
ansible-galaxy collection install -r ../ansible/mongodb_basic/meta/requirements.yml  # once; ansible.posix
ANSIBLE_CONFIG=$PWD/ansible.cfg ansible-lint playbook.yml
ANSIBLE_CONFIG=$PWD/ansible.cfg ansible-playbook --syntax-check -i localhost, playbook.yml
```

## Architecture and constraints

**Build pipeline** (`box/rocky.pkr.hcl`): the EFI GRUB boot command appends `inst.ks=http://{{ .HTTPIP }}...` so Packer serves `http/ks.cfg` → unattended install from the DVD → `scripts/base.sh` (dnf update + Guest Additions toolchain, then reboot, hence `expect_disconnect`) → `guest-additions.sh` → `vagrant.sh` → `cleanup.sh` (removes the toolchain, zeroes free space) → Vagrant post-processor.

Things that are coupled across files:

- `ssh_password` in `variables.pkr.hcl` must match the `vagrant` user password in `http/ks.cfg`.
- Packages stay minimal on purpose: `ks.cfg` excludes them, and `base.sh` installs with `install_weak_deps=False` so a kernel update doesn't pull firmware back in. Check `SUMMARY.md` before adding a package.
- Guest Additions is compiled for one exact kernel, and the toolchain is removed afterwards. Rebuild the box rather than updating the kernel inside it.

**Ansible role `mongodb_basic`**: `tasks/main.yml` imports, in order, preflight → install → selinux (when `selinux_policy`) → thp → system → firewall (when `enable_firewall`) → service (systemd drop-in only). It doesn't write `mongod.conf` or start `mongod`. Only `ansible.builtin` modules are used, except `ansible.posix.firewalld` for the firewall (the role and `sharding/playbook.yml`); `meta/requirements.yml` declares that one collection. Don't add other collection dependencies (e.g. remount is a plain `mount -o remount` command). User-tunable settings live in `defaults/main.yml`; fixed facts (SELinux default paths/ports, the bad-kernel range 6.19–7.0.13, SELinux build packages) live in `vars/main.yml`. Variables have no role prefix, except `mongod_port` (`port` is a reserved Ansible keyword).

- It owns `mongod_port`, `db_path`, `log_path` and the `Restart mongod` handler, which other roles reuse. The handler is `systemctl try-restart`, so it never starts a stopped `mongod`.
- The upstream `mongodb-selinux` policy only supports default `dbPath`, log path, and ports 27017–27019; preflight fails otherwise when the policy is enabled.
- THP is *enabled* (`always` / `defer+madvise`) for MongoDB 8.0+, unlike the older "disable THP" advice. A `mongod-thp.service` unit applies it before `mongod.service`.
- The policy also means one `mongod` per VM, which is why every replica set member is its own VM. `mongos` isn't covered by the policy and runs unconfined.
- The mongod systemd override sets `GLIBC_TUNABLES=glibc.pthread.rseq=0` so TCMalloc per-CPU caches work with EL10's glibc.
- Ansible runs no verification checks (THP, SELinux domain, TCMalloc); check those by hand.

**Ansible role `mongodb_replica_set`**: lists `mongodb_basic` as a dependency in `meta/main.yml`, so playbooks name only `mongodb_replica_set`. Its defaults are the `mongod.conf`-only settings (`bind_ip`, `cache_size_gb`, `ftdc_dir_size_mb`, `replica_set_name`, `oplog_size_mb`, `replica_set_members`, `service_enabled`); don't duplicate `mongodb_basic`'s. It writes `mongod.conf` with `security.keyFile` and `authorization: enabled`, generates the keyfile once on the control node (`<playbook dir>/keyfile`, git-ignored), copies it to `/etc/mongodb/pki/keyfile`, and starts `mongod`. By design it doesn't run `rs.initiate()` or create users; that's done by hand through the localhost exception.

**Test environment `replicas/`**: the Vagrantfile reads the member names and IPs, port, domain and replica set name from `config.yml`; the last node listed gets the provisioner. VirtualBox boots the VMs one at a time, so the `ansible` provisioner is attached only to the last VM (`curly`), with `limit = "all"`: one `ansible-playbook` run configures all members in parallel, and `run_once` generates the keyfile once. Each host's `bind_ip` (`127.0.0.1,<private IP>`) comes from `ansible.host_vars`; the shared settings (`replica_set_name`, `replica_set_members`, the 1 GB VM sizing of 0.25 GB cache, 990 MB oplog and 50 MB FTDC, `enable_firewall`) come from `ansible.extra_vars`. vagrant-hostmanager writes each name and `<name>.alceu.org` into every guest's `/etc/hosts`. `ansible.cfg` sets `roles_path = ../ansible`. VMs are linked clones. `playbook.yml` sets the timezone (`timezone`, `America/Sao_Paulo`) in `pre_tasks` with `timedatectl`, not `community.general.timezone`, and notifies the role's `Restart mongod` handler because mongod logs in local time.

**Test environment `sharding/` (old layout, not migrated)**: the Vagrant `ansible` provisioner is attached only to the last VM, with `limit = "all"`, so one play covers every member and `mongod` runs on all hosts before `rs.initiate()` and `addShard`. In `group_vars/`, each replica set is a group named after the set, and `all.yml` derives the members and the initiating host from it.

- Group vars that use `hostvars` can't be read from another host through `hostvars[...]`, because the nested `hostvars` is undefined there. That's why the mongos play rebuilds the addresses from `node_ip` and `mongod_port`.
- mongosh scripts are passed with `command: argv` and `--eval`; they check current state first (`rs.status()`, `listShards`) so re-provisioning doesn't change anything.
