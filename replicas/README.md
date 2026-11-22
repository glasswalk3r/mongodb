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

## Data disk and I/O throttling

Each member keeps `dbPath` (`/var/lib/mongo`) on its own disk instead of the
root file system:

- **The disk:** a regular, dynamically allocated VDI in
  `.vagrant/disks/<name>-data.vdi`, attached to SATA port 1 (`/dev/sdb` in the
  guest). Its size is `data_disk_mb` in `config.yml`. Unlike the boot disk,
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

1. Measure the disk's ceiling inside the VM, on the data disk
   (`dnf install fio`):

   ```bash
   cd /var/lib/mongo
   sudo fio --name=seqwrite --rw=write --bs=1M --size=512M --direct=1 \
       --ioengine=libaio --iodepth=8 --filename=fio.test
   sudo rm fio.test
   ```

2. Measure what `mongod` actually uses: run your write load against the
   primary and watch the secondary with `iostat -xm 2 sdb` (`dnf install
   sysstat`).
3. Set the limit below that peak on one secondary, keep the write load going,
   and watch the lag grow with `rs.printSecondaryReplicationInfo()` (see
   [Verifying replication](#verifying-replication)).

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
