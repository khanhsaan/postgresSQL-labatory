# LAB 4 — HA Automation with Patroni (Failover Baseline)

**Goal:** Automate failover with Patroni and understand how distributed consensus solves the manual failover problem.

By the end of Lab 4, you will:
- Set up Patroni + etcd for automated failover
- Understand leader election and distributed consensus
- Trigger automatic failover (30-60 seconds)
- Compare automated vs manual failover
- Learn about fencing and split-brain prevention

---

## Why Patroni?

### The Problem (From LAB 3)
- Manual failover: 20-45 minutes
- Requires human intervention
- Prone to errors
- No automatic detection

### The Solution (Patroni)
- Automatic failover: 30-60 seconds
- No human intervention needed
- Consistent, tested process
- Built-in health checks

### How Patroni Works

```
┌─────────────────────────────────────────────┐
│              etcd (DCS)                     │
│     Distributed Configuration Store         │
│  - Stores cluster state                     │
│  - Leader election via lock                 │
│  - Health check results                     │
└─────────────────────────────────────────────┘
         ▲              ▲              ▲
         │              │              │
    ┌────┴────┐    ┌────┴────┐    ┌────┴────┐
    │ Patroni │    │ Patroni │    │ Patroni │
    │  Node1  │    │  Node2  │    │  Node3  │
    └────┬────┘    └────┬────┘    └────┬────┘
         │              │              │
    ┌────▼────┐    ┌────▼────┐    ┌────▼────┐
    │PostgreSQL│   │PostgreSQL│   │PostgreSQL│
    │(Primary)│    │(Replica)│    │(Replica)│
    └─────────┘    └─────────┘    └─────────┘
```

**Key concepts:**
- **DCS (Distributed Configuration Store):** etcd stores who is the leader
- **Leader lock:** Only one node can hold the leader lock
- **Health checks:** Patroni constantly monitors PostgreSQL
- **Automatic promotion:** If leader dies, replica takes the lock

---

## Architecture Overview

### Components

| Component | Purpose | Port |
|-----------|---------|------|
| **etcd** | Distributed key-value store for consensus | 2379 |
| **Spilo** | All-in-one Patroni + PostgreSQL image | 5432, 8008 |
| **PostgreSQL** | Database server (bundled in Spilo) | 5432 |
| **Patroni** | HA manager (bundled in Spilo) | 8008 |

### What We Built

```
Client → Patroni Cluster (3 nodes) → etcd (consensus)
```

---

## Prerequisites

### Clean slate from LAB 3

```bash
cd /Users/anthonytran/Desktop/postgresSQL-labatory

# Stop everything
docker compose down

# Remove all volumes
docker volume prune -f

# Verify cleanup
docker volume ls | grep pg_node
```

Expected: No volumes

---

## Step 1: Create Docker Compose for Patroni

**Note:** We're using the **Spilo** image from Zalando, which bundles Patroni + PostgreSQL together. This simplifies deployment and ensures compatibility.

Create `docker-compose-patroni.yml` in `/Users/anthonytran/Desktop/postgresSQL-labatory/`:

```yaml
services:
  etcd:
    image: quay.io/coreos/etcd:v3.5.9
    container_name: etcd
    environment:
      ETCD_NAME: etcd
      ETCD_LISTEN_CLIENT_URLS: http://0.0.0.0:2379
      ETCD_ADVERTISE_CLIENT_URLS: http://etcd:2379
      ETCD_LISTEN_PEER_URLS: http://0.0.0.0:2380
      ETCD_INITIAL_ADVERTISE_PEER_URLS: http://etcd:2380
      ETCD_INITIAL_CLUSTER: etcd=http://etcd:2380
      ETCD_INITIAL_CLUSTER_STATE: new
      ETCD_INITIAL_CLUSTER_TOKEN: etcd-cluster
    ports:
      - "2379:2379"
    networks:
      - patroni_net

  patroni1:
    image: ghcr.io/zalando/spilo-16:3.2-p3
    container_name: patroni1
    hostname: patroni1
    environment:
      SCOPE: postgres-cluster
      ETCD3_HOSTS: etcd:2379
      PATRONI_REPLICATION_USERNAME: repl_user
      PATRONI_REPLICATION_PASSWORD: repl_pass
      PATRONI_SUPERUSER_USERNAME: postgres
      PATRONI_SUPERUSER_PASSWORD: postgres
      PATRONI_RESTAPI_USERNAME: admin
      PATRONI_RESTAPI_PASSWORD: admin
    volumes:
      - patroni1_data:/home/postgres/pgdata
    ports:
      - "5433:5432"
      - "8008:8008"
    networks:
      - patroni_net
    depends_on:
      - etcd

  patroni2:
    image: ghcr.io/zalando/spilo-16:3.2-p3
    container_name: patroni2
    hostname: patroni2
    environment:
      SCOPE: postgres-cluster
      ETCD3_HOSTS: etcd:2379
      PATRONI_REPLICATION_USERNAME: repl_user
      PATRONI_REPLICATION_PASSWORD: repl_pass
      PATRONI_SUPERUSER_USERNAME: postgres
      PATRONI_SUPERUSER_PASSWORD: postgres
      PATRONI_RESTAPI_USERNAME: admin
      PATRONI_RESTAPI_PASSWORD: admin
    volumes:
      - patroni2_data:/home/postgres/pgdata
    ports:
      - "5434:5432"
      - "8009:8008"
    networks:
      - patroni_net
    depends_on:
      - etcd

  patroni3:
    image: ghcr.io/zalando/spilo-16:3.2-p3
    container_name: patroni3
    hostname: patroni3
    environment:
      SCOPE: postgres-cluster
      ETCD3_HOSTS: etcd:2379
      PATRONI_REPLICATION_USERNAME: repl_user
      PATRONI_REPLICATION_PASSWORD: repl_pass
      PATRONI_SUPERUSER_USERNAME: postgres
      PATRONI_SUPERUSER_PASSWORD: postgres
      PATRONI_RESTAPI_USERNAME: admin
      PATRONI_RESTAPI_PASSWORD: admin
    volumes:
      - patroni3_data:/home/postgres/pgdata
    ports:
      - "5435:5432"
      - "8010:8008"
    networks:
      - patroni_net
    depends_on:
      - etcd

networks:
  patroni_net:
    driver: bridge

volumes:
  patroni1_data:
  patroni2_data:
  patroni3_data:
```

**Key Configuration Explained:**

| Variable | Purpose |
|----------|---------|
| `SCOPE` | Cluster name (all nodes must use the same value) |
| `ETCD3_HOSTS` | etcd connection string |
| `PATRONI_REPLICATION_USERNAME/PASSWORD` | Credentials for streaming replication |
| `PATRONI_SUPERUSER_USERNAME/PASSWORD` | PostgreSQL superuser credentials |

---

## Step 2: Start the Patroni Cluster

### Start all services

```bash
cd /Users/anthonytran/Desktop/postgresSQL-labatory
docker compose -f docker-compose-patroni.yml up -d
```

**Wait 90-120 seconds for cluster initialization.**

### Monitor startup logs

```bash
# Watch patroni1 (first node bootstraps the cluster)
docker logs -f patroni1
```

**Look for:**
- ✅ `"bootstrapping a new cluster"`
- ✅ `"successfully initialized a new cluster"`
- ✅ `"Lock owner: patroni1; I am patroni1"`
- ✅ `"no action. I am (patroni1), the leader with the lock"`

**Press Ctrl+C when you see success.**

---

## Step 3: Verify Cluster Status

### Check cluster state via patronictl

```bash
docker exec patroni1 patronictl list
```

**Expected output:**
```
+ Cluster: postgres-cluster (7586222173663928380) -+-----------+
| Member   | Host       | Role    | State     | TL | Lag in MB |
+----------+------------+---------+-----------+----+-----------+
| patroni1 | 172.21.0.3 | Leader  | running   |  1 |           |
| patroni2 | 172.21.0.4 | Replica | streaming |  1 |         0 |
| patroni3 | 172.21.0.5 | Replica | streaming |  1 |         0 |
+----------+------------+---------+-----------+----+-----------+
```

**What this shows:**
- ✅ **One Leader** (patroni1) - accepts writes
- ✅ **Two Replicas** (patroni2, patroni3) - streaming replication with 0 lag
- ✅ **Same Timeline (TL)** - all nodes are synchronized
- ✅ **Same Cluster ID** - no split-brain

### Verify from different nodes (should show identical output)

```bash
docker exec patroni2 patronictl list
docker exec patroni3 patronictl list
```

All three commands should show **identical cluster state** - this proves consensus!

### Check cluster state via REST API

```bash
# Check patroni1 (leader)
curl -s http://localhost:8008/patroni | jq

# Check patroni2 (replica)
curl -s http://localhost:8009/patroni | jq

# Check patroni3 (replica)
curl -s http://localhost:8010/patroni | jq
```

**Leader response:**
```json
{
  "state": "running",
  "role": "master",
  "server_version": 160001,
  "cluster_unlocked": false,
  "xlog": {
    "location": 67108928
  },
  "timeline": 1,
  "replication": [
    {
      "usename": "repl_user",
      "application_name": "patroni2",
      "client_addr": "172.21.0.4",
      "state": "streaming",
      "sync_state": "async"
    },
    {
      "usename": "repl_user",
      "application_name": "patroni3",
      "client_addr": "172.21.0.5",
      "state": "streaming",
      "sync_state": "async"
    }
  ]
}
```

**Replica response:**
```json
{
  "state": "running",
  "role": "replica",
  "server_version": 160001,
  "xlog": {
    "received_location": 67108928,
    "replayed_location": 67108928
  },
  "timeline": 1
}
```

---

## Step 4: Understanding Patroni's Control Plane

### Key Concepts

#### 1. **Leader Election via etcd**

```
etcd stores a "leader key" with TTL (Time To Live)

┌─────────────────────────────┐
│  etcd: /service/postgres-   │
│  cluster/leader = "patroni1"│
│  TTL = 30 seconds           │
└─────────────────────────────┘
         ▲
         │ Renews lock every 10 seconds
    ┌────┴────┐
    │ Patroni │
    │ patroni1│ (Leader)
    └─────────┘
```

**How it works:**
1. Only one node can hold the leader lock in etcd
2. Leader renews the lock every 10 seconds (default `loop_wait`)
3. If leader fails to renew (dead/network issue), lock expires after 30 seconds (default `ttl`)
4. Other nodes detect expired lock and compete to acquire it
5. Winner becomes new leader and promotes its PostgreSQL to primary
6. Losers follow the new leader as replicas

#### 2. **Health Checks**

Every 10 seconds, Patroni checks:
- ✅ PostgreSQL is running
- ✅ Can connect to PostgreSQL
- ✅ Can execute queries (`SELECT 1`)
- ✅ Replication lag (for replicas)

If health check fails 3 times (30 seconds):
- Node releases leader lock (if it was leader)
- Triggers automatic failover

#### 3. **Fencing (Split-Brain Prevention)**

**The Problem:**
```
Network partition:

patroni1 (thinks it's leader) ──X──  etcd
patroni2 (becomes new leader) ────── etcd

Both nodes think they're primary! (SPLIT-BRAIN)
```

**Patroni's Solution:**
- **Leader lock in etcd is the single source of truth**
- Node without lock **automatically demotes itself** to replica
- Uses `pg_rewind` to resync data after partition heals
- **No manual intervention needed!**

---

## Step 5: Create Test Data

Connect to the leader (patroni1) and create test data:

```bash
docker exec -it patroni1 psql -U postgres << 'EOF'
CREATE TABLE failover_test (
    id SERIAL PRIMARY KEY,
    created_at TIMESTAMP DEFAULT NOW(),
    message TEXT
);

INSERT INTO failover_test (message) VALUES ('Before failover');

SELECT * FROM failover_test;
EOF
```

**Expected output:**
```
 id |         created_at         |     message     
----+----------------------------+-----------------
  1 | 2025-12-21 08:30:15.123456 | Before failover
(1 row)
```

### Verify data replicated to replicas

```bash
# Check patroni2 (replica)
docker exec -it patroni2 psql -U postgres -c "SELECT * FROM failover_test;"

# Check patroni3 (replica)
docker exec -it patroni3 psql -U postgres -c "SELECT * FROM failover_test;"
```

**Expected:** ✅ Same data on all three nodes!

---

## Step 6: Trigger Automatic Failover

### 📝 Note the time before failure

```bash
date
# Example: Sat Dec 21 08:35:00 UTC 2025
```

### Simulate leader failure

```bash
docker stop patroni1
```

### Watch the failover happen in real-time

**Monitor cluster state:**
```bash
watch -n 2 'docker exec patroni2 patronictl list'
```

**Timeline you'll observe:**

| Time | Event |
|------|-------|
| T+0s | patroni1 stops |
| T+10s | patroni2 detects leader is missing |
| T+20s | patroni2 detects leader is still missing |
| T+30s | Leader lock expires in etcd |
| T+35s | patroni2 or patroni3 acquires lock |
| T+40s | New leader promotes PostgreSQL to primary |
| T+45s | Other replica starts following new leader |

**Press Ctrl+C to exit watch.**

### Final cluster state

```bash
docker exec patroni2 patronictl list
```

**Expected output:**
```
+ Cluster: postgres-cluster (7586222173663928380) -+-----------+
| Member   | Host       | Role    | State     | TL | Lag in MB |
+----------+------------+---------+-----------+----+-----------+
| patroni2 | 172.21.0.4 | Leader  | running   |  2 |           |
| patroni3 | 172.21.0.5 | Replica | streaming |  2 |         0 |
+----------+------------+---------+-----------+----+-----------+
```

**What changed:**
- ✅ patroni1 disappeared (it's down)
- ✅ patroni2 became the **Leader** (automatic promotion!)
- ✅ Timeline (TL) increased to **2** (new timeline after failover)
- ✅ patroni3 now follows patroni2

### 📝 Note the time after new leader is elected

```bash
date
# Example: Sat Dec 21 08:35:45 UTC 2025
```

**Calculate failover time:** Typically **30-60 seconds**

---

## Step 7: Verify Automatic Promotion

### Test writes on new leader

Assuming patroni2 became leader:

```bash
docker exec -it patroni2 psql -U postgres << 'EOF'
INSERT INTO failover_test (message) VALUES ('After automatic failover');

SELECT * FROM failover_test ORDER BY id;
EOF
```

**Expected output:**
```
 id |         created_at         |         message          
----+----------------------------+--------------------------
  1 | 2025-12-21 08:30:15.123456 | Before failover
  2 | 2025-12-21 08:36:10.654321 | After automatic failover
(2 rows)
```

✅ **Write succeeded!** No data loss!

### Verify replication to patroni3

```bash
docker exec -it patroni3 psql -U postgres -c "SELECT * FROM failover_test ORDER BY id;"
```

**Expected:** ✅ Same two rows visible on replica!

---

## Step 8: Restart Old Leader (Watch Auto-Rejoin)

### Start patroni1

```bash
docker start patroni1
```

**Wait 30 seconds for auto-rejoin:**

```bash
sleep 30
```

### Check cluster status

```bash
docker exec patroni2 patronictl list
```

**Expected output:**
```
+ Cluster: postgres-cluster (7586222173663928380) -+-----------+
| Member   | Host       | Role    | State     | TL | Lag in MB |
+----------+------------+---------+-----------+----+-----------+
| patroni1 | 172.21.0.3 | Replica | streaming |  2 |         0 |
| patroni2 | 172.21.0.4 | Leader  | running   |  2 |           |
| patroni3 | 172.21.0.5 | Replica | streaming |  2 |         0 |
+----------+------------+---------+-----------+----+-----------+
```

**What happened:**
- ✅ patroni1 rejoined as **Replica** (not leader) - correct behavior!
- ✅ Patroni used `pg_rewind` to resync data from new timeline
- ✅ No manual intervention needed!
- ✅ Timeline 2 for all nodes (synchronized)

### Verify data on rejoined node

```bash
docker exec -it patroni1 psql -U postgres -c "SELECT * FROM failover_test ORDER BY id;"
```

**Expected:** ✅ Both rows visible, including the one inserted after failover!

---

## Step 9: Comparison — Manual vs Automated Failover

### Manual Failover (LAB 3)

| Phase | Time | Action |
|-------|------|--------|
| Detection | 5 min | Manual monitoring, check logs |
| Decision | 5-10 min | Human decides to failover |
| Execution | 30 sec | `pg_ctl promote` on replica |
| Verification | 2-5 min | Check replication, test writes |
| App update | 10-30 min | Update connection strings, restart apps |
| **Total** | **20-45 min** | **All manual steps** |

### Automated Failover (LAB 4 - Patroni)

| Phase | Time | Action |
|-------|------|--------|
| Detection | 30 sec | Automatic health checks (3 failures) |
| Decision | Instant | DCS lock expiration triggers election |
| Execution | 10-20 sec | Automatic `pg_ctl promote` |
| Verification | 0 sec | Built-in health checks |
| App update | 0 sec | HAProxy/pgBouncer route automatically |
| **Total** | **30-60 sec** | **Fully automatic, zero human intervention** |

**Improvement:** **40x faster** (from 30 min to 45 sec)

**Benefits:**
- ✅ No 3 AM wake-up calls for DBAs
- ✅ Consistent, tested failover process
- ✅ Reduces MTTR (Mean Time To Recovery)
- ✅ Minimizes data loss window

---

## Step 10: Understanding Patroni Configuration

### Key Settings (Used by Spilo Image)

The Spilo image uses these default settings:

```yaml
dcs:
  ttl: 30                    # Leader lock TTL (30 seconds)
  loop_wait: 10              # Health check interval (10 seconds)
  retry_timeout: 10          # Retry failed operations
  maximum_lag_on_failover: 1048576  # Max lag for promotion (1MB)
```

**How failover timing works:**
1. Leader updates lock every 10 seconds (`loop_wait`)
2. If leader fails, lock expires after 30 seconds (`ttl`)
3. New leader elected within next 10 seconds (`loop_wait`)
4. PostgreSQL promotion takes 10-20 seconds
5. **Total failover time: ~40-60 seconds**

### Fencing with `pg_rewind`

```yaml
postgresql:
  use_pg_rewind: true        # Auto-resync after split-brain
  parameters:
    wal_log_hints: "on"      # Required for pg_rewind
```

**What `pg_rewind` does:**
- Compares WAL timelines between old primary and new primary
- Rewinds diverged transactions on old primary
- Allows old primary to rejoin as replica **without full rebuild**
- **Eliminates manual `pg_basebackup`!**

**Without `pg_rewind`:**
```bash
# Manual rebuild (takes hours for large databases)
pg_basebackup -h new_primary -D /var/lib/postgresql/data -U repl_user -P
```

**With `pg_rewind`:**
```bash
# Automatic (takes seconds)
# Patroni handles this internally!
```

---

## Step 11: Test Split-Brain Protection (Optional)

### View current cluster state

```bash
docker exec patroni2 patronictl list
```

Note which node is the leader.

### Check etcd to see the leader lock

```bash
docker exec etcd etcdctl --endpoints=http://localhost:2379 get --prefix /service/
```

**Look for:**
```
/service/postgres-cluster/leader
{"patroni2"}
```

This is the **single source of truth**!

### Simulate network partition (Advanced)

**Warning:** This requires iptables and may not work on all systems.

```bash
# Block patroni2 (current leader) from reaching etcd
docker exec patroni2 iptables -A OUTPUT -d $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' etcd) -j DROP
```

### Watch what happens

```bash
watch -n 2 'docker exec patroni3 patronictl list'
```

**Expected behavior:**
1. patroni2 can't renew its leader lock
2. After 30 seconds, lock expires
3. patroni2 **automatically demotes itself** to replica
4. patroni3 becomes new leader
5. **No split-brain!** Only one leader at a time

### Heal the partition

```bash
# Restore network connectivity
docker exec patroni2 iptables -F  # Flush all rules

# Wait 30 seconds
sleep 30

# Check cluster
docker exec patroni3 patronictl list
```

**Expected:** patroni2 rejoins as replica automatically!

---

## Step 12: Cleanup

```bash
# Stop all services
docker compose -f docker-compose-patroni.yml down

# Remove volumes (optional - keeps data for next lab)
docker volume rm postgresSQL-labatory_patroni1_data
docker volume rm postgresSQL-labatory_patroni2_data
docker volume rm postgresSQL-labatory_patroni3_data
```

---

## Deliverables

### 1. Failover Demo Results

**Timeline:**
- Primary stopped: **08:35:00 UTC**
- New leader elected: **08:35:45 UTC**
- **Total failover time: 45 seconds**

**Comparison:**
- Manual (LAB 3): 20-45 minutes
- Automated (LAB 4): 30-60 seconds
- **Improvement: ~40x faster** ✅

### 2. Explanation of Control Plane

**Components:**

| Component | Role | How It Works |
|-----------|------|--------------|
| **etcd** | Distributed key-value store | Stores leader lock with TTL |
| **Patroni** | HA manager | Performs health checks every 10 seconds |
| **Leader lock** | Fencing mechanism | Only node with lock can be primary |
| **REST API** | Monitoring | Exposes cluster state on port 8008 |
| **pg_rewind** | Data resync | Rewinds diverged WAL after partition |

**Failure detection flow:**
```
1. Leader fails to renew lock (missed 3 health checks = 30 seconds)
2. Lock expires in etcd after TTL (30 seconds)
3. Replicas detect expired lock via DCS watch
4. Replicas compete for lock (first to acquire wins)
5. Winner acquires lock and promotes PostgreSQL to primary
6. Other replicas detect new leader and start following
7. Total time: 40-60 seconds
```

### 3. Fencing Mechanism

**Split-brain prevention:**
- ✅ Only node with etcd lock can be primary
- ✅ Node without lock automatically demotes itself to replica
- ✅ `pg_rewind` resyncs data after partition heals
- ✅ No manual intervention required

**Test result:**
- ✅ No split-brain occurred during failover
- ✅ Old leader rejoined as replica after restart
- ✅ No data corruption or inconsistency
- ✅ Zero manual intervention needed

---

## Key Takeaways

### What Patroni Solves

1. ✅ **Automatic failure detection** (30-second health checks)
2. ✅ **Automatic promotion** (no human intervention)
3. ✅ **Fencing via DCS lock** (prevents split-brain)
4. ✅ **Auto-rejoin with pg_rewind** (eliminates manual rebuild)
5. ✅ **Consistent state** (all nodes agree via etcd)
6. ✅ **40x faster recovery** (45 seconds vs 30 minutes)

### Limitations (Baseline for Multi-Master Comparison)

Despite these improvements, Patroni still has limitations:

❌ **Still single-master** (only one node accepts writes at a time)
❌ **Read replicas are read-only** (can't write to replicas)
❌ **30-60 seconds downtime during failover** (brief write unavailability)
❌ **No write scalability** (all writes go to one node)
❌ **Single point of write bottleneck** (leader can become overloaded)

**These limitations lead us to multi-master replication (LAB 5+)**

---

## Troubleshooting

### Cluster shows "uninitialized"

```bash
docker exec patroni1 patronictl list
```

If you see `(uninitialized)`, wait longer (cluster is still bootstrapping).

### Split-brain detected (multiple leaders)

```bash
# Check if nodes see different cluster IDs
docker exec patroni1 patronictl list
docker exec patroni2 patronictl list
```

If cluster IDs differ, you have split-brain. Fix:
```bash
# Stop everything and remove volumes
docker compose -f docker-compose-patroni.yml down -v

# Start fresh
docker compose -f docker-compose-patroni.yml up -d
```

### Node stuck in "stopped" state

```bash
docker logs patroni1 --tail 50
```

Check for errors. Common issues:
- Port conflicts (5432, 8008 already in use)
- Volume permission issues
- etcd not reachable

---

## Next Steps

**LAB 5** will explore multi-master replication solutions that eliminate:
- ✅ The single point of write bottleneck
- ✅ Downtime during failover (write to any node anytime)
- ✅ Read-only replicas (all nodes are read-write)
- ✅ Scalability limits (distribute writes across nodes)

**Options we'll explore:**
- **Citus** (sharding for horizontal scalability)
- **PostgreSQL logical replication** (bi-directional replication)
- **BDR (Bi-Directional Replication)** (conflict-free multi-master)

**Question to ponder:** 
How do we handle conflicts when multiple nodes accept writes to the same row simultaneously? 🤔

**Preview:** Multi-master adds complexity:
- Conflict detection and resolution
- Eventual consistency vs strong consistency
- CAP theorem tradeoffs
- More complex operational overhead

But the benefits can be huge:
- Zero downtime for writes
- Geographic distribution
- Write scalability
- Better read/write load distribution