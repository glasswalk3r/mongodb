#!/usr/bin/env python

import json
import sys
from getpass import getpass

import yaml
from pydantic import BaseModel
from pydantic.networks import IPvAnyAddress
from pymongo import MongoClient
from pymongo.errors import (
    ConfigurationError,
    ConnectionFailure,
    OperationFailure,
    PyMongoError,
    ServerSelectionTimeoutError,
)


class MongoDBReplSetCfg(BaseModel):
    replica_set: str
    domain: str
    port: int
    data_disk_mb: int
    nodes: dict[str, IPvAnyAddress]

    def dsn(self, user, password) -> str:
        nodes = ",".join([f"{node}.{self.domain}:{self.port}" for node in self.nodes])
        return f"mongodb://{user}:{password}@{nodes}?authSource=admin&replicaSet={self.replica_set}"


def read_config() -> MongoDBReplSetCfg:
    with open("config.yaml") as fp:
        data = yaml.safe_load(fp)

    return MongoDBReplSetCfg.model_validate(data)


# while (true) {
#   let s = db.adminCommand({ replSetGetStatus: 1 }).initialSyncStatus;
#   if (!s) { print("Sync complete!"); break; }
#   let pct = ((s.approxTotalBytesCopied / s.approxTotalDataSize) * 100).toFixed(2);
#   print(`Copied: ${pct}% | DBs Cloned: ${s.databases.databasesCloned}`);
#   sleep(5000);
# }

mongo_cfg = read_config()
user = "sys"
password = getpass(f"Type the password for {user}: ")
uri = mongo_cfg.dsn(user, password)

with MongoClient(uri) as client:
    try:
        db = client.get_database("sample")
        collection = db.get_collection("books")
        book = collection.find_one({"language": "en-US"})
        print(json.dumps(book, indent=4, default=str))
    except ConfigurationError as e:
        print(f"Invalid URI or client config: {e}")
    except ServerSelectionTimeoutError as e:
        print(f"Could not reach MongoDB server: {e}")
    except OperationFailure as e:
        # Includes auth failures (code 18) and command errors
        print(f"Database operation failed (code {e.code}): {e.details}")
    except ConnectionFailure as e:
        print(f"Lost connection to database: {e}")
    except PyMongoError as e:
        print(f"General PyMongo error: {e}")
    except Exception as e:  # noqa: BLE001
        print(f"Got an unexpected exception: {e!s}", file=sys.stderr)
        sys.exit(1)
