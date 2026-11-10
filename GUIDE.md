# MongoDB Labs (Topics 6, 7, 8) - Step-by-Step Guide with Complete Solutions

Files in this package:

| File | Purpose |
|---|---|
| `gen_products.py` | creates `products.json` (60 docs, incl. 4 "discontinued") |
| `gen_orders.py` | creates `users.json` (50) and `orders.json` (600, nested `items[]`, `orderDate`) |
| `topic6.js` | Topic 6 deliverable: every CRUD command, commented |
| `topic7.js` | Topic 7 deliverable: 2 pipelines, explain before/after, TTL |
| `topic8.sh` | Topic 8: replica set, failover, log |

---

## Part A - Atlas setup (Topics 6 and 7)

1. Register at mongodb.com/cloud/atlas/register.
2. Build a Database -> Free (M0) -> any region -> Create.
3. Database Access -> Add New Database User (username + password, keep them).
4. Network Access -> Add IP Address -> Allow Access from Anywhere (0.0.0.0/0).
5. Wait 2-5 minutes until the cluster is green.
6. Connect -> Drivers -> copy the string
   `mongodb+srv://<user>:<password>@cluster0.xxxxx.mongodb.net/`
   (if the password has special characters like `@` or `#`, URL-encode them).

## Part B - Codespaces setup

1. github.com -> **+** -> New codespace -> any repo -> Create.
2. Install MongoDB tools (check `lsb_release -cs`; use that codename instead of `jammy` if different):

```bash
wget -qO - https://www.mongodb.org/static/pgp/server-8.0.asc | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg
echo "deb [signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/8.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list
sudo apt-get update
sudo apt-get install -y mongodb-org mongodb-mongosh mongodb-database-tools
```

3. Verify: `mongosh --version && mongoimport --version && mongod --version`
4. Upload all files from this package into the Codespace (drag and drop into the Explorer).
5. Test Atlas connection:
   `mongosh "mongodb+srv://<user>:<password>@cluster0.xxxxx.mongodb.net/"`
   You should see a prompt like `Atlas atlas-xxxxx-shard-0 [primary] test>`. Exit with `exit`.

---

## Topic 6 - CRUD

**Step 1 - generate and import the data**
```bash
python3 gen_products.py
mongoimport --uri "mongodb+srv://<user>:<password>@cluster0.xxxxx.mongodb.net/shop_db" \
  --collection products --file products.json --jsonArray
```
Expected: `60 document(s) imported successfully`.

**Step 2 - run the deliverable script**
```bash
mongosh "mongodb+srv://<user>:<password>@cluster0.xxxxx.mongodb.net/" --file topic6.js | tee topic6_output.txt
```
`topic6.js` contains (all commented):
- 10 distinct `find()` queries (range, `$in`, `$and`, sort/skip/limit, `$or`, array match, `$all`, `$nin` + projection, regex, `$size`)
- `updateMany` + `$mul: 1.10` on electronics, `updateOne` + `$addToSet` (run twice to show no duplicate)
- upsert into `stock` (first run creates, second run only matches)
- `countDocuments` before / `deleteMany` / after for `discontinued` (4 -> 0)
- bonus demos for the self-check questions (`replaceOne` vs `$set`, immutable `_id`)

The `ObjectId("...")` placeholders from the assignment are replaced by ids fetched with `findOne`, so the script runs unchanged.

Note: a script file cannot use `use shop_db`; the equivalent is `db = db.getSiblingDB("shop_db")`.

**Self-check answers**
1. **updateOne+$set vs replaceOne:** `$set` touches only the named fields (small oplog entry, other fields and concurrent changes to them are untouched). `replaceOne` writes the entire new document, so it costs more network/oplog/storage work and silently drops any field you omit.
2. **Why `_id` is immutable:** it is the primary key, backed by the mandatory unique index, and identifies the document in the oplog, replication and sharding. Changing it would really be a delete plus a new insert, so MongoDB rejects it.
3. **Upsert duplicates under concurrency:** two simultaneous upserts can both find no match and both insert. Without a unique index on the filter field nothing prevents it. Fix: create a unique index (e.g. on `stock.productId`) so one request fails with E11000 and can retry as an update.

---

## Topic 7 - Aggregation and indexing

**Step 1 - generate and import**
```bash
python3 gen_orders.py
mongoimport --uri "mongodb+srv://<user>:<password>@cluster0.xxxxx.mongodb.net/shop_db" --collection users  --file users.json  --jsonArray
mongoimport --uri "mongodb+srv://<user>:<password>@cluster0.xxxxx.mongodb.net/shop_db" --collection orders --file orders.json --jsonArray
```
The files use Extended JSON (`$oid`, `$date`) so `customerId` is a real ObjectId and `orderDate` a real Date.

**Step 2 - run**
```bash
mongosh "mongodb+srv://<user>:<password>@cluster0.xxxxx.mongodb.net/" --file topic7.js | tee topic7_output.txt
```

What it does:
1. **Pipeline 1** (`$match` -> `$unwind` -> `$group` -> `$sort` -> `$limit`): top 5 categories by revenue.
2. **Pipeline 2** (`$group` by customer -> `$sort` -> `$limit` -> `$lookup` users): top 5 customers (I added `$unwind` + `$project` so the customer name is readable).
3. **Before index:** `explain("executionStats")` on `{customerId: ...}` -> **COLLSCAN**, `totalDocsExamined = 600`.
4. **Index:** `createIndex({ customerId: 1, orderDate: -1 })` (ESR: equality field first, then sort/range field).
5. **After index:** **FETCH <- IXSCAN**, `totalDocsExamined` equals `nReturned` (about 12 on average, 600 orders / 50 customers).
6. **TTL:** `sessions.createIndex({createdAt:1},{expireAfterSeconds:60})`, insert one doc, wait 1-2 minutes (the TTL monitor runs every 60 s), then run `db.sessions.find()` -> empty.

**Short analysis to paste in the report (fill in your actual numbers):**
> Before the index, MongoDB performed a COLLSCAN: it examined all 600 documents (`totalDocsExamined = 600`) to return only N matching orders, an efficiency of N/600. After creating the compound index `{customerId: 1, orderDate: -1}` the winning plan changed to IXSCAN + FETCH; `totalKeysExamined` and `totalDocsExamined` both dropped to N, equal to `nReturned`, i.e. a ratio of 1:1. On 600 documents the time difference is tiny, but the work grows with collection size for a COLLSCAN while the index lookup stays roughly logarithmic. The index also supports sorting by `orderDate` within one customer without an in-memory sort.

---

## Topic 8 - Replication (Codespaces)

**Step 1 - run the whole lab and capture the log**
```bash
bash topic8.sh 2>&1 | tee topic8_log.txt
```
It performs, in order:
1. Creates `~/data/db1..db3` and starts 3 `mongod --replSet rs0` on ports 27017/27018/27019.
2. `rs.initiate()` with the 3 members.
3. `rs.status()` before failure -> 1 PRIMARY (27017) + 2 SECONDARY. Full JSON saved to `rs_status_before.json`.
4. Writes `{msg:"hello"}` on the primary, reads it on 27018 with `rs.secondaryOk()`.
5. Shuts down the primary with `shutdownServer({force:true})`, waits 15 s, shows `rs.status()` from 27018 -> 27017 is `(not reachable/healthy)`, one of 27018/27019 is the new PRIMARY. Saved to `rs_status_after.json`.
6. Extras: write on the new primary, restart 27017 (it rejoins as SECONDARY), then stop two nodes to show loss of majority.

If the script fails at the first mongod start, check `~/data/db1.log`. Run `pkill mongod` to clean up.

**Step 2 - Optional sharding description (half a page)**
> A sharded cluster consists of: (1) **shards** - here 2 shards, each ideally a replica set (`shardA`, `shardB`) holding a subset of the data; (2) **config servers** - a replica set (2 in the assignment, 3 in production) storing cluster metadata: the chunk ranges and which shard owns them; (3) **mongos** - the stateless router applications connect to; it reads metadata from the config servers and routes each query to the right shard(s), merging results. Setup: start config servers with `--configsvr --replSet cfg`, shards with `--shardsvr --replSet shardA/shardB`, run `rs.initiate()` on each, start `mongos --configdb cfg/host:port`, then in mongos `sh.addShard("shardA/host:port")`, `sh.addShard("shardB/host:port")`, `sh.enableSharding("shop_db")` and `sh.shardCollection("shop_db.orders", { customerId: "hashed" })`. The balancer then moves chunks to even out the shards.

**Step 3 - Failover description (half a page, adapt to your actual log)**
> Three mongod nodes formed replica set `rs0`; after `rs.initiate()` node 27017 won the election and became PRIMARY while 27018 and 27019 became SECONDARY and replicated the oplog. A document inserted on the primary was readable on a secondary (after `rs.secondaryOk()`), confirming replication. When I shut down the primary, the secondaries stopped receiving its heartbeats; after the election timeout (about 10 s by default) one secondary called an election and, with a vote of the remaining majority (2 of 3), became the new PRIMARY (in my run: **27018 / 27019 - check your rs.status()**). `rs.status()` then showed 27017 as unreachable (`health: 0`). Writes continued on the new primary without manual action, so the cluster stayed available. When 27017 was restarted it rejoined as a SECONDARY and caught up from the oplog. When I stopped two of three nodes, the last node could not reach a majority, stepped down to SECONDARY and refused writes (reads from it were still possible with secondary read preference), showing that a replica set needs a majority of voting members to elect a primary.

**Self-check answers**
1. **Data loss with `w: 1`:** the client gets an acknowledgement once only the primary has written. If the primary crashes before secondaries replicate that write, a secondary without it becomes primary; when the old primary returns, the un-replicated write is rolled back. Use `w: "majority"` (with journaling) to make the write survive failover.
2. **Majority unreachable:** no node can win an election, so there is no primary. The remaining nodes become SECONDARY: the set is read-only (with secondary read preference) and writes fail until a majority is back. This prevents split-brain.
3. **`_id` as shard key with monotonically increasing ObjectIds:** new ObjectIds always sort higher, so all inserts land in the last chunk on a single shard (hot shard). Writes aren't distributed, and that chunk keeps splitting and migrating. Use a hashed shard key (`{_id: "hashed"}`) or a well-distributed compound key.

---

## What to submit

- `topic6.js` (+ `topic6_output.txt`)
- `topic7.js` (+ `topic7_output.txt`, explain output before/after, analysis paragraph)
- `topic8_log.txt`, `rs_status_before.json`, `rs_status_after.json`, failover description (half a page), optional sharding description
- Answers to self-check questions
