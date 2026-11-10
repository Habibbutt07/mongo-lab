#!/usr/bin/env bash
# =====================================================================
# Topic 8 - MongoDB III: replica set, failover  (run in GitHub Codespaces)
# Usage:  bash topic8.sh 2>&1 | tee topic8_log.txt      <- the log is part of the deliverable
# Needs mongod + mongosh installed (see GUIDE.md part B).
# =====================================================================
set -u
status() {   # compact view of replica-set members: port, state
  mongosh --quiet --port "$1" --eval '
    rs.status().members.forEach(m => print(m.name, "=>", m.stateStr, " health:", m.health))'
}

echo "### 1. Data directories and 3 mongod processes"
pkill mongod 2>/dev/null; sleep 2
rm -rf ~/data && mkdir -p ~/data/db1 ~/data/db2 ~/data/db3
mongod --replSet rs0 --port 27017 --dbpath ~/data/db1 --bind_ip localhost --fork --logpath ~/data/db1.log
mongod --replSet rs0 --port 27018 --dbpath ~/data/db2 --bind_ip localhost --fork --logpath ~/data/db2.log
mongod --replSet rs0 --port 27019 --dbpath ~/data/db3 --bind_ip localhost --fork --logpath ~/data/db3.log

echo "### 2. rs.initiate()"
mongosh --quiet --port 27017 --eval '
rs.initiate({
  _id: "rs0",
  members: [
    { _id: 0, host: "localhost:27017" },
    { _id: 1, host: "localhost:27018" },
    { _id: 2, host: "localhost:27019" }
  ]
})'
sleep 15     # wait for the election to finish

echo "### 3. rs.status() BEFORE failure (1 PRIMARY + 2 SECONDARY expected)"
status 27017
mongosh --quiet --port 27017 --eval 'printjson(rs.status())' > rs_status_before.json

echo "### 4. Write on PRIMARY, read on SECONDARY"
mongosh --quiet --port 27017 --eval 'printjson(db.test.insertOne({msg:"hello"}))'
sleep 2
mongosh --quiet --port 27018 --eval 'rs.secondaryOk(); printjson(db.test.find().toArray())'

echo "### 5. Kill the PRIMARY (27017) and watch the election"
mongosh --quiet --port 27017 --eval 'db.getSiblingDB("admin").shutdownServer({force: true})'
sleep 15
echo "--- rs.status() AFTER failure (asked to 27018) ---"
status 27018
mongosh --quiet --port 27018 --eval 'printjson(rs.status())' > rs_status_after.json

echo "### 5b. Writes still work on the NEW primary"
mongosh --quiet "mongodb://localhost:27018,localhost:27019/?replicaSet=rs0" \
        --eval 'printjson(db.test.insertOne({msg:"after failover"}))'

echo "### 5c. Old primary rejoins as SECONDARY"
mongod --replSet rs0 --port 27017 --dbpath ~/data/db1 --bind_ip localhost --fork --logpath ~/data/db1.log
sleep 15
status 27018

echo "### 5d. (bonus) Majority lost: stop two nodes, the survivor steps down to SECONDARY"
PRIMARY_PORT=$(mongosh --quiet --port 27018 --eval 'print(rs.isMaster().primary.split(":")[1])')
echo "current primary port: $PRIMARY_PORT"
for p in 27017 27018 27019; do
  [ "$p" != "27019" ] && mongosh --quiet --port $p --eval 'db.getSiblingDB("admin").shutdownServer({force:true})' >/dev/null 2>&1
done
sleep 15
mongosh --quiet --port 27019 --eval 'print("27019 state:", rs.isMaster().ismaster ? "PRIMARY" : "NOT primary (no majority)")'
mongosh --quiet --port 27019 --eval 'rs.secondaryOk(); printjson(db.test.find().toArray())'   # reads still OK on secondary

echo "### cleanup:  pkill mongod"
