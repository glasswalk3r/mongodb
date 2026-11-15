# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Infrastructure only, no application code:

- `box/`: a Packer build that turns the Rocky Linux 10.2 DVD ISO into a minimal EFI VirtualBox VM and Vagrant box, plus an Ansible role (`box/mongod/`) that installs and tunes MongoDB 8.0 Community on it.
- `replicas/`: three-VM replica set `rs0` (`rs1`–`rs3`, 192.168.56.11–13, port 27017).
- `sharding/`: two-shard cluster with single-member replica sets: `config` (192.168.56.21; config server `cfgrs` on 27019 plus `mongos` on 27017), `shard1` and `shard2` (192.168.56.22–23; `shard1rs`/`shard2rs` on 27018).
- `Vagrantfile` (repo root): a single VM from the box, no provisioner.

All Vagrantfiles use the box registered locally as `RockyLinux`.

`box/SUMMARY.md` is the detailed design doc: the reasons for every package exclusion, the kickstart settings, the role's task order and variables, SELinux policy scope, open checks, and tuning that is deliberately not applied. Read it before changing the build or the role, and keep it in sync when you change behavior.

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
vagrant provision <last-vm>   # re-run the playbook (rs3 or shard2)
vagrant destroy -f
```

Lint the role and the playbooks (the role uses `# noqa` annotations). Run from an environment directory so its `ansible.cfg` resolves the role:

```bash
ansible-galaxy collection install -r ../box/mongod/meta/requirements.yml  # once; ansible.posix
ANSIBLE_CONFIG=$PWD/ansible.cfg ansible-lint playbook.yml ../box/mongod
ANSIBLE_CONFIG=$PWD/ansible.cfg ansible-playbook --syntax-check -i localhost, playbook.yml
```

## Architecture and constraints

**Build pipeline** (`box/rocky.pkr.hcl`): the EFI GRUB boot command appends `inst.ks=http://{{ .HTTPIP }}...` so Packer serves `http/ks.cfg` → unattended install from the DVD → `scripts/base.sh` (dnf update + Guest Additions toolchain, then reboot, hence `expect_disconnect`) → `guest-additions.sh` → `vagrant.sh` → `cleanup.sh` (removes the toolchain, zeroes free space) → Vagrant post-processor.

Things that are coupled across files:

- `ssh_password` in `variables.pkr.hcl` must match the `vagrant` user password in `http/ks.cfg`.
- Packages stay minimal on purpose: `ks.cfg` excludes them, and `base.sh` installs with `install_weak_deps=False` so a kernel update doesn't pull firmware back in. Check `SUMMARY.md` before adding a package.
- Guest Additions is compiled for one exact kernel, and the toolchain is removed afterwards. Rebuild the box rather than updating the kernel inside it.

**Ansible role `mongod`**: `tasks/main.yml` imports, in order, preflight → install → selinux (when `mongod_selinux_policy`) → thp → system → firewall (when `mongod_firewall`) → service → replication (only on the host with `mongod_replset_initiate`) → verify. Only `ansible.builtin` modules are used, except `ansible.posix.firewalld` for the firewall (the role and `sharding/playbook.yml`); `meta/requirements.yml` declares that one collection. Don't add other collection dependencies (e.g. remount is a plain `mount -o remount` command). User-tunable settings live in `defaults/main.yml`; fixed facts (SELinux default paths/ports, the bad-kernel range 6.19–7.0.13, SELinux build packages) live in `vars/main.yml`.

- The upstream `mongodb-selinux` policy only supports default `dbPath`, log path, and ports 27017–27019; preflight fails otherwise when the policy is enabled.
- THP is *enabled* (`always` / `defer+madvise`) for MongoDB 8.0+, unlike the older "disable THP" advice. A `mongod-thp.service` unit applies it before `mongod.service`.
- The policy also means one `mongod` per VM, which is why every replica set member is its own VM. `mongos` isn't covered by the policy and runs unconfined; it's set up by tasks in `sharding/playbook.yml`, not by the role.
- The mongod systemd override sets `GLIBC_TUNABLES=glibc.pthread.rseq=0` so TCMalloc per-CPU caches work with EL10's glibc; `verify.yml` asserts this, the THP values, and the `mongod_t` SELinux domain.

**Test environments** (`replicas/`, `sharding/`): the Vagrant `ansible` provisioner is attached only to the last VM, with `limit = "all"`, so one play covers every member. Ansible's linear strategy then has `mongod` running on all hosts before `rs.initiate()` and `addShard`. The Vagrantfile defines the inventory groups and each VM's `node_ip`; `ansible.cfg` sets `roles_path = ../box`. In `group_vars/`, each replica set is a group named after the set; `all.yml` derives `mongod_replset_members` and `mongod_replset_initiate` (first host in the group) from it, and sizes everything for 1 GB VMs (0.25 GB cache, 990 MB oplog, 50 MB FTDC). VMs are linked clones.

- Group vars that use `hostvars` (like `mongod_replset_members`) can't be read from another host through `hostvars[...]`, because the nested `hostvars` is undefined there. That's why the mongos play rebuilds the addresses from `node_ip` and `mongod_port`.
- mongosh scripts are passed with `command: argv` and `--eval`; they check current state first (`rs.status()`, `listShards`) so re-provisioning doesn't change anything.
