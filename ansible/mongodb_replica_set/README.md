# mongodb_replica_set

Configures `mongod` as a member of a single replica set, with keyfile
authentication between members and authorization enabled. It depends on
`mongodb_basic` (see `meta/main.yml`), which installs and tunes MongoDB first.

It doesn't run `rs.initiate()` or create users. Do that by hand on one member
over localhost, using the localhost exception (see `replicas/README.md`).

## Tasks

1. Writes `/etc/mongod.conf`: port and paths from `mongodb_basic`, `bindIp`,
   the optional cache and FTDC size limits, `replication` and, when
   `replica_set_name` is set, `security.keyFile` and
   `security.authorization: enabled`.
2. Generates a keyfile on the control node once, in
   `{{ playbook_dir }}/keyfile` (keep it out of version control), and copies it
   to `/etc/mongodb/pki/keyfile` on every member, owned by `mongod`, mode 0400.
3. Enables and starts `mongod`, restarting it when the config or the keyfile
   changes, and waits for the port.
4. Prints the connection string built from `replica_set_members`.

## Variables (`defaults/main.yml`)

| Variable | Default |
|---|---|
| `bind_ip` | `127.0.0.1`; add the host's private IP for a multi-host set |
| `cache_size_gb` / `ftdc_dir_size_mb` | `0` / `0` (MongoDB defaults) |
| `replica_set_name` | `""` (standalone, no keyfile or authorization) |
| `oplog_size_mb` | `0` (MongoDB default) |
| `replica_set_members` | `[]`; `host:port` of every member, only for the printed connection string |
| `service_enabled` | `true` |

From `mongodb_basic`: `mongod_port`, `db_path`, `log_path` and
`enable_firewall` (needed when `bind_ip` isn't loopback only).

Fixed in `vars/main.yml`: `mongod_keyfile_path` (`/etc/mongodb/pki`) and
`mongod_keyfile_name` (`keyfile`).

## Example

```yaml
- hosts: all
  become: true
  roles:
    - mongodb_replica_set
  vars:
    replica_set_name: rs0
    replica_set_members: [rs1.example.org:27017, rs2.example.org:27017, rs3.example.org:27017]
    bind_ip: "127.0.0.1,192.0.2.11"   # per host, e.g. in host_vars
    enable_firewall: true
```

## License

GPL-3.0-only
