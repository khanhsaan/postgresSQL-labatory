# LAB 3 — Failure Simulation (Reality Check)

**Goal:** See what *actually* happens during failure and understand why automation is needed.

By the end of Lab 3, you will:
- Simulate a primary failure
- Understand replica limitations (read-only)
- Manually promote a standby to primary
- Document the failure timeline and downtime
- Realize the need for automatic failover

---

## Prerequisites

Complete LAB 2 first. You should have:
- ✅ pg_node1 running as primary
- ✅ pg_node2 running as standby (streaming from pg_node1)
- ✅ Active replication connection

Verify replication is working:
```bash
psql -h localhost -p 5433 -U postgres -d labdb -c "SELECT * FROM pg_stat_replication;"
```

Expected: 1 row showing pg_node2 streaming.

---

## Step 1: Verify Current State

### Check primary status (pg_node1)
```bash
psql -h localhost -p 5433 -U postgres -d labdb -c "SELECT pg_is_in_recovery();"
```

Expected: `f` (false - it's a primary)

### Check standby status (pg_node2)
```bash
psql -h localhost -p 5434 -U postgres -d labdb -c "SELECT pg_is_in_recovery();"
```

Expected: `t` (true - it's a standby)

### Create test data on primary
```bash
psql -h localhost -p 5433 -U postgres -d labdb << EOF
CREATE TABLE IF NOT EXISTS failure_test(
    id SERIAL PRIMARY KEY,
    event TEXT,
    created_at TIMESTAMP DEFAULT now()
);

INSERT INTO failure_test(event) VALUES('Before failure');
EOF
```

### Verify data replicated to standby
```bash
psql -h localhost -p 5434 -U postgres -d labdb -c "SELECT * FROM failure_test;"
```

Expected: You should see the row 'Before failure'.

---

## Step 2: Simulate Primary Failure

**📝 Note the time before stopping:**
```bash
date
```

**Stop pg_node1 (simulating crash/network failure):**
```bash
docker stop pg_node1
```

**📝 Note the time after stopping:**
```bash
date
```

### What just happened?

- ❌ Primary (pg_node1) is down
- ✅ Standby (pg_node2) is still running
- ⚠️ Replication connection is broken
- ⚠️ Your application can't write anymore

---

## Step 3: Try to Write to Replica (This Will Fail)

Try inserting data on pg_node2:
```bash
psql -h localhost -p 5434 -U postgres -d labdb << EOF
INSERT INTO failure_test(event) VALUES('During failure - attempt 1');
EOF
```

**Expected error:**
```
ERROR:  cannot execute INSERT in a read-only transaction
```

### Why?

- Standbys are **read-only** by design
- They only replay WAL from the primary
- They cannot accept write operations
- Your application is effectively **down for writes**

---

## Step 4: Observe Application Behavior

Simulate what a real application would experience:

### Attempt to connect to primary (will fail)
```bash
psql -h localhost -p 5433 -U postgres -d labdb -c "SELECT 1;"
```

**Expected error:**
```
psql: error: connection to server at "localhost" (127.0.0.1), port 5433 failed
```

### Read from standby (still works)
```bash
psql -h localhost -p 5434 -U postgres -d labdb -c "SELECT * FROM failure_test;"
```

**Expected:** ✅ Reads work! You can still see existing data.

### Document the impact

**What's broken:**
- ❌ All write operations (INSERT, UPDATE, DELETE)
- ❌ Connection to primary (port 5433)
- ❌ Applications expecting read-write access

**What still works:**
- ✅ Read operations on standby (port 5434)
- ✅ Existing data is intact
- ✅ Standby is healthy (but useless for writes)

---

## Step 5: Check Standby Status After Primary Failure

```bash
docker logs pg_node2 --tail 20
```

**Look for messages like:**
```
LOG:  connection to primary failed
LOG:  waiting for WAL to become available
LOG:  could not connect to the primary server
```

Check replication lag (this will show no connection):
```bash
psql -h localhost -p 5434 -U postgres -d labdb -c "SELECT * FROM pg_stat_wal_receiver;"
```

Expected: 0 rows (no active replication connection)

---

## Step 6: Manual Promotion (Failover)

**📝 Note the time before promotion:**
```bash
date
```

### Promote pg_node2 to primary

Promote the standby as PostgreSQL user:
```bash
docker exec -u postgres pg_node2 pg_ctl promote -D /var/lib/postgresql/data
```

**Expected output:**
```
waiting for server to promote.... done
server promoted
```

**📝 Note the time after promotion:**
```bash
date
```

### What just happened?

- PostgreSQL removed `standby.signal` file
- pg_node2 exited recovery mode
- pg_node2 is now a **read-write primary** ✅
- pg_node2 can accept write operations

---

## Step 7: Verify Promotion Worked

### Check pg_node2 is now a primary
```bash
psql -h localhost -p 5434 -U postgres -d labdb -c "SELECT pg_is_in_recovery();"
```

Expected: `f` (false - it's now a primary!)

### Try writing again (this should work now)
```bash
psql -h localhost -p 5434 -U postgres -d labdb << EOF
INSERT INTO failure_test(event) VALUES('After promotion');
SELECT * FROM failure_test;
EOF
```

**Expected:** ✅ Write succeeds! You should see all 3 rows:
```
 id |         event          |         created_at         
----+------------------------+----------------------------
  1 | Before failure         | 2025-12-21 ...
  2 | After promotion        | 2025-12-21 ...
```

---

## Step 8: Document Your Failure Timeline

Fill in the actual times from your notes:

| Event | Time | Duration |
|-------|------|----------|
| Primary healthy | _______ | - |
| Primary stopped | _______ | - |
| Promotion started | _______ | Downtime: _____ minutes |
| Promotion completed | _______ | - |
| Writes restored | _______ | Total: _____ minutes |

### Calculate downtime

**Total write downtime** = Time from "Primary stopped" to "Writes restored"

**Manual steps required:**
1. Detect the failure (manual)
2. Decide to failover (manual)
3. Run `pg_ctl promote` (manual)
4. Update application connection string (manual)

---

## Step 9: Update Application Connection (Simulated)

In a real scenario, you'd need to:

**Before failure:**
```python
# Application config
DATABASE_URL = "postgresql://postgres:postgres@localhost:5433/labdb"
```

**After manual failover:**
```python
# Application config (MANUALLY UPDATED)
DATABASE_URL = "postgresql://postgres:postgres@localhost:5434/labdb"
```

**Problems:**
- ❌ Manual process
- ❌ Requires code/config change
- ❌ Requires application restart
- ❌ Prone to human error
- ❌ Slow (minutes to hours)

---

## Step 10: Reality Check — What Happens to pg_node1?

### Option A: Leave it down (simplest)

pg_node1 is stopped and stays down. pg_node2 is now the only primary.

**Problem:** No high availability anymore (no standby).

### Option B: Rebuild pg_node1 as a new standby

**This is what you'd do in production:**

```bash
# Stop pg_node1 (if not already stopped)
docker stop pg_node1
docker rm pg_node1

# Remove old primary data
docker volume rm postgresSQL-labatory_pg_node1_data

# Rebuild from new primary (pg_node2)
docker run --rm -it \
  --network postgresSQL-labatory_default \
  -v postgresSQL-labatory_pg_node1_data:/var/lib/postgresql/data \
  postgres:16 \
  pg_basebackup \
    -h pg_node2 \
    -U repl_user \
    -D /var/lib/postgresql/data \
    -Fp -Xs -P -R

# Start pg_node1 as standby
docker compose up -d pg_node1
```

**Result:** Now pg_node1 is a standby streaming from pg_node2!

**Problems with this approach:**
- ❌ Completely manual
- ❌ Requires understanding of replication
- ❌ Takes 15-30 minutes for large databases
- ❌ Human error risk (wrong commands)

---

## Step 11: Clean Up (Optional)

If you want to restore the original setup (pg_node1 as primary):

```bash
# Stop everything
docker compose down

# Remove all volumes
docker volume rm postgresSQL-labatory_pg_node1_data
docker volume rm postgresSQL-labatory_pg_node2_data

# Start fresh
docker compose up -d

# Redo LAB 2 setup
```

---

## Deliverables

### 1. Failure Timeline

Document your actual times:
- Detection time: _______
- Decision time: _______
- Promotion time: _______
- **Total downtime: _______**

### 2. Observed Downtime

**Write downtime:** Time when applications couldn't write data

**Read downtime:** 0 minutes (reads worked the whole time on standby)

### 3. Manual vs Automatic

| Task | Manual? | Time Required |
|------|---------|---------------|
| Detect primary failure | ✅ Manual | ~5 minutes |
| Decide to failover | ✅ Manual | ~5-10 minutes |
| Promote standby | ✅ Manual | ~30 seconds |
| Update app connection | ✅ Manual | ~10-30 minutes |
| **Total** | **All manual** | **~20-45 minutes** |

### 4. Key Observations

**What worked:**
- ✅ Standby had all the data
- ✅ Promotion was fast (30 seconds)
- ✅ No data loss

**What was painful:**
- ❌ Everything was manual
- ❌ Required SSH access + PostgreSQL knowledge
- ❌ Application downtime during failover
- ❌ Application config needed manual update
- ❌ Rebuilding old primary was tedious

---

## Key Takeaways

### The Reality of Manual Failover

1. **Detection is slow** - How do you know the primary is down? Monitoring? Users complaining?

2. **Decision-making takes time** - Is it really down? Should we failover? Who has authority?

3. **Execution requires expertise** - Not everyone knows `pg_ctl promote`

4. **Application updates are manual** - Connection strings, DNS, load balancers

5. **Downtime is inevitable** - 20-45 minutes is optimistic (can be hours)

### Why Automation is Critical

Without automation:
- ❌ Mean Time To Recovery (MTTR): 20-45 minutes (or hours)
- ❌ Requires on-call engineers 24/7
- ❌ Prone to human error
- ❌ Inconsistent process

With automation (Patroni - coming in LAB 4):
- ✅ Mean Time To Recovery (MTTR): 30-60 seconds
- ✅ Works at 3 AM without human intervention
- ✅ Consistent, tested process
- ✅ Automatic application failover

---

## Next Step: LAB 4

In LAB 4, you'll install **Patroni** to automate:
- ✅ Failure detection (health checks every 10 seconds)
- ✅ Automatic promotion (no human intervention)
- ✅ Application failover (via HAProxy/VIP)
- ✅ Standby rebuild (automatic re-sync)

**Downtime will drop from 20-45 minutes to 30-60 seconds!** 🚀

---

## Appendix: Common Issues

### "Connection refused" when connecting to pg_node2 after promotion

**Cause:** PostgreSQL might have restarted during promotion.

**Solution:** Wait 10 seconds and try again.

### "Cannot execute INSERT" still showing after promotion

**Cause:** Still connected to old session or promotion didn't complete.

**Solution:**
```bash
# Check if promotion completed
docker logs pg_node2 --tail 20

# Force reconnect
psql -h localhost -p 5434 -U postgres -d labdb -c "SELECT pg_is_in_recovery();"
```

Expected: `f` (false)

### Data missing after failover

**Cause:** Asynchronous replication - some WAL might not have been replayed.

**Solution:** This is expected with async replication. Use synchronous replication for zero data loss (covered in advanced labs).