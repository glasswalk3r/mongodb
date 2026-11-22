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
