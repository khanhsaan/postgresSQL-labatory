# LAB 5 — Backup & Recovery (Disaster Recovery)

**Goal:** Understand the critical difference between High Availability (HA) and Disaster Recovery (DR), and implement a comprehensive backup strategy using pgBackRest.

By the end of Lab 5, you will:
- Understand why HA ≠ DR (replication copies corruption!)
- Configure pgBackRest for automated backups
- Enable WAL archiving for near-zero RPO
- Perform full, incremental, and differential backups
- Execute Point-in-Time Recovery (PITR)
- Calculate and optimize RPO/RTO
- Test disaster recovery scenarios

---

## Why Backups Matter (Even With HA)

### The Critical Misunderstanding

**❌ Common mistake:**
> "We have Patroni with streaming replication. We don't need backups."

**✅ Reality:**
```
Primary: DELETE FROM customers WHERE 1=1;  -- Oops!
         ↓ (replicates in <1 second)
Replica: All data gone!
Replica: All data gone!
Replica: All data gone!
```

**HA replicates disasters instantly!**

### HA vs DR: What's the Difference?

| Scenario | HA (Patroni) Protects? | DR (Backups) Protects? |
|----------|------------------------|------------------------|
| Server hardware failure | ✅ Yes (30-60 sec failover) | ✅ Yes (but slower: minutes-hours) |
| Process crash | ✅ Yes (automatic restart) | ✅ Yes (restore from backup) |
| Accidental `DELETE` | ❌ **Replicates instantly!** | ✅ Yes (PITR to before DELETE) |
| `DROP TABLE` | ❌ **Replicates instantly!** | ✅ Yes (restore from backup) |
| Data corruption | ❌ **Replicates instantly!** | ✅ Yes (restore clean backup) |
| Ransomware encryption | ❌ **Replicates instantly!** | ✅ Yes (restore pre-attack backup) |
| Datacenter fire | ❌ All nodes destroyed | ✅ Yes (off-site backups survive) |
| Malicious admin | ❌ **Replicates instantly!** | ✅ Yes (immutable backups) |

**Key insight:** HA provides **availability**, not **recoverability**.

---

## RPO and RTO Explained

### Recovery Point Objective (RPO)

**RPO = Maximum acceptable data loss**

```
Last Backup              Disaster
     ↓                      ↓
─────●──────────────────────X─────▶ Time
     └──────────────────────┘
            RPO Window
     (Data in this window is lost)
```

**Example RPO targets:**

| Backup Strategy | RPO | Data Loss Risk |
|-----------------|-----|----------------|
| Daily full backup only | 24 hours | **Lose 1 day of transactions** |
| Hourly incremental | 1 hour | Lose 1 hour of transactions |
| WAL archiving (every 60 sec) | 1 minute | **Lose <1 min of transactions** |
| Synchronous replication | 0 seconds | **No data loss** (but not a backup!) |

### Recovery Time Objective (RTO)

**RTO = Maximum acceptable downtime**

```
Disaster Detected    System Restored
        ↓                   ↓
────────X═══════════════════●─────▶ Time
        └───────────────────┘
              RTO Window
        (Application is down)
```

**Example RTO targets:**

| Recovery Method | RTO | Downtime Impact |
|-----------------|-----|-----------------|
| Manual failover (LAB 3) | 20-45 minutes | Significant revenue loss |
| Patroni failover (LAB 4) | 30-60 seconds | Minimal impact |
| Restore from backup (LAB 5) | 10 minutes - 24 hours | Depends on DB size |

**Trade-off:** Lower RPO = Higher cost (more frequent backups, more storage)

---

## Architecture Overview

### What We're Building

```
┌────────────────────────────────────────────────────────────┐
│                   Patroni HA Cluster                       │
│  ┌──────────┐      ┌──────────┐      ┌──────────┐        │
│  │patroni1  │──────▶│patroni2  │      │patroni3  │        │
│  │(Leader)  │      │(Replica) │      │(Replica) │        │
│  └────┬─────┘      └──────────┘      └──────────┘        │
│       │                                                    │
│       │ archive_command (every 60s or 16MB)               │
│       ▼                                                    │
│  ┌──────────────────────────────────────────────┐        │
│  │         pgBackRest Repository                │        │
│  │  ┌────────────────────────────────────────┐ │        │
│  │  │ Full Backups (weekly)                  │ │        │
│  │  │  └─ backup-20251221-020000F (23.5MB)   │ │        │
│  │  │                                         │ │        │
│  │  │ Incremental Backups (daily)            │ │        │
│  │  │  └─ backup-20251222-020000I (45KB)     │ │        │
│  │  │                                         │ │        │
│  │  │ WAL Archives (continuous)              │ │        │
│  │  │  └─ 000000010000000000000001           │ │        │
│  │  │  └─ 000000010000000000000002           │ │        │
│  │  │  └─ 000000010000000000000003           │ │        │
│  │  └────────────────────────────────────────┘ │        │
│  └──────────────────────────────────────────────┘        │
└────────────────────────────────────────────────────────────┘
```

### Components

| Component | Purpose | Port |
|-----------|---------|------|
| **pgBackRest** | Backup and restore tool | - |
| **Patroni Cluster** | Source database (from LAB 4) | 5432, 8008 |
| **WAL Archives** | Transaction logs for PITR | - |
| **Backup Repository** | Stores backups (Docker volume) | - |

---

## Prerequisites

### Knowledge Requirements

- ✅ Completed LAB 4 (Patroni HA cluster)
- ✅ Understand streaming replication
- ✅ Basic understanding of WAL (Write-Ahead Logging)

### System Requirements

```bash
# Verify Docker resources
docker system df

# Need at least:
# - 4GB RAM
# - 10GB disk space (for backups)
```

---

## Step 1: Create Lab Directory Structure

```bash
cd /Users/anthonytran/Desktop/postgresSQL-labatory

# Create lab5 directories
mkdir -p lab5_env/{backups,archives,config,restore,scripts}

# Verify structure
tree lab5_env
```

**Expected:**
```
lab5_env/
├── backups/    # Backup repository (mounted to pgBackRest)
├── archives/   # WAL archive location
├── config/     # pgBackRest configuration
├── restore/    # Temporary restore location
└── scripts/    # Backup/restore scripts
```

---

## Step 2: Create pgBackRest Configuration

pgBackRest needs a configuration file to know where to store backups and how to connect to PostgreSQL.

````ini
// filepath: /Users/anthonytran/Desktop/postgresSQL-labatory/lab5_env/config/pgbackrest.conf
[global]
# Repository settings
repo1-path=/backup
repo1-retention-full=2
repo1-retention-diff=4
repo1-retention-archive=7
log-level-console=info
log-level-file=debug
log-path=/var/log/pgbackrest
lock-path=/tmp/pgbackrest

# Process settings
process-max=2
archive-async=y
spool-path=/var/spool/pgbackrest

[main]
# PostgreSQL cluster settings
pg1-path=/home/postgres/pgdata/data
pg1-host=patroni1
pg1-port=5432
pg1-user=postgres
````

**Configuration explained:**
- `repo1-path`: Where backups are stored
- `repo1-retention-*`: How many backups to keep (full: 2, differential: 4, archive: 7 days)
- `archive-async=y`: Asynchronous WAL archiving for better performance
- `process-max=2`: Parallel backup processes
- `pg1-*`: Connection details to PostgreSQL primary

---

## Step 3: Create Docker Compose with pgBackRest

Create `docker-compose-backup.yml` that extends our Patroni setup with backup capabilities:

```yaml
# filepath: /Users/anthonytran/Desktop/postgresSQL-labatory/docker-compose-backup.yml
version: '3.8'

networks:
  patroni_net:
    driver: bridge

volumes:
  etcd-data:
  patroni1-data:
  patroni2-data:
  patroni3-data:
  pgbackrest-repo:  # Shared backup repository

services:
  # etcd for distributed consensus
  etcd:
    image: quay.io/coreos/etcd:v3.5.9
    container_name: etcd
    environment:
      ETCD_NAME: etcd
      ETCD_INITIAL_CLUSTER: etcd=http://etcd:2380
      ETCD_INITIAL_CLUSTER_STATE: new
      ETCD_INITIAL_CLUSTER_TOKEN: etcd-cluster
      ETCD_INITIAL_ADVERTISE_PEER_URLS: http://etcd:2380
      ETCD_ADVERTISE_CLIENT_URLS: http://etcd:2379
      ETCD_LISTEN_PEER_URLS: http://0.0.0.0:2380
      ETCD_LISTEN_CLIENT_URLS: http://0.0.0.0:2379
    ports:
      - "2379:2379"
    networks:
      - patroni_net
    volumes:
      - etcd-data:/etcd-data

  # Patroni Node 1 (Primary)
  patroni1:
    image: ghcr.io/zalando/spilo-16:3.2-p3
    container_name: patroni1
    hostname: patroni1
    environment:
      SCOPE: postgres-cluster
      PGVERSION: "16"
      ETCD3_HOSTS: "etcd:2379"
      PATRONI_SUPERUSER_USERNAME: postgres
      PATRONI_SUPERUSER_PASSWORD: postgres
      PATRONI_REPLICATION_USERNAME: replicator
      PATRONI_REPLICATION_PASSWORD: replpass
      PATRONI_RESTAPI_LISTEN: "0.0.0.0:8008"
      PATRONI_RESTAPI_CONNECT_ADDRESS: "patroni1:8008"
      PATRONI_POSTGRESQL_LISTEN: "0.0.0.0:5432"
      PATRONI_POSTGRESQL_CONNECT_ADDRESS: "patroni1:5432"
      PATRONI_NAME: patroni1
      # WAL Archiving Configuration
      PATRONI_POSTGRESQL_PARAMETERS_ARCHIVE_MODE: "on"
      PATRONI_POSTGRESQL_PARAMETERS_ARCHIVE_COMMAND: "pgbackrest --stanza=main archive-push %p"
      PATRONI_POSTGRESQL_PARAMETERS_ARCHIVE_TIMEOUT: "60"
      PATRONI_POSTGRESQL_PARAMETERS_WAL_LEVEL: "replica"
      PATRONI_POSTGRESQL_PARAMETERS_MAX_WAL_SENDERS: "10"
    ports:
      - "5433:5432"
      - "8008:8008"
    networks:
      - patroni_net
    volumes:
      - patroni1-data:/home/postgres/pgdata
      - pgbackrest-repo:/backup
      - ./lab5_env/config/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro
    depends_on:
      - etcd

  # Patroni Node 2 (Replica)
  patroni2:
    image: ghcr.io/zalando/spilo-16:3.2-p3
    container_name: patroni2
    hostname: patroni2
    environment:
      SCOPE: postgres-cluster
      PGVERSION: "16"
      ETCD3_HOSTS: "etcd:2379"
      PATRONI_SUPERUSER_USERNAME: postgres
      PATRONI_SUPERUSER_PASSWORD: postgres
      PATRONI_REPLICATION_USERNAME: replicator
      PATRONI_REPLICATION_PASSWORD: replpass
      PATRONI_RESTAPI_LISTEN: "0.0.0.0:8008"
      PATRONI_RESTAPI_CONNECT_ADDRESS: "patroni2:8008"
      PATRONI_POSTGRESQL_LISTEN: "0.0.0.0:5432"
      PATRONI_POSTGRESQL_CONNECT_ADDRESS: "patroni2:5432"
      PATRONI_NAME: patroni2
    ports:
      - "5434:5432"
      - "8009:8008"
    networks:
      - patroni_net
    volumes:
      - patroni2-data:/home/postgres/pgdata
      - pgbackrest-repo:/backup
      - ./lab5_env/config/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro
    depends_on:
      - etcd

  # Patroni Node 3 (Replica)
  patroni3:
    image: ghcr.io/zalando/spilo-16:3.2-p3
    container_name: patroni3
    hostname: patroni3
    environment:
      SCOPE: postgres-cluster
      PGVERSION: "16"
      ETCD3_HOSTS: "etcd:2379"
      PATRONI_SUPERUSER_USERNAME: postgres
      PATRONI_SUPERUSER_PASSWORD: postgres
      PATRONI_REPLICATION_USERNAME: replicator
      PATRONI_REPLICATION_PASSWORD: replpass
      PATRONI_RESTAPI_LISTEN: "0.0.0.0:8008"
      PATRONI_RESTAPI_CONNECT_ADDRESS: "patroni3:8008"
      PATRONI_POSTGRESQL_LISTEN: "0.0.0.0:5432"
      PATRONI_POSTGRESQL_CONNECT_ADDRESS: "patroni3:5432"
      PATRONI_NAME: patroni3
    ports:
      - "5435:5432"
      - "8010:8008"
    networks:
      - patroni_net
    volumes:
      - patroni3-data:/home/postgres/pgdata
      - pgbackrest-repo:/backup
      - ./lab5_env/config/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro
    depends_on:
      - etcd

  # pgBackRest dedicated backup server
  pgbackrest:
    image: pgbackrest/pgbackrest:latest
    container_name: pgbackrest
    hostname: pgbackrest
    networks:
      - patroni_net
    volumes:
      - pgbackrest-repo:/backup
      - ./lab5_env/config/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro
    command: tail -f /dev/null  # Keep container running
```

**Key additions:**
- `pgbackrest-repo` volume: Shared backup storage
- `PATRONI_POSTGRESQL_PARAMETERS_ARCHIVE_*`: WAL archiving configuration
- `pgbackrest` service: Dedicated backup server
- Mounted `pgbackrest.conf` in all nodes

---

## Step 4: Start the Environment

```bash
# Clean up any existing environment
docker compose -f docker-compose-backup.yml down -v

# Start etcd first
docker compose -f docker-compose-backup.yml up -d etcd
sleep 5

# Start patroni nodes sequentially
docker compose -f docker-compose-backup.yml up -d patroni1
sleep 10

docker compose -f docker-compose-backup.yml up -d patroni2 patroni3
sleep 10

# Start pgbackrest server
docker compose -f docker-compose-backup.yml up -d pgbackrest

# Check cluster status
docker exec -it patroni1 patronictl -c /home/postgres/postgres.yml list
```

**Expected output:**
```
+ Cluster: postgres-cluster --+---------+---------+----+-----------+
| Member    | Host      | Role    | State   | TL | Lag in MB |
+-----------+-----------+---------+---------+----+-----------+
| patroni1  | patroni1  | Leader  | running |  1 |           |
| patroni2  | patroni2  | Replica | running |  1 |         0 |
| patroni3  | patroni3  | Replica | running |  1 |         0 |
+-----------+-----------+---------+---------+----+-----------+
```

---

## Step 5: Configure WAL Archiving

Verify WAL archiving is enabled on the primary:

```bash
# Check archive_mode is ON
docker exec -it patroni1 psql -U postgres -c "SHOW archive_mode;"
docker exec -it patroni1 psql -U postgres -c "SHOW archive_command;"
docker exec -it patroni1 psql -U postgres -c "SHOW wal_level;"

# Expected output:
# archive_mode      | on
# archive_command   | pgbackrest --stanza=main archive-push %p
# wal_level         | replica
```

**Why WAL archiving matters:**
- **RPO (Recovery Point Objective):** Near-zero data loss
- **PITR (Point-in-Time Recovery):** Restore to any second
- WAL files contain all database changes between backups

---

## Step 6: Initialize pgBackRest Stanza

A "stanza" is pgBackRest's term for a backup configuration set.

```bash
# Initialize the stanza
docker exec -it pgbackrest pgbackrest --stanza=main stanza-create

# Check stanza status
docker exec -it pgbackrest pgbackrest --stanza=main check

# Expected output:
# P00   INFO: check command begin 2.49: ...
# P00   INFO: check repo1 configuration (primary)
# P00   INFO: check repo1 archive for WAL (primary)
# P00   INFO: WAL segment ... successfully archived to ...
# P00   INFO: check command end: completed successfully
```

**What happened:**
- pgBackRest verified it can connect to PostgreSQL
- Verified WAL archiving works
- Created backup repository structure in `/backup`

---

## Step 7: Create Test Data

Create meaningful test data to demonstrate backup scenarios:

```bash
docker exec -it patroni1 psql -U postgres << 'EOF'
-- Create test database
CREATE DATABASE sales_db;
\c sales_db

-- Create table with timestamp for PITR testing
CREATE TABLE orders (
    order_id SERIAL PRIMARY KEY,
    customer_name TEXT NOT NULL,
    amount NUMERIC(10,2) NOT NULL,
    order_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert initial data
INSERT INTO orders (customer_name, amount)
SELECT 
    'Customer_' || i,
    (random() * 1000)::NUMERIC(10,2)
FROM generate_series(1, 1000) i;

-- Check data
SELECT COUNT(*), SUM(amount), MIN(order_time), MAX(order_time) FROM orders;

-- Note the current time for PITR testing
SELECT NOW() AS "Baseline Time";
EOF
```

**Record this baseline time!** You'll need it for PITR testing.

Example output:
```
 count | sum      | min                        | max
-------+----------+----------------------------+----------------------------
  1000 | 502341.89| 2024-01-15 10:30:15.123456 | 2024-01-15 10:30:15.234567

     Baseline Time
------------------------
 2024-01-15 10:30:15.5
```

---

## Step 8: Perform Full Backup

A full backup captures the entire database.

```bash
# Take full backup
docker exec -it pgbackrest pgbackrest --stanza=main --type=full backup

# List backups
docker exec -it pgbackrest pgbackrest --stanza=main info
```

**Expected output:**
```
stanza: main
    status: ok
    cipher: none

    db (current)
        wal archive min/max (16): 000000010000000000000001/000000010000000000000003

        full backup: 20240115-103045F
            timestamp start/stop: 2024-01-15 10:30:45 / 2024-01-15 10:31:20
            wal start/stop: 000000010000000000000002 / 000000010000000000000002
            database size: 24.5MB, database backup size: 24.5MB
            repo1: backup size: 3.1MB
```

**Backup types explained:**
- **Full backup:** Complete database copy (larger, but faster to restore)
- **Differential backup:** Changes since last full backup
- **Incremental backup:** Changes since last backup (any type)

**Performance metrics:**
- Database size: 24.5MB
- Backup size: 3.1MB (87% compression!)
- Time: ~35 seconds

---

## Step 9: Add More Data and Take Incremental Backup

```bash
# Add more orders
docker exec -it patroni1 psql -U postgres -d sales_db << 'EOF'
INSERT INTO orders (customer_name, amount)
SELECT 
    'Customer_' || i,
    (random() * 1000)::NUMERIC(10,2)
FROM generate_series(1001, 2000) i;

SELECT COUNT(*), SUM(amount) FROM orders;
SELECT NOW() AS "After Second Batch";
EOF

# Take incremental backup
docker exec -it pgbackrest pgbackrest --stanza=main --type=incr backup

# List backups again
docker exec -it pgbackrest pgbackrest --stanza=main info
```

**New output shows:**
```
    full backup: 20240115-103045F
        ...
    
    incr backup: 20240115-103045F_20240115-103515I
        timestamp start/stop: 2024-01-15 10:35:15 / 2024-01-15 10:35:25
        wal start/stop: 000000010000000000000004 / 000000010000000000000004
        database size: 26.1MB, database backup size: 1.6MB
        repo1: backup size: 256KB
        backup reference list: 20240115-103045F
```

**Notice:**
- Incremental backup only: 256KB (vs 3.1MB full)
- References the full backup: `20240115-103045F`
- Much faster: ~10 seconds

---

## Step 10: Simulate Disaster (Accidental DELETE)

Now simulate a common disaster: accidental data deletion.

```bash
# Check current data
docker exec -it patroni1 psql -U postgres -d sales_db -c "SELECT COUNT(*) FROM orders;"
# Output: 2000

# Note the time BEFORE disaster
docker exec -it patroni1 psql -U postgres -d sales_db -c "SELECT NOW() AS \"Before Disaster\";"
# Output: 2024-01-15 10:40:30.123456

# Wait 5 seconds (to create clear time boundary)
sleep 5

# DISASTER: Accidental DELETE without WHERE clause!
docker exec -it patroni1 psql -U postgres -d sales_db << 'EOF'
DELETE FROM orders;  -- Oops! Forgot WHERE clause!
SELECT NOW() AS "Disaster Time";
SELECT COUNT(*) FROM orders;
EOF

# Output:
#      Disaster Time
# ------------------------
#  2024-01-15 10:40:35.5
# 
#  count
# -------
#      0
```

**Panic mode activated!** 😱

Check replicas - disaster replicated instantly:
```bash
docker exec -it patroni2 psql -U postgres -d sales_db -c "SELECT COUNT(*) FROM orders;"
# Output: 0 (disaster replicated!)

docker exec -it patroni3 psql -U postgres -d sales_db -c "SELECT COUNT(*) FROM orders;"
# Output: 0 (disaster replicated!)
```

**This is why HA ≠ DR!**

---

## Step 11: Point-in-Time Recovery (PITR)

Restore database to **before** the DELETE command using PITR.

### Step 11.1: Stop Patroni Cluster

```bash
# Stop all patroni nodes (keeps data)
docker compose -f docker-compose-backup.yml stop patroni1 patroni2 patroni3
```

### Step 11.2: Restore to Point-in-Time

```bash
# Restore to 5 seconds before disaster (use your "Before Disaster" timestamp)
docker exec -it pgbackrest pgbackrest --stanza=main --delta \
    --type=time "--target=2024-01-15 10:40:30" \
    --target-action=promote \
    restore

# Expected output:
# P00   INFO: restore command begin 2.49: ...
# P00   INFO: restore backup set 20240115-103045F_20240115-103515I
# P00   INFO: write updated /home/postgres/pgdata/data/postgresql.auto.conf
# P00   INFO: restore global/pg_control (performed last to ensure aborted restores cannot be started)
# P00   INFO: restore command end: completed successfully
```

**PITR magic:**
1. pgBackRest restores last incremental backup
2. Applies WAL archives up to target time
3. Stops **before** the DELETE command
4. Promotes database to ready state

### Step 11.3: Start Primary and Verify Recovery

```bash
# Start patroni1 only (as standalone, not in cluster yet)
docker compose -f docker-compose-backup.yml start patroni1
sleep 10

# Check recovered data
docker exec -it patroni1 psql -U postgres -d sales_db << 'EOF'
SELECT COUNT(*) FROM orders;
SELECT MAX(order_time) AS "Latest Order Time";
EOF

# Expected output:
#  count
# -------
#   2000
# 
#  Latest Order Time
# ----------------------------
#  2024-01-15 10:35:20.456789
```

**Success!** Data restored to before DELETE! 🎉

---

## Step 12: Rebuild Replicas from Restored Primary

The replicas still have corrupted data. Rebuild them using `pg_rewind` or fresh `pg_basebackup`.

```bash
# Stop and remove replica data
docker compose -f docker-compose-backup.yml stop patroni2 patroni3
docker volume rm postgresSQL-labatory_patroni2-data postgresSQL-labatory_patroni3-data

# Recreate replicas
docker compose -f docker-compose-backup.yml up -d patroni2 patroni3
sleep 20

# Check cluster status
docker exec -it patroni1 patronictl -c /home/postgres/postgres.yml list

# Verify data on replica
docker exec -it patroni2 psql -U postgres -d sales_db -c "SELECT COUNT(*) FROM orders;"
# Output: 2000 (restored data replicated!)
```

**Recovery complete!**

**RPO achieved:** ~5 seconds (time between last WAL archive and disaster)
**RTO achieved:** ~10 minutes (stop cluster + restore + rebuild replicas)

---

## Step 13: Full Disaster Recovery (Datacenter Loss)

Simulate complete cluster loss (fire, flood, ransomware, etc.).

### Step 13.1: Destroy Everything

```bash
# Nuclear option: delete all cluster data (simulate datacenter loss)
docker compose -f docker-compose-backup.yml down -v

# Verify volumes deleted
docker volume ls | grep patroni
# Output: (empty - all data gone!)
```

**But backups survived!** (They're in `pgbackrest-repo` volume)

### Step 13.2: Restore from Backup to New Cluster

```bash
# Recreate cluster infrastructure
docker compose -f docker-compose-backup.yml up -d etcd
sleep 5

# Start pgbackrest server (it still has backups!)
docker compose -f docker-compose-backup.yml up -d pgbackrest

# Verify backups still exist
docker exec -it pgbackrest pgbackrest --stanza=main info
# Output: Shows full and incremental backups intact!

# Create empty patroni1 container (don't start PostgreSQL yet)
docker compose -f docker-compose-backup.yml up -d patroni1 --no-start

# Restore latest backup
docker exec -it pgbackrest pgbackrest --stanza=main --delta restore

# Start patroni1
docker compose -f docker-compose-backup.yml start patroni1
sleep 15

# Verify data recovered
docker exec -it patroni1 psql -U postgres -d sales_db -c "SELECT COUNT(*) FROM orders;"
# Output: 2000
```

### Step 13.3: Rebuild Full Cluster

```bash
# Start remaining nodes (they'll clone from patroni1)
docker compose -f docker-compose-backup.yml up -d patroni2 patroni3
sleep 20

# Verify full cluster operational
docker exec -it patroni1 patronictl -c /home/postgres/postgres.yml list

# Test replica data
docker exec -it patroni2 psql -U postgres -d sales_db -c "SELECT COUNT(*) FROM orders;"
docker exec -it patroni3 psql -U postgres -d sales_db -c "SELECT COUNT(*) FROM orders;"
```

**Complete disaster recovery achieved!** 🚀

---

## Step 14: Calculate RPO and RTO

### Recovery Point Objective (RPO)

**RPO = Maximum acceptable data loss**

For our setup:
```
RPO = Time between backups + WAL archive interval

With WAL archiving:
- Incremental backups: Every 4 hours
- WAL archiving: Every 60 seconds (archive_timeout=60)
- RPO = ~60 seconds (worst case: last WAL not yet archived)

Without WAL archiving:
- Only nightly full backups
- RPO = 24 hours (lose entire day's work!)
```

**RPO comparison:**

| Backup Strategy | RPO | Risk |
|----------------|-----|------|
| No backups | ∞ | ☠️ Catastrophic |
| Daily full backup | 24 hours | 😱 High |
| Hourly incremental | 1 hour | 😟 Medium |
| Incremental + WAL | <1 minute | ✅ Low |
| Synchronous replication + WAL | 0 seconds | ✅ Minimal |

**Our lab achieves:** <60 second RPO

### Recovery Time Objective (RTO)

**RTO = Maximum acceptable downtime**

For our lab environment:

| Recovery Scenario | RTO | Steps |
|-------------------|-----|-------|
| HA failover (Patroni) | 30-60 sec | Automatic (LAB 4) |
| PITR from backup | 10-15 min | Stop cluster + restore + verify |
| Full cluster rebuild | 20-30 min | Restore primary + rebuild replicas |
| Datacenter disaster | 1-2 hours | New infrastructure + restore + test |

**Production optimization techniques:**
- Hot standby site: 5-10 min RTO
- Pre-staged restore environment: <5 min RTO
- Automated failover to DR site: <2 min RTO
- Multiple backup repositories: Parallel restore

---

## Step 15: Automated Backup Scripts

Create production-ready automation scripts.

### Backup Script

```bash
# filepath: /Users/anthonytran/Desktop/postgresSQL-labatory/lab5_env/scripts/backup.sh
#!/bin/bash
set -euo pipefail

# Configuration
STANZA="main"
BACKUP_TYPE="${1:-incr}"  # Default to incremental
LOG_FILE="/var/log/pgbackrest/backup-$(date +%Y%m%d-%H%M%S).log"

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Pre-backup checks
log "Starting backup (type: $BACKUP_TYPE)"

# Check disk space
AVAILABLE_GB=$(df -BG /backup | tail -1 | awk '{print $4}' | sed 's/G//')
if [ "$AVAILABLE_GB" -lt 10 ]; then
    log "ERROR: Low disk space: ${AVAILABLE_GB}GB available"
    exit 1
fi

# Check PostgreSQL is running
if ! docker exec patroni1 pg_isready -U postgres > /dev/null 2>&1; then
    log "ERROR: PostgreSQL is not ready"
    exit 1
fi

# Execute backup
log "Executing pgBackRest backup..."
START_TIME=$(date +%s)

if docker exec pgbackrest pgbackrest --stanza="$STANZA" --type="$BACKUP_TYPE" backup >> "$LOG_FILE" 2>&1; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    # Get backup info
    BACKUP_INFO=$(docker exec pgbackrest pgbackrest --stanza="$STANZA" info --output=json)
    
    log "SUCCESS: Backup completed in ${DURATION} seconds"
    log "Backup info: $BACKUP_INFO"
    
    # Send success notification (add your alerting here)
    # curl -X POST https://your-monitoring-system/alert -d "Backup successful"
    
    exit 0
else
    log "ERROR: Backup failed"
    # Send failure alert
    # curl -X POST https://your-monitoring-system/alert -d "Backup FAILED"
    exit 1
fi
```

Make executable:
```bash
chmod +x lab5_env/scripts/backup.sh
```

### Cron Schedule

```bash
# filepath: /Users/anthonytran/Desktop/postgresSQL-labatory/lab5_env/scripts/crontab
# PostgreSQL Backup Schedule

# Full backup: Every Sunday at 2 AM
0 2 * * 0 /path/to/backup.sh full

# Incremental backup: Every 4 hours (except Sunday 2 AM)
0 */4 * * * /path/to/backup.sh incr

# Cleanup old backups: Daily at 3 AM
0 3 * * * docker exec pgbackrest pgbackrest --stanza=main expire

# Health check: Every 6 hours
0 */6 * * * docker exec pgbackrest pgbackrest --stanza=main check
```

---

## Step 16: Monitoring and Alerting

### Health Check Script

```bash
# filepath: /Users/anthonytran/Desktop/postgresSQL-labatory/lab5_env/scripts/check_backups.sh
#!/bin/bash
set -euo pipefail

# Check when last successful backup was taken
LAST_BACKUP=$(docker exec pgbackrest pgbackrest --stanza=main info --output=json | \
    jq -r '.[0].backup[-1].timestamp.stop')

LAST_BACKUP_EPOCH=$(date -d "$LAST_BACKUP" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$LAST_BACKUP" +%s)
CURRENT_EPOCH=$(date +%s)
AGE_HOURS=$(( (CURRENT_EPOCH - LAST_BACKUP_EPOCH) / 3600 ))

# Alert if backup older than 6 hours
if [ "$AGE_HOURS" -gt 6 ]; then
    echo "WARNING: Last backup is $AGE_HOURS hours old!"
    # Send alert
    exit 1
fi

# Check WAL archiving
WAL_ARCHIVE_STATUS=$(docker exec patroni1 psql -U postgres -tAc \
    "SELECT archived_count, failed_count FROM pg_stat_archiver;")

ARCHIVED=$(echo "$WAL_ARCHIVE_STATUS" | cut -d'|' -f1)
FAILED=$(echo "$WAL_ARCHIVE_STATUS" | cut -d'|' -f2)

if [ "$FAILED" -gt 0 ]; then
    echo "WARNING: $FAILED WAL archiving failures detected!"
    exit 1
fi

echo "OK: Backups healthy. Last backup: $AGE_HOURS hours ago, Archived WALs: $ARCHIVED"
```

### Prometheus Metrics Export

```bash
# filepath: /Users/anthonytran/Desktop/postgresSQL-labatory/lab5_env/scripts/export_metrics.sh
#!/bin/bash

# Export backup metrics in Prometheus format
cat << EOF
# HELP pgbackrest_last_backup_age_seconds Time since last backup
# TYPE pgbackrest_last_backup_age_seconds gauge
pgbackrest_last_backup_age_seconds{stanza="main"} $AGE_SECONDS

# HELP pgbackrest_backup_size_bytes Size of latest backup
# TYPE pgbackrest_backup_size_bytes gauge
pgbackrest_backup_size_bytes{stanza="main",type="full"} $FULL_BACKUP_SIZE
pgbackrest_backup_size_bytes{stanza="main",type="incr"} $INCR_BACKUP_SIZE

# HELP pgbackrest_wal_archived_total Total WAL segments archived
# TYPE pgbackrest_wal_archived_total counter
pgbackrest_wal_archived_total{stanza="main"} $ARCHIVED

# HELP pgbackrest_wal_failed_total Total WAL archiving failures
# TYPE pgbackrest_wal_failed_total counter
pgbackrest_wal_failed_total{stanza="main"} $FAILED
EOF
```

---

## Step 17: Production Best Practices

### 1. Multiple Backup Repositories

```ini
# filepath: /Users/anthonytran/Desktop/postgresSQL-labatory/lab5_env/config/pgbackrest-prod.conf
[global]
# Local repository (fast restore)
repo1-path=/backup/local
repo1-retention-full=2

# S3 repository (off-site, immutable)
repo2-type=s3
repo2-s3-bucket=mycompany-pg-backups
repo2-s3-region=us-west-2
repo2-s3-endpoint=s3.amazonaws.com
repo2-retention-full=7
repo2-retention-archive=14

# Azure Blob repository (additional off-site)
repo3-type=azure
repo3-azure-container=pgbackups
repo3-azure-account=mycompanybackups
repo3-retention-full=30

[main]
pg1-path=/home/postgres/pgdata/data
pg1-host=patroni1
pg1-port=5432
pg1-user=postgres
```

**Repository strategy:**
- Repo1: Local (fast restore, 2 days retention)
- Repo2: S3 (off-site, 7 days retention, versioning enabled)
- Repo3: Azure (cold storage, 30 days retention, compliance)

### 2. Backup Verification

```bash
# Regularly restore backups to test environment
docker exec pgbackrest pgbackrest --stanza=main --delta \
    --target=latest \
    --target-action=promote \
    --db-path=/test-restore \
    restore

# Verify restored database
docker exec patroni1 postgres -D /test-restore --single -P "disable_system_indexes=on" \
    template1 -c "SELECT COUNT(*) FROM pg_class;"
```

### 3. Encryption at Rest

```ini
[global]
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=<strong-encryption-key>

# Use environment variable in production
# export PGBACKREST_REPO1_CIPHER_PASS=$(vault read -field=password secret/pgbackrest)
```

### 4. Backup Windows and Throttling

```ini
[global]
# Limit backup impact on production
start-fast=y          # Force checkpoint immediately
process-max=4         # Parallel compression
compress-level=3      # Balance speed vs size
backup-standby=y      # Backup from replica (not primary)

# Network throttling for off-site backups
repo2-storage-upload-chunksize=4MB
repo2-storage-verify-tls=y
```

### 5. Immutable Backups (Ransomware Protection)

```bash
# S3 Object Lock (requires bucket versioning)
aws s3api put-object-lock-configuration \
    --bucket mycompany-pg-backups \
    --object-lock-configuration '{
        "ObjectLockEnabled": "Enabled",
        "Rule": {
            "DefaultRetention": {
                "Mode": "GOVERNANCE",
                "Days": 30
            }
        }
    }'

# Now backups cannot be deleted for 30 days (even by admin!)
```

---

## Step 18: Testing and Deliverables

### Disaster Recovery Drills

**Schedule:** Quarterly DR test

| Test Scenario | Success Criteria | Last Test | Result |
|--------------|------------------|-----------|--------|
| PITR - Accidental DELETE | Data restored to before incident | 2024-01-15 | ✅ Pass (10 min RTO) |
| Full cluster loss | Cluster rebuilt from backup | 2024-01-01 | ✅ Pass (25 min RTO) |
| Backup corruption | Secondary backup repository used | 2023-12-01 | ✅ Pass |
| Primary and replicas lost | Restored from S3 off-site backup | 2023-11-01 | ✅ Pass (2 hour RTO) |

### Lab Deliverables

📋 **Submission Checklist:**

1. **Environment Setup**
   - [ ] `docker-compose-backup.yml` created and tested
   - [ ] `pgbackrest.conf` configured with proper retention
   - [ ] WAL archiving enabled and verified
   - [ ] pgBackRest stanza initialized successfully

2. **Backup Operations**
   - [ ] Full backup taken and verified (Step 8)
   - [ ] Incremental backup taken (Step 9)
   - [ ] Backup sizes and compression ratios documented
   - [ ] `pgbackrest info` output captured

3. **Disaster Recovery Testing**
   - [ ] Accidental DELETE simulated (Step 10)
   - [ ] PITR restore performed successfully (Step 11)
   - [ ] Replicas rebuilt from restored primary (Step 12)
   - [ ] Full datacenter loss simulated (Step 13)
   - [ ] Complete cluster restored from backup

4. **RPO/RTO Analysis**
   - [ ] RPO calculated for your backup strategy
   - [ ] RTO measured for each recovery scenario
   - [ ] Documented improvements vs. LAB 3 (manual recovery: 20-45 min)
   - [ ] Comparison chart: HA (LAB 4) vs. DR (LAB 5)

5. **Production Readiness**
   - [ ] Automated backup script created (Step 15)
   - [ ] Cron schedule configured
   - [ ] Monitoring/health check script implemented (Step 16)
   - [ ] Backup verification procedure documented

6. **Documentation**
   - [ ] Screenshots of each major step
   - [ ] `pgbackrest info` outputs before/after each backup
   - [ ] Timing measurements for all operations
   - [ ] Lessons learned and potential improvements

---

## Key Takeaways

### 1. HA ≠ DR
- **High Availability (Patroni):** Protects against hardware/process failures (RTO: 30-60 sec)
- **Disaster Recovery (Backups):** Protects against data corruption, deletions, disasters (RPO: <1 min)
- **Both required** for production systems!

### 2. Backup Strategy Matters
| Strategy | RPO | RTO | Cost | Complexity |
|----------|-----|-----|------|------------|
| No backups | ∞ | ∞ | $0 | 0/10 |
| Daily full | 24 hours | 2-4 hours | $ | 2/10 |
| Hourly incr | 1 hour | 1-2 hours | $$ | 4/10 |
| Incr + WAL | <1 min | 10-30 min | $$$ | 6/10 |
| Continuous (Streaming + WAL + Hot Standby) | 0 sec | <1 min | $$$$ | 9/10 |

### 3. pgBackRest Advantages
- ✅ Parallel backup/restore (faster)
- ✅ Multiple repository types (local, S3, Azure, GCS)
- ✅ Incremental/differential backups (save space)
- ✅ Compression and encryption
- ✅ Automatic WAL archiving
- ✅ PITR support
- ✅ Backup verification
- ✅ Active development and community

### 4. Real-World RPO/RTO Examples

| Industry | Typical RPO | Typical RTO | Backup Strategy |
|----------|-------------|-------------|----------------|
| E-commerce | <1 min | <5 min | Streaming replication + WAL + Hot standby |
| Banking | 0 sec | <1 min | Synchronous replication + PITR |
| SaaS | <5 min | <15 min | WAL archiving + 4-hour incrementals |
| Internal tools | <1 hour | <4 hours | Daily backups + WAL |
| Development | 24 hours | 1 day | Weekly full backups |

### 5. Cost Analysis (Annual estimates for 1TB database)

| Component | Cost | Benefit |
|-----------|------|---------|
| Primary storage | $1,000 | Required |
| 2 replicas (HA) | $2,000 | 30-60 sec RTO |
| Backup storage (local) | $500 | PITR capability |
| S3 backup (off-site) | $300 | Disaster protection |
| pgBackRest automation | $0 | Free! |
| DR testing | $2,000 | Confidence |
| **Total** | **$5,800** | **Sleep at night:** Priceless |

**Cost of NOT having backups:**
- Lost customer data: $$$$$
- Reputation damage: Priceless (in a bad way)
- Regulatory fines: $$$$
- Downtime revenue loss: $$$ per hour
- "Resume shopping time": 💀

---

## Troubleshooting Guide

### Issue 1: WAL Archiving Fails

**Symptoms:**
```sql
postgres=# SELECT * FROM pg_stat_archiver;
 archived_count | last_archived_wal | failed_count | last_failed_time
----------------+-------------------+--------------+------------------
            123 | 000000010...0005  |           45 | 2024-01-15 10:00
```

**Solutions:**
```bash
# Check archive_command configuration
docker exec patroni1 psql -U postgres -c "SHOW archive_command;"

# Test archive command manually
docker exec patroni1 pgbackrest --stanza=main archive-push /home/postgres/pgdata/data/pg_wal/000000010000000000000001

# Check pgbackrest.conf permissions
docker exec patroni1 ls -la /etc/pgbackrest/pgbackrest.conf

# Check backup repository space
docker exec pgbackrest df -h /backup

# Review pgbackrest logs
docker exec pgbackrest cat /var/log/pgbackrest/main-archive.log
```

### Issue 2: Backup Fails with "unable to get lock"

**Solution:**
```bash
# Check for stale locks
docker exec pgbackrest ls -la /tmp/pgbackrest/

# Remove stale locks (only if no backup is actually running!)
docker exec pgbackrest rm -f /tmp/pgbackrest/main-*.lock

# Retry backup
docker exec pgbackrest pgbackrest --stanza=main backup
```

### Issue 3: Restore Fails with "backup info missing"

**Solution:**
```bash
# Verify stanza exists
docker exec pgbackrest pgbackrest --stanza=main info

# If stanza missing, recreate it
docker exec pgbackrest pgbackrest --stanza=main stanza-create

# Check backup repository
docker exec pgbackrest ls -la /backup/backup/main/
```

### Issue 4: PITR Target Time Not Found

**Error:** `ERROR: could not find WAL file for timestamp`

**Solution:**
```bash
# Check available WAL range
docker exec pgbackrest pgbackrest --stanza=main info

# Look for: "wal archive min/max"
# Your target time must be within this range

# If WAL missing, restore to latest possible time
docker exec pgbackrest pgbackrest --stanza=main --delta \
    --type=default \
    restore
```

---

## Comparison: LAB 3 vs LAB 4 vs LAB 5

| Feature | LAB 3 (Manual) | LAB 4 (Patroni HA) | LAB 5 (Backup/DR) |
|---------|----------------|-------------------|------------------|
| **Primary protection** | Process crash | Hardware/process failures | Data corruption/disasters |
| **RTO** | 20-45 minutes | 30-60 seconds | 10-30 minutes |
| **RPO** | Hours to days | 0 seconds (sync repl) | <60 seconds (WAL archiving) |
| **Manual intervention** | Required | Automatic | Manual (but scripted) |
| **Protects against DELETE** | ❌ No | ❌ No | ✅ Yes (PITR) |
| **Protects against DROP TABLE** | ❌ No | ❌ No | ✅ Yes |
| **Protects against datacenter loss** | ❌ No | ❌ No (if all nodes lost) | ✅ Yes (off-site backups) |
| **Complexity** | Low | Medium | Medium-High |
| **Cost** | $ | $$ | $$$ |
| **Production readiness** | Testing only | HA clusters | Complete solution (HA+DR) |

**The complete picture:**
```
                Production PostgreSQL
                        │
        ┌───────────────┴───────────────┐
        │                               │
   High Availability              Disaster Recovery
   (LAB 4: Patroni)                (LAB 5: pgBackRest)
        │                               │
  RTO: 30-60 sec                  RPO: <60 sec
  Automatic failover              Point-in-Time Recovery
  3+ node cluster                 Off-site backups
        │                               │
        └───────────────┬───────────────┘
                        │
              ✅ Sleep well at night!
```

---

## Next Steps

After completing LAB 5, you've mastered:
- ✅ Streaming replication (LAB 2)
- ✅ Manual failover (LAB 3)  
- ✅ Automated HA with Patroni (LAB 4)
- ✅ Comprehensive backup and DR (LAB 5)

**Production checklist before going live:**
1. [ ] HA cluster with 3+ nodes (Patroni)
2. [ ] Automated backups (pgBackRest with multiple repositories)
3. [ ] WAL archiving enabled (RPO <1 min)
4. [ ] Off-site backup repository (S3/Azure/GCS)
5. [ ] Backup encryption enabled
6. [ ] Quarterly DR drills scheduled
7. [ ] Monitoring and alerting configured
8. [ ] Runbooks documented for all scenarios
9. [ ] Backup verification automated
10. [ ] Team trained on DR procedures

**Congratulations!** You now understand production-grade PostgreSQL HA and DR! 🎉

---

## Further Reading

- [pgBackRest User Guide](https://pgbackrest.org/user-guide.html)
- [PostgreSQL WAL Archiving](https://www.postgresql.org/docs/current/continuous-archiving.html)
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [PostgreSQL PITR](https://www.postgresql.org/docs/current/continuous-archiving.html#BACKUP-PITR-RECOVERY)
- [Disaster Recovery Best Practices](https://wiki.postgresql.org/wiki/Disaster_recovery)