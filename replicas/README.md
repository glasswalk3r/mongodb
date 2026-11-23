# Creating a MongoDB replica set

## Approach 1: Initialize Replica Set First, Enable Auth Last (Simplest)

This is the safest method when setting up a brand-new cluster from scratch:

1. Start all nodes without keyFile: Launch your mongod instances with replication.replSetName configured, but without security.keyFile enabled yet.
1. Initiate the replica set: Connect to one node via mongosh and run rs.initiate(...) to elect a Primary.
1. Create your users on the Primary: Switch to admin and run db.createUser(...) for your sys and user-admin accounts. Because the replica set is already running, these users automatically replicate to the Secondaries.
1. Add the keyfile and restart: Place the identical keyfile on every node, add security.keyFile to mongod.conf on each node, and restart the instances (Secondaries first, then Primary).

## Approach 2: Enable Keyfile First (Official Tutorial Method)

**This method used by the Ansible role.**

1. Start all nodes with keyFile enabled: Every mongod starts with security.keyFile and replication.replSetName configured.
1. Connect locally and initiate: Connect to one node via localhost (127.0.0.1) and run rs.initiate(...).
1. Create the first user immediately: on that exact same mongosh connection, switch to admin and create your first user. Once the first user is created (or if you disconnect after rs.initiate()), the localhost exception closes permanently.
1. Authenticate and create remaining users: Log in as that first user (db.auth(...)) to create any additional accounts like sys.

## Summary Recommendation

• If your nodes are already running with security.keyFile and you haven't created users yet, use Approach 2 (or temporarily comment out keyFile if you already disconnected after rs.initiate()).
• If you are starting from scratch, Approach 1 is much less error-prone.

## This environment

`vagrant up` provisions every member with `security.keyFile` and
`authorization: enabled` already in `mongod.conf`, so use Approach 2: on one
member, connect with `mongosh --host 127.0.0.1`, run `rs.initiate(...)`, then
create the first user in the same session. The playbook doesn't initiate the
set or create users. It generates the keyfile in `replicas/keyfile` (ignored by
git) on the first run and prints the connection string at the end.

## Local package mirror

Each member downloads about 180 MB of MongoDB packages. To download them once
instead, mirror them into `mongodb-repo/` (ignored by git) before `vagrant up`.
The script needs `defusedxml` from the repository's `requirements.txt`:

```bash
pip install -r ../requirements.txt
./sync-mongodb-repo.py                # MongoDB 8.0, the role's default
./sync-mongodb-repo.py --version 7.0  # another release series
```

It downloads the upstream repodata, the signing key and the newest RPM of each
package `mongodb-org` needs (8 RPMs, 181 MB for 8.0.38), checking each
file's SHA-256 against the metadata. It reads the dependencies from the
metadata, so the list follows upstream changes. Run it again to update: it
downloads only new files and deletes RPMs that are no longer the newest. The
mirror holds one release series; it has to match the role's `version`.

When `mongodb-repo/repodata/repomd.xml` exists, the Vagrantfile sets the role's
`repo_baseurl` and `repo_gpgkey` to `file:///vagrant/mongodb-repo/...`, so the
guests install through the `/vagrant` synced folder, still checking package
signatures. Without it, they download from `repo.mongodb.org` as before.

The URLs only change the `.repo` file: members provisioned earlier switch over
on the next `vagrant provision curly`. Updating the mirror also updates what a
new VM installs, but the role installs with `state: present`, so it never
upgrades a member that already has MongoDB.

## Data disk and I/O throttling

Each member keeps `dbPath` (`/var/lib/mongo`) on its own disk instead of the
root file system:

- **The disk:** a regular, dynamically allocated VDI in
  `.vagrant/disks/<name>-data.vdi`, attached to SATA port 1 (`/dev/sdb` in the
  guest). Its size is `data_disk_mb` in `config.yaml`. Unlike the boot disk,
  it's not part of the linked clone.
- **Formatting and mounting:** `mongodb_basic` formats it as XFS with the label
  `mongodata` and mounts it by label with `noatime` (`data_device` in the
  Vagrantfile's `extra_vars`).
- **Lifecycle:** `vagrant destroy` deletes it with the VM, and the next
  `vagrant up` creates a blank one.

The VMs have fixed VirtualBox names (`replicas-moe`, `replicas-larry`,
`replicas-curly`), so `VBoxManage` commands don't need the UUID.

### Throttling

The data disk is attached to a bandwidth group named `datadisk`, created with a
limit of 1000 MB/s, which doesn't throttle anything in practice. Change the
limit at any time, including while the VM is running; it applies immediately:

```bash
VBoxManage bandwidthctl replicas-moe set datadisk --limit 5M     # throttle to 5 MB/s
VBoxManage bandwidthctl replicas-moe set datadisk --limit 1000M  # back to unthrottled
VBoxManage bandwidthctl replicas-moe list                        # current limit
```

Uppercase `K`/`M`/`G` are bytes per second; lowercase `k`/`m`/`g` are bits per
second, so `5m` is eight times slower than `5M`.

The limit lasts until you change it again, also across `vagrant halt`/`up`,
because it's stored in the VM's configuration. It only covers the data disk:
the OS disk, SSH and logs keep their full speed.

Test the limit with real data, not zeros: the VDI is dynamically allocated and
VirtualBox skips all-zero writes, so `dd if=/dev/zero` runs at full speed under
any limit. `fio` fills its buffers with random data, so it's fine. Example
measured on `moe` with `dd if=/dev/urandom bs=1M count=200 oflag=direct,sync`:
115 MB/s unthrottled, 2.7 MB/s with `--limit 5M`.

Don't remove the group (`bandwidthctl ... remove`): the Vagrantfile attaches
the disk to it on every `vagrant up`, which then fails. Raise the limit
instead.

### Picking a limit

1. Measure what the data disk can do with an I/O pattern close to
   WiredTiger's, inside the VM (`dnf install fio`). See
   [Measuring the disk with fio](#measuring-the-disk-with-fio).
2. Measure what `mongod` actually uses: run your write load against the
   primary and watch the secondary with `iostat -xm 2 sdb` (`dnf install
   sysstat`).
3. Set the limit below that peak on one secondary, keep the write load going,
   and watch the lag grow with `rs.printSecondaryReplicationInfo()` (see
   [Verifying replication](#verifying-replication)).

Step 2 is what tells you the limit: below `mongod`'s real peak the secondary
falls behind, above it nothing happens. fio gives the ceiling, and shows how
latency changes under a limit.

### Measuring the disk with fio

A large sequential write (`--rw=write --bs=1M`) measures the best case, which
`mongod` never produces. WiredTiger does two kinds of I/O at the same time, so
the command runs two jobs together:

- **`data`: data and index files.** Random reads and writes of 4 to 32 KiB
  pages (4 KiB internal pages, leaf pages up to 32 KiB before compression).
  Reads happen when the working set doesn't fit in the cache, which here is
  only 0.25 GB; writes come from eviction and from the checkpoint every 60 s.
  `O_DIRECT` with 16 requests in flight, for the eviction and checkpoint
  threads.
- **`journal`: the write-ahead log.** Small sequential appends, each followed
  by `fdatasync`, one at a time. A write with `w: "majority"` (the default)
  waits for it, so its latency matters more than its throughput.

```bash
cd /var/lib/mongo
sudo fio --directory=/var/lib/mongo --filename_format='fio.$jobname' \
    --time_based --runtime=120 --ramp_time=15 \
    --name=data --ioengine=libaio --direct=1 --rw=randrw --rwmixread=50 \
    --bssplit=4k/40:8k/20:16k/20:32k/20 --size=4G --iodepth=16 \
    --name=journal --ioengine=sync --rw=write \
    --bssplit=4k/60:16k/30:64k/10 --size=512M --fdatasync=1
sudo rm -f fio.data fio.journal
sudo fstrim -v /var/lib/mongo
```

`--rwmixread=50` fits a secondary applying a write load; use 70 to 80 for a
read-heavy primary. Before it starts, fio writes both files in full ("Laying
out IO file"), which takes a few seconds and isn't measured.

Why this size and duration get past the caches:

- **Guest page cache:** the `data` job uses `O_DIRECT`, which bypasses it, and
  its 4 GB file is four times the VM's RAM. The `journal` job writes through
  the cache, like WiredTiger, but `fdatasync` forces every write to disk.
- **Host page cache:** not involved. The SATA controller runs with
  VirtualBox's "Use Host I/O Cache" off (the default for SATA), so every
  write reaches the VDI file on disk directly. That's also why a 1.4 s run
  isn't inflated by the host's RAM.
- **Warm-up:** `--ramp_time=15` discards the first 15 s, when the dynamically
  allocated VDI is still growing and the SSD's write cache is empty, and the
  120 s of `--time_based` measure the sustained rate instead of a burst.
- **SSD cache (limit):** a consumer SSD can absorb tens of GB of writes at
  full speed before slowing down. The 10 GB data disk can't hold a file large
  enough to exhaust that cache, so the result is your host disk's best
  sustained case, not its worst.

Cleanup: the VDI keeps the space fio wrote until it gets a discard. The disk
is attached with discard enabled, so `fstrim` after deleting the files shrinks
the VDI back (on `moe`, to 16 MB after a run).

Which values to read:

| Line | Job | Meaning |
|---|---|---|
| `read: IOPS=..., BW=...` and `write: IOPS=..., BW=...` | `data` | Random throughput. Add read and write `BW`: the bandwidth limit throttles both. |
| `clat percentiles` | `data` | Latency of each page read or written; look at the 99th percentile. |
| `sync percentiles` | `journal` | `fdatasync` latency: the time a journaled write waits. The most telling number for write latency. |
| `WRITE: bw=` in `Run status group 0` | both | Total write throughput. |

Measured on `moe`, unthrottled, with a 15 s run of the same command (1 GB
file): `data` 47 MiB/s read plus 47 MiB/s write at about 5,400 IOPS each,
`journal` `fdatasync` 5 ms on average and 214 ms at most. The same disk gives
357 MiB/s with a 1 MiB sequential write: the random pattern reaches about a
quarter of that.

With `--limit 5M`, a 16 KiB random-read job on `moe` reached 9.6 MiB/s, and a
sequential write 2.7 MB/s (see [Throttling](#throttling)). The limit covers
reads and writes, but not with the same precision, so measure under the limit
you set instead of assuming it.

## Network latency

VirtualBox can also put a NIC in a bandwidth group, but that only caps the
throughput of outgoing traffic. It adds delay only when the link is saturated,
which replication traffic (heartbeats, small oplog batches) never does. To
simulate distance between members, use `tc netem` inside the guest instead.
Nothing in the playbook applies it: run the commands below when you need them.

`tc` (`iproute-tc`) and the `sch_netem` module (`kernel-modules-extra`) are
already in the box. Apply netem only to the private interface (`enp0s8`,
192.168.56.x), so SSH and Ansible over NAT (`enp0s3`) keep their speed. Look up
the name if in doubt with `ip -o -4 addr show to 192.168.56.11`.

netem delays outgoing packets only: 50 ms on every member gives about 100 ms of
round trip between any two of them. A delay on one member only adds to the
traffic it sends, so its round trip to the others grows by the same 50 ms.

### Delay everything a member sends

```bash
vagrant ssh curly
sudo tc qdisc add dev enp0s8 root netem delay 50ms                       # fixed 50 ms
sudo tc qdisc change dev enp0s8 root netem delay 50ms 10ms distribution normal  # 50 ms ±10 ms jitter
sudo tc qdisc change dev enp0s8 root netem delay 50ms loss 1%            # add 1% packet loss
tc qdisc show dev enp0s8                                                 # what's applied
sudo tc qdisc del dev enp0s8 root                                        # remove it
```

`add` fails if a netem qdisc is already there; use `change` to adjust it, or
`del` first. Measured on `moe` with `ping` to the host (192.168.56.1): 0.4 ms
without netem, 50 ms with `delay 50ms`.

### Delay only the traffic to one peer

To model one link (for example `moe` to `curly` across a WAN while `moe` and
`larry` stay in the same data center), send only the packets for that address
through netem:

```bash
vagrant ssh moe
sudo tc qdisc add dev enp0s8 root handle 1: prio
sudo tc qdisc add dev enp0s8 parent 1:3 handle 30: netem delay 80ms
sudo tc filter add dev enp0s8 parent 1: protocol ip u32 match ip dst 192.168.56.13/32 flowid 1:3
sudo tc qdisc change dev enp0s8 parent 1:3 handle 30: netem delay 20ms   # adjust
sudo tc qdisc del dev enp0s8 root                                        # remove it
```

Repeat on `curly` with `dst 192.168.56.11/32` to delay both directions.

### Lifetime

Unlike the disk limit, the delay isn't stored anywhere: `vagrant reload` or
`halt`/`up` clears it. Re-running the playbook doesn't, but it isn't affected
either, because Ansible connects over NAT.

### What to watch

- `rs.printSecondaryReplicationInfo()`: replication lag of the delayed member.
- Writes with `w: "majority"` (the default) take at least one round trip to
  the nearest secondary. With only `curly` delayed, `larry` acknowledges and
  write latency barely changes; delay both secondaries to see it grow.
- Elections: heartbeats go every 2 s and a member calls an election after
  `electionTimeoutMillis` (10 s) without hearing from the primary. High loss or
  delays of several seconds can trigger elections.

## Commands

Create users:

```javascript
use admin

db.createUser({
  user: "root",
  pwd: passwordPrompt(),
  roles: [ { role: "root", db: "admin" } ]
})

db.createUser({
  user: "sys",
  pwd: passwordPrompt(),
  roles: [
    { role: "clusterManager", db: "admin" },
    { role: "readWriteAnyDatabase", db: "admin" },
    { role: "restore", db: "admin" }
  ]
})

db.createUser({
  user: "monitor",
  pwd: passwordPrompt(),
  roles: [ { role: "clusterMonitor", db: "admin" } ]
})
```

If you need to change later:

```javascript
db.grantRolesToUser("sys", ["root"])
```

Create the replica set:

```javascript
rs.initiate({
    _id: "foobar",
    version: 1,
    members: [
        {_id: 0, host: "moe.alceu.org:27017"},
        {_id: 1, host: "larry.alceu.org:27017"},
        {_id: 2, host: "curly.alceu.org:27017"}
    ]
})
```

Create the security key:

```
openssl rand -base64 756 > keyfile
```

```bash
mongosh 'mongodb://<user>:<password>@moe.alceu.org,larry.alceu.org,curly.alceu.org/?authSource=admin&replicaSet=foobar'
```

## Verifying replication

After a bulk load (for example with `mongoimport`), check three things in this
order: the secondaries have caught up, every member has the same number of
documents, and the data is identical. The examples use the `books` database and
collection; replace them with yours. Leave the password out of the URI and
`mongosh` prompts for it.

### 1. Members are healthy and caught up

Connect to the replica set as `monitor` (`clusterMonitor` is enough for these
commands):

```bash
mongosh 'mongodb://monitor@moe.alceu.org,larry.alceu.org,curly.alceu.org/?authSource=admin&replicaSet=foobar'
```

```javascript
// State, health and last applied operation of each member
rs.status().members.map(m => ({ name: m.name, state: m.stateStr, health: m.health, optime: m.optimeDate }))

// How far each secondary is behind the primary
rs.printSecondaryReplicationInfo()

// Oplog size and the time window it covers
rs.printReplicationInfo()
```

Expected: one `PRIMARY` and two `SECONDARY` members, all with `health: 1` and
the same `optimeDate`, and each secondary `0 secs` behind the primary. That
means the secondaries have applied every write. `mongoimport` uses the
`majority` write concern by default, so at least one secondary is already in
sync when the import ends; the other one catches up within seconds.

A member in `RECOVERING`, or a "too stale" message in its log, fell behind by
more than the oplog window reported by `rs.printReplicationInfo()`. It can't
catch up from the oplog and needs an initial sync. The oplog here is small (990
MB), so this can happen if you stop a secondary during a large import.

### 2. Every member has the same document count

Connect to each member on its own (`directConnection=true`) instead of to the
replica set, which would always send the reads to the primary.
`readPreference=secondaryPreferred` lets a secondary answer the read. `sys`
can read any database:

```bash
for h in moe larry curly; do
  printf '%s: ' "$h"
  mongosh "mongodb://sys@$h.alceu.org:27017/books?authSource=admin&directConnection=true&readPreference=secondaryPreferred" \
    --quiet --eval 'db.books.countDocuments({})'
done
```

All three counts must be equal, and equal to the number of documents imported.
Use `countDocuments()`, not `estimatedDocumentCount()`: the estimate comes from
collection metadata and can be wrong after an unclean shutdown.

### 3. The data is identical

`dbHash` returns an MD5 hash of each collection's contents on the member it
runs on. Run it on every member, the same way as the count:

```bash
for h in moe larry curly; do
  printf '%s: ' "$h"
  mongosh "mongodb://sys@$h.alceu.org:27017/books?authSource=admin&directConnection=true&readPreference=secondaryPreferred" \
    --quiet --eval 'db.runCommand({ dbHash: 1, collections: ["books"] }).collections.books'
done
```

The three hashes must match. Run this only while nothing is writing to the
collection: a member that hasn't applied the latest write yet gives a different
hash. `dbHash` reads the whole collection, so on large collections and these
small VMs it takes a while and loads the members.

Each loop asks for the password once per member.
