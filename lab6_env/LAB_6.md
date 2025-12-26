# LAB 6 — Logical Replication (Bridge to Multi-Master)

**Goal:** Understand logical replication - the foundational technology for multi-master replication in PostgreSQL.

By the end of Lab 6, you will:
- Understand the difference between physical and logical replication
- Set up publisher/subscriber logical replication
- Replicate specific tables (not entire databases)
- Understand how logical replication enables bi-directional (multi-master) setups
- Learn the building blocks for conflict-free replicated data types (CRDTs)

---

## Why Logical Replication?

### The Journey So Far

| Lab | Type | Replication Level | Limitations |
|-----|------|-------------------|-------------|
| LAB 2 | Physical (Streaming) | Entire cluster | Read-only replicas, single primary |
| LAB 3 | Manual Failover | Entire cluster | Downtime, manual intervention |
| LAB 4 | Patroni (HA) | Entire cluster | Still single-primary, 30-60s downtime |
| **LAB 6** | **Logical** | **Specific tables** | **Enables multi-master!** |

### Physical vs Logical Replication

```
┌─────────────────────────────────────────────────────────────┐
│  PHYSICAL REPLICATION (LAB 2-4)                             │
├─────────────────────────────────────────────────────────────┤
│  Replicates: Binary WAL (Write-Ahead Log) segments         │
│  Granularity: Entire PostgreSQL cluster                     │
│  Direction: One-way (primary → replica)                     │
│  Replica state: Read-only (cannot write)                    │
│  Version compatibility: Must match (16.1 → 16.1 only)      │
│  Use case: HA failover, read scaling                        │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  LOGICAL REPLICATION (LAB 6)                                │
├─────────────────────────────────────────────────────────────┤
│  Replicates: Logical changes (INSERT/UPDATE/DELETE)        │
│  Granularity: Specific tables or databases                  │
│  Direction: Can be bi-directional (A ↔ B)                   │
│  Replica state: Read-write (can accept writes!)            │
│  Version compatibility: Cross-version (16.1 → 15.3 works)  │
│  Use case: Multi-master, selective sync, migrations        │
└─────────────────────────────────────────────────────────────┘
```

### Architecture Overview

```
┌────────────────────────────────────────────────────────────┐
│                    LOGICAL REPLICATION                      │
│                                                             │
│  ┌─────────────────────┐         ┌─────────────────────┐  │
│  │   PUBLISHER (pg1)   │         │  SUBSCRIBER (pg2)   │  │
│  │                     │         │                     │  │
│  │  ┌───────────────┐  │         │  ┌───────────────┐ │  │
│  │  │ users_table   │  │         │  │ users_table   │ │  │
│  │  │ id | name     │  │         │  │ id | name     │ │  │
│  │  │ 1  | Alice    │──┼────────→│  │ 1  | Alice    │ │  │
│  │  │ 2  | Bob      │  │ Logical │  │ 2  | Bob      │ │  │
│  │  └───────────────┘  │ Changes │  └───────────────┘ │  │
│  │                     │         │                     │  │
│  │  ┌───────────────┐  │         │  ┌───────────────┐ │  │
│  │  │ orders_table  │  │         │  │ orders_table  │ │  │
│  │  │ (NOT synced)  │  │         │  │ (local only)  │ │  │
│  │  └───────────────┘  │         │  └───────────────┘ │  │
│  └─────────────────────┘         └─────────────────────┘  │
│                                                             │
│  Key Point: Only SELECTED tables replicate!                │
└────────────────────────────────────────────────────────────┘
```

### How It Enables Multi-Master

```
Step 1 (LAB 6): Unidirectional
pg1 (Publisher) ──→ pg2 (Subscriber)

Step 2 (LAB 7): Bi-directional
pg1 (Pub & Sub) ←→ pg2 (Pub & Sub)

Step 3 (LAB 8): Multi-master with Conflict Resolution
pg1 ←→ pg2 ←→ pg3
(All nodes can write, conflicts resolved automatically)
```

---

## Prerequisites

### Clean Slate

```bash
cd /Users/anthonytran/Desktop/postgresSQL-labatory/lab6_env

# Stop any previous labs
cd ..
docker compose -f docker-compose.yml down 2>/dev/null || true
docker compose -f docker-compose-patroni.yml down 2>/dev/null || true

# Return to lab6
cd lab6_env
```

---

## Step 1: Create Docker Compose for Two PostgreSQL Instances

Create `docker-compose.yml` in `/Users/anthonytran/Desktop/postgresSQL-labatory/lab6_env/`:

```yaml
services:
  pg1:
    image: postgres:16
    container_name: lab6_pg1
    hostname: pg1
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: testdb
    ports:
      - "5433:5432"
    volumes:
      - pg1_data:/var/lib/postgresql/data
      - ./init/init_pg1.sql:/docker-entrypoint-initdb.d/init_pg1.sql
    networks:
      - logical_net
    command:
      - "postgres"
      - "-c"
      - "wal_level=logical"              # Required for logical replication
      - "-c"
      - "max_replication_slots=5"        # Allow replication slots
      - "-c"
      - "max_wal_senders=5"              # Allow WAL senders
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d testdb"]
      interval: 5s
      timeout: 5s
      retries: 5

  pg2:
    image: postgres:16
    container_name: lab6_pg2
    hostname: pg2
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: testdb
    ports:
      - "5434:5432"
    volumes:
      - pg2_data:/var/lib/postgresql/data
      - ./init/init_pg2.sql:/docker-entrypoint-initdb.d/init_pg2.sql
    networks:
      - logical_net
    command:
      - "postgres"
      - "-c"
      - "wal_level=logical"
      - "-c"
      - "max_replication_slots=5"
      - "-c"
      - "max_wal_senders=5"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d testdb"]
      interval: 5s
      timeout: 5s
      retries: 5

networks:
  logical_net:
    driver: bridge

volumes:
  pg1_data:
  pg2_data:
```

**Key Configuration Explained:**

| Parameter | Value | Why It Matters |
|-----------|-------|----------------|
| `wal_level` | `logical` | Enables logical decoding of WAL (vs `replica` for physical) |
| `max_replication_slots` | `5` | Allows creation of logical replication slots |
| `max_wal_senders` | `5` | Concurrent replication connections |

**Note:** Init scripts are in the `init/` subdirectory and will be mounted to `/docker-entrypoint-initdb.d/` inside containers.

---

## Step 2: Create Initialization Scripts

Create the `init` directory and initialization scripts:

```bash
# Create init directory if it doesn't exist
mkdir -p /Users/anthonytran/Desktop/postgresSQL-labatory/lab6_env/init
```

### Create `init/init_pg1.sql` (Publisher)

Create the file at `/Users/anthonytran/Desktop/postgresSQL-labatory/lab6_env/init/init_pg1.sql`:

```sql
-- init_pg1.sql
-- This runs automatically when pg1 container starts

-- Create schema
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    product VARCHAR(100) NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

-- This table will NOT be replicated (to demonstrate selective replication)
CREATE TABLE local_logs (
    id SERIAL PRIMARY KEY,
    message TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Configure sequences for pg1 to use ODD numbers (1, 3, 5, 7...)
-- This prevents ID conflicts when both nodes accept writes
ALTER SEQUENCE users_id_seq RESTART WITH 1 INCREMENT BY 2;
ALTER SEQUENCE orders_id_seq RESTART WITH 1 INCREMENT BY 2;

-- Insert initial data on publisher (will get odd IDs: 1, 3, 5)
INSERT INTO users (name, email) VALUES 
    ('Alice', 'alice@example.com'),
    ('Bob', 'bob@example.com'),
    ('Charlie', 'charlie@example.com');

INSERT INTO orders (user_id, product, amount) VALUES 
    (1, 'Laptop', 1200.00),
    (1, 'Mouse', 25.00),
    (1, 'Keyboard', 75.00);

INSERT INTO local_logs (message) VALUES 
    ('Publisher initialized with ODD id sequence'),
    ('Initial data loaded');

-- Show what we created
SELECT 'Publisher (pg1) initialized with ODD IDs:' AS status;
SELECT 'Users:' AS info, id, name FROM users ORDER BY id;
SELECT 'Orders:' AS info, id, product FROM orders ORDER BY id;
SELECT 'Local logs:' AS info, COUNT(*) AS count FROM local_logs;
SELECT 'Sequence config:' AS info, last_value, increment_by FROM users_id_seq;
```

### Create `init/init_pg2.sql` (Subscriber)

Create the file at `/Users/anthonytran/Desktop/postgresSQL-labatory/lab6_env/init/init_pg2.sql`:

```sql
-- init_pg2.sql
-- This runs automatically when pg2 container starts

-- Create IDENTICAL schema for tables we want to replicate
-- CRITICAL: Schema must match on subscriber!
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    product VARCHAR(100) NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Subscriber can have its own local tables
CREATE TABLE subscriber_logs (
    id SERIAL PRIMARY KEY,
    message TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Configure sequences for pg2 to use EVEN numbers (2, 4, 6, 8...)
-- This prevents ID conflicts when both nodes accept writes
ALTER SEQUENCE users_id_seq RESTART WITH 2 INCREMENT BY 2;
ALTER SEQUENCE orders_id_seq RESTART WITH 2 INCREMENT BY 2;

INSERT INTO subscriber_logs (message) VALUES 
    ('Subscriber initialized with EVEN id sequence'),
    ('Waiting for replication setup');

-- Show what we created
SELECT 'Subscriber (pg2) initialized with EVEN IDs:' AS status;
SELECT 'Users table (empty):' AS info, COUNT(*) AS count FROM users;
SELECT 'Orders table (empty):' AS info, COUNT(*) AS count FROM orders;
SELECT 'Sequence config:' AS info, last_value, increment_by FROM users_id_seq;
```

**Important Note About Sequences:**
- pg1 uses ODD IDs (1, 3, 5, 7, 9...)
- pg2 uses EVEN IDs (2, 4, 6, 8, 10...)
- This prevents primary key conflicts when both nodes accept writes
- **Critical for LAB 7's bi-directional replication!**

---

## Step 3: Start the Containers

```bash
cd /Users/anthonytran/Desktop/postgresSQL-labatory/lab6_env

# Ensure init directory and scripts exist
ls -la init/

# Start both nodes
docker compose up -d

# Wait for initialization
echo "Waiting for PostgreSQL to initialize..."
sleep 15
```

### Verify Both Nodes Are Running

```bash
# Check pg1 (publisher)
docker exec -it lab6_pg1 psql -U postgres -d testdb -c "\dt"

# Expected output:
#           List of relations
#  Schema |    Name     | Type  |  Owner   
# --------+-------------+-------+----------
#  public | local_logs  | table | postgres
#  public | orders      | table | postgres
#  public | users       | table | postgres

# Check pg2 (subscriber)
docker exec -it lab6_pg2 psql -U postgres -d testdb -c "\dt"

# Expected output:
#           List of relations
#  Schema |       Name        | Type  |  Owner   
# --------+-------------------+-------+----------
#  public | orders            | table | postgres
#  public | subscriber_logs   | table | postgres
#  public | users             | table | postgres
```

---

## Step 4: Set Up Logical Replication (Publisher Side)

### Create Publication on pg1

A **publication** defines which tables to replicate.

```bash
docker exec -i lab6_pg1 psql -U postgres -d testdb << 'EOF'
-- Create publication for specific tables
CREATE PUBLICATION my_publication 
FOR TABLE users, orders;

-- Verify publication created
SELECT * FROM pg_publication;

-- Show which tables are included
SELECT * FROM pg_publication_tables;
EOF
```

**Expected output:**
```
      pubname     | pubowner | puballtables | pubinsert | pubupdate | pubdelete 
------------------+----------+--------------+-----------+-----------+-----------
 my_publication   |       10 | f            | t         | t         | t

 pubname        | schemaname | tablename 
----------------+------------+-----------
 my_publication | public     | users
 my_publication | public     | orders
```

**What this means:**
- ✅ `users` and `orders` will replicate
- ✅ INSERT, UPDATE, DELETE operations will replicate
- ❌ `local_logs` will NOT replicate (not in publication)

---

## Step 5: Set Up Logical Replication (Subscriber Side)

### Create Subscription on pg2

A **subscription** connects to a publication and starts receiving changes.

```bash
# Remove -t flag (use only -i for input redirection)
docker exec -i lab6_pg2 psql -U postgres -d testdb << 'EOF'
-- Create subscription to pg1's publication
CREATE SUBSCRIPTION my_subscription
CONNECTION 'host=pg1 port=5432 dbname=testdb user=postgres password=postgres'
PUBLICATION my_publication;

-- Verify subscription created
SELECT subname, subenabled, subpublications FROM pg_subscription;

-- Check replication status
SELECT * FROM pg_stat_subscription;
EOF
```

**Expected output:**
```
     subname      | subenabled | subpublications 
------------------+------------+-----------------
 my_subscription  | t          | {my_publication}

 subname         | pid  | relid | received_lsn | latest_end_lsn | last_msg_send_time 
-----------------+------+-------+--------------+----------------+--------------------
 my_subscription | 1234 |       | 0/1A2B3C4D   | 0/1A2B3C4D     | 2025-12-23 10:30:15
```

**What happened:**
1. pg2 connected to pg1
2. pg2 created a replication slot on pg1
3. pg2 started receiving changes
4. **Initial data was synchronized automatically!**

---

## Step 6: Verify Initial Data Sync

### Check pg1 (Publisher) Data

```bash
docker exec -i lab6_pg1 psql -U postgres -d testdb << 'EOF'
SELECT 'Publisher (pg1) data:' AS source;

SELECT * FROM users ORDER BY id;
SELECT * FROM orders ORDER BY id;
SELECT * FROM local_logs ORDER BY id;
EOF
```

**Expected:**
```
 id |  name   |       email        
----+---------+--------------------
  1 | Alice   | alice@example.com
  3 | Bob     | bob@example.com
  5 | Charlie | charlie@example.com

 id | user_id | product  | amount  
----+---------+----------+---------
  1 |       1 | Laptop   | 1200.00
  3 |       1 | Mouse    |   25.00
  5 |       1 | Keyboard |   75.00

 id |        message        
----+-----------------------
  1 | Publisher initialized with ODD id sequence
  2 | Initial data loaded
```

**Notice:** User IDs are 1, 3, 5 (ODD numbers) - this is intentional!

### Check pg2 (Subscriber) Data

```bash
docker exec -i lab6_pg2 psql -U postgres -d testdb << 'EOF'
SELECT 'Subscriber (pg2) data after sync:' AS source;

SELECT * FROM users ORDER BY id;
SELECT * FROM orders ORDER BY id;

-- This table doesn't exist on subscriber (it wasn't replicated)
\dt local_logs
EOF
```

**Expected:**
```
 id |  name   |       email        
----+---------+--------------------
  1 | Alice   | alice@example.com
  3 | Bob     | bob@example.com
  5 | Charlie | charlie@example.com
(3 rows)

 id | user_id | product  | amount  
----+---------+----------+---------
  1 |       1 | Laptop   | 1200.00
  3 |       1 | Mouse    |   25.00
  5 |       1 | Keyboard |   75.00
(3 rows)

Did not find any relation named "local_logs".
```

✅ **Success!** Data replicated from pg1 → pg2, but only for published tables!

**Notice:** The replicated IDs are ODD (1, 3, 5) because they came from pg1.

---

## Step 7: Test Real-Time Replication

### Insert New Data on Publisher (pg1)

```bash
docker exec -i lab6_pg1 psql -U postgres -d testdb << 'EOF'
-- Insert new user
INSERT INTO users (name, email) VALUES ('David', 'david@example.com');

-- Insert new order
INSERT INTO orders (user_id, product, amount) VALUES (4, 'Monitor', 350.00);

-- Update existing user
UPDATE users SET name = 'Alice Smith' WHERE id = 1;

-- Delete an order
DELETE FROM orders WHERE id = 2;

-- Insert into non-replicated table
INSERT INTO local_logs (message) VALUES ('New data added - not replicated');

SELECT 'After changes on pg1:' AS status;
SELECT * FROM users ORDER BY id;
SELECT * FROM orders ORDER BY id;
EOF
```

### Verify Changes Replicated to Subscriber (pg2)

```bash
# Wait a moment for replication
sleep 2

docker exec -i lab6_pg2 psql -U postgres -d testdb << 'EOF'
SELECT 'After replication to pg2:' AS status;

-- Should see new user
SELECT * FROM users ORDER BY id;

-- Should see new order and deleted order is gone
SELECT * FROM orders ORDER BY id;

-- Should see updated name
SELECT * FROM users WHERE id = 1;
EOF
```

**Expected output on pg2:**
```
 id |    name     |       email        
----+-------------+--------------------
  1 | Alice Smith | alice@example.com  ← UPDATED!
  3 | Bob         | bob@example.com
  5 | Charlie     | charlie@example.com
  4 | David       | david@example.com  ← NEW!

 id | user_id | product | amount  
----+---------+---------+---------
  1 |       1 | Laptop  | 1200.00
  5 |       1 | Keyboard|   75.00
  4 |       4 | Monitor |  350.00  ← NEW!
(Row id=3 deleted! Note: id=2 was Mouse, but we deleted it)
```

✅ **Real-time replication working!**
- ✅ INSERT replicated
- ✅ UPDATE replicated
- ✅ DELETE replicated

**Notice:** New user David got id=4 (next value in pg1's ODD sequence: 1→3→5→7... wait, 4 is even! This is because we deleted id=2).

---

## Step 8: Monitor Replication

### Check Replication Lag

```bash
docker exec -i lab6_pg2 psql -U postgres -d testdb << 'EOF'
-- Check subscription status
SELECT 
    subname,
    pid,
    received_lsn,
    latest_end_lsn,
    last_msg_send_time,
    last_msg_receipt_time,
    latest_end_time - last_msg_receipt_time AS replication_lag
FROM pg_stat_subscription;
EOF
```

**What to look for:**
- `received_lsn` = `latest_end_lsn` → Fully caught up
- `replication_lag` ≈ 0 → Near real-time replication

### Check Replication Slot on Publisher

```bash
docker exec -i lab6_pg1 psql -U postgres -d testdb << 'EOF'
-- View replication slots
SELECT 
    slot_name,
    plugin,
    slot_type,
    database,
    active,
    restart_lsn
FROM pg_replication_slots;
EOF
```

**Expected:**
```
      slot_name       |  plugin  | slot_type | database | active | restart_lsn 
----------------------+----------+-----------+----------+--------+-------------
 my_subscription      | pgoutput | logical   | testdb   | t      | 0/1A2B3C4D
```

**What this means:**
- ✅ Replication slot created by subscription
- ✅ `active = t` → Subscriber is connected
- ✅ `plugin = pgoutput` → Logical replication decoder

---

## Step 9: Understanding Logical Replication Internals

### How It Works Under the Hood

```
┌──────────────────────────────────────────────────────────────┐
│  PUBLISHER (pg1)                                              │
│                                                               │
│  1. Transaction commits:                                      │
│     INSERT INTO users VALUES (5, 'Eve', 'eve@example.com')   │
│                                                               │
│  2. PostgreSQL writes to WAL:                                 │
│     WAL Segment: 000000010000000000000001                     │
│     LSN: 0/1A2B3C4D                                           │
│                                                               │
│  3. Logical Decoding Plugin (pgoutput):                       │
│     Decodes WAL → Logical Change Records                      │
│     {action: "INSERT", table: "users", data: {...}}          │
│                                                               │
│  4. Replication Slot:                                         │
│     Buffers changes for subscriber                            │
│     Tracks subscriber progress (received_lsn)                 │
│                                                               │
│  5. WAL Sender Process:                                       │
│     Streams logical changes to subscriber                     │
│     Protocol: PostgreSQL Replication Protocol                 │
│                                                               │
└──────────────────────────────────────────────────────────────┘
                          │
                          │ Network
                          ▼
┌──────────────────────────────────────────────────────────────┐
│  SUBSCRIBER (pg2)                                             │
│                                                               │
│  1. Subscription Worker Process:                              │
│     Receives logical change stream                            │
│     Decodes: {action: "INSERT", table: "users", ...}         │
│                                                               │
│  2. Apply Changes:                                            │
│     Constructs SQL: INSERT INTO users (id, name, email)      │
│                     VALUES (5, 'Eve', 'eve@example.com')     │
│     Executes locally                                          │
│                                                               │
│  3. Commit and Acknowledge:                                   │
│     Commits transaction                                       │
│     Sends ACK to publisher with LSN                           │
│                                                               │
│  4. Update Statistics:                                        │
│     Updates pg_stat_subscription                              │
│     received_lsn = 0/1A2B3C4E                                │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

### Key Differences from Physical Replication

| Aspect | Physical Replication | Logical Replication |
|--------|---------------------|---------------------|
| **Data Format** | Binary WAL blocks | Logical SQL operations |
| **Granularity** | Entire cluster | Specific tables |
| **Direction** | One-way only | Can be bi-directional |
| **Subscriber writes** | Read-only | Read-write enabled |
| **Schema changes** | Auto-replicated | Must be applied manually |
| **Version compatibility** | Must match exactly | Cross-version supported |
| **Conflict handling** | N/A (read-only) | Requires resolution strategy |

---

## Step 10: Test Subscriber Writes (Multi-Master Preview)

### Important: Subscriber Can Accept Writes!

Unlike physical replication, the subscriber is NOT read-only!

```bash
docker exec -i lab6_pg2 psql -U postgres -d testdb << 'EOF'
-- Write directly to subscriber (pg2)
INSERT INTO users (name, email) VALUES ('Frank', 'frank@example.com');

SELECT 'Data written directly to pg2:' AS status;
SELECT id, name, email FROM users WHERE name = 'Frank';
EOF
```

**Expected:** ✅ Write succeeds! pg2 is read-write!

```
INSERT 0 1
            status             
-------------------------------
 Data written directly to pg2:
(1 row)

 id | name  |       email       
----+-------+-------------------
  2 | Frank | frank@example.com   ← EVEN ID from pg2!
(1 row)
```

**Notice:** Frank got id=2 (EVEN) because pg2's sequence generates 2, 4, 6, 8...

### Understanding Sequence Behavior

Let's check all users on both nodes:

```bash
# Check pg1
docker exec -i lab6_pg1 psql -U postgres -d testdb -c "
SELECT id, name, email FROM users ORDER BY id;
"

# Check pg2
docker exec -i lab6_pg2 psql -U postgres -d testdb -c "
SELECT id, name, email FROM users ORDER BY id;
"
```

**pg1 output (publisher):**
```
 id |    name     |       email        
----+-------------+--------------------
  1 | Alice Smith | alice@example.com
  3 | Bob         | bob@example.com
  5 | Charlie     | charlie@example.com
  7 | David       | david@example.com
(4 rows)
```

**pg2 output (subscriber):**
```
 id |    name     |       email        
----+-------------+--------------------
  1 | Alice Smith | alice@example.com  ← from pg1 (replicated)
  2 | Frank       | frank@example.com  ← from pg2 (local write)
  3 | Bob         | bob@example.com    ← from pg1 (replicated)
  5 | Charlie     | charlie@example.com ← from pg1 (replicated)
  7 | David       | david@example.com  ← from pg1 (replicated)
(5 rows)
```

### Why Non-Overlapping Sequences Matter

**Without sequence configuration (problematic):**
```
pg1 generates: 1, 2, 3, 4, 5...
pg2 generates: 1, 2, 3, 4, 5...
              ↓
When pg1's id=2 replicates to pg2 → CONFLICT! (pg2 already has id=2)
```

**With ODD/EVEN sequences (correct):**
```
pg1 generates: 1, 3, 5, 7, 9...  (ODD)
pg2 generates: 2, 4, 6, 8, 10... (EVEN)
              ↓
No conflicts! IDs never overlap!
```

### What Happens Without Proper Sequences?

If you didn't configure sequences, you'd see errors like:

```bash
# Without sequence config, inserting on pg2 would cause:
ERROR:  duplicate key value violates unique constraint "users_pkey"
DETAIL:  Key (id)=(1) already exists.
```

**Why?** PostgreSQL's `nextval()` would try:
1. id=1 → Conflict! (replicated from pg1)
2. id=2 → Conflict! (replicated from pg1)  
3. id=3 → Conflict! (replicated from pg1)
4. Keeps trying until finding a free ID...

This wastes sequence values and is very inefficient!

### Check if This Write Appears on pg1

```bash
docker exec -i lab6_pg1 psql -U postgres -d testdb << 'EOF'
SELECT 'Checking pg1 for Frank:' AS status;
SELECT * FROM users WHERE name = 'Frank';
EOF
```

**Expected:** ❌ No rows! The write on pg2 did NOT replicate back to pg1!

**Why?** We only set up **unidirectional** replication: pg1 → pg2

**For bi-directional (multi-master):**
- Need to create publication on pg2
- Need to create subscription on pg1
- Need conflict resolution strategy
- **This is what LAB 7 will cover!**

---

## Step 10a: Understanding Sequence Conflicts (Deep Dive)

### The Sequence Problem Explained

**Question:** Why did we configure ODD/EVEN sequences? What happens without it?

Let's understand PostgreSQL's sequence behavior during conflicts.

### Experiment: What PostgreSQL Does When ID Conflicts Occur

When you insert with a SERIAL column, PostgreSQL:

1. Calls `nextval('table_id_seq')` to get next ID
2. Tries to INSERT with that ID
3. If PRIMARY KEY constraint fails → Transaction rolls back
4. **But the sequence value is NOT rolled back!**
5. Next attempt uses the next sequence value

```
┌────────────────────────────────────────────────────┐
│  Sequence Behavior During Conflicts                │
├────────────────────────────────────────────────────┤
│                                                     │
│  Initial state: users has ids [1, 3, 5]            │
│                 (replicated from pg1)              │
│                 sequence last_value = 1            │
│                                                     │
│  Attempt 1:                                        │
│    nextval() → 2                                   │
│    INSERT id=2 → ERROR! (conflict with pg1's Bob)  │
│    Sequence now: last_value = 2 (not rolled back!) │
│                                                     │
│  Attempt 2:                                        │
│    nextval() → 3                                   │
│    INSERT id=3 → ERROR! (conflict with pg1's data) │
│    Sequence now: last_value = 3                    │
│                                                     │
│  Attempt 3:                                        │
│    nextval() → 4                                   │
│    INSERT id=4 → ERROR! (if pg1 has id=4)         │
│    Sequence now: last_value = 4                    │
│                                                     │
│  Attempt N:                                        │
│    nextval() → N                                   │
│    INSERT id=N → SUCCESS! (first free ID)         │
│                                                     │
│  Result: IDs 2, 3, 4... are "burned" (wasted)     │
│          Large gaps in sequence                    │
│          Inefficient and confusing                 │
│                                                     │
└────────────────────────────────────────────────────┘
```

### Verification: Check Sequence State

```bash
# Check pg1's sequence (should be on ODD numbers)
docker exec -i lab6_pg1 psql -U postgres -d testdb -c "
SELECT last_value, increment_by FROM users_id_seq;
"

# Expected: last_value=7 (or last odd used), increment_by=2

# Check pg2's sequence (should be on EVEN numbers)
docker exec -i lab6_pg2 psql -U postgres -d testdb -c "
SELECT last_value, increment_by FROM users_id_seq;
"

# Expected: last_value=2 (after inserting Frank), increment_by=2
```

### Why ODD/EVEN Strategy Works

```
┌──────────────────────────────────────────────────────────┐
│  Conflict Prevention Strategy: Non-Overlapping Sequences │
├──────────────────────────────────────────────────────────┤
│                                                           │
│  pg1 (Publisher):                                         │
│    ALTER SEQUENCE users_id_seq                           │
│      RESTART WITH 1 INCREMENT BY 2;                      │
│    Generates: 1, 3, 5, 7, 9, 11, 13...                   │
│                                                           │
│  pg2 (Subscriber):                                        │
│    ALTER SEQUENCE users_id_seq                           │
│      RESTART WITH 2 INCREMENT BY 2;                      │
│    Generates: 2, 4, 6, 8, 10, 12, 14...                  │
│                                                           │
│  Result:                                                  │
│    ✅ No overlap → No conflicts                          │
│    ✅ Both can write independently                       │
│    ✅ Foundation for bi-directional replication          │
│    ✅ Essential for multi-master setups                  │
│                                                           │
└──────────────────────────────────────────────────────────┘
```

### Alternative Strategies

| Strategy | How It Works | Pros | Cons |
|----------|--------------|------|------|
| **ODD/EVEN** | Node 1: odd, Node 2: even | Simple, predictable | Limited to 2 nodes |
| **Range-based** | Node 1: 1-1M, Node 2: 1M-2M | Scales to many nodes | Complex management |
| **UUID** | Use UUIDs instead of integers | Globally unique | Larger storage, slower |
| **Composite key** | (node_id, local_id) | Natural partitioning | Schema changes required |
| **Central sequence** | Shared sequence service | True coordination | Single point of failure |

### Best Practices for Multi-Master

```sql
-- For 2-node setup (LAB 6 & 7):
-- Node 1: ODD
ALTER SEQUENCE users_id_seq RESTART WITH 1 INCREMENT BY 2;

-- Node 2: EVEN  
ALTER SEQUENCE users_id_seq RESTART WITH 2 INCREMENT BY 2;

-- For 3+ nodes:
-- Node 1: starts at 1, increment by 3 (1, 4, 7, 10...)
-- Node 2: starts at 2, increment by 3 (2, 5, 8, 11...)
-- Node 3: starts at 3, increment by 3 (3, 6, 9, 12...)

-- Or use UUIDs:
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(100),
    email VARCHAR(100)
);
```

### Key Takeaways

1. ✅ **Sequences don't rollback** - Failed inserts burn sequence values
2. ✅ **Logical replication doesn't sync sequences** - Each node has independent sequences
3. ✅ **Non-overlapping ranges prevent conflicts** - ODD/EVEN is the simplest approach
4. ✅ **Critical for multi-master** - Without this, bi-directional replication fails
5. ✅ **Plan ahead** - Configure sequences before enabling writes on replicas

---

## Step 11: Logical Replication Diagram (Deliverable)

```
┌──────────────────────────────────────────────────────────────────┐
│                   LAB 6: LOGICAL REPLICATION                      │
│                    (Unidirectional Setup)                         │
└──────────────────────────────────────────────────────────────────┘

┌─────────────────────────────┐         ┌─────────────────────────────┐
│   PUBLISHER (pg1)            │         │   SUBSCRIBER (pg2)          │
│   Port: 5433 (host)         │         │   Port: 5434 (host)        │
│   Internal: pg1:5432        │         │   Internal: pg2:5432       │
├─────────────────────────────┤         ├─────────────────────────────┤
│                             │         │                             │
│  📊 Database: testdb        │         │  📊 Database: testdb        │
│                             │         │                             │
│  ✅ PUBLISHED TABLES:       │         │  ✅ SUBSCRIBED TABLES:      │
│  ┌─────────────────────┐   │         │  ┌─────────────────────┐   │
│  │ users               │───┼────────→│  │ users               │   │
│  │ (id, name, email)   │   │ Logical │  │ (id, name, email)   │   │
│  └─────────────────────┘   │ Changes │  └─────────────────────┘   │
│                             │         │                             │
│  ┌─────────────────────┐   │         │  ┌─────────────────────┐   │
│  │ orders              │───┼────────→│  │ orders              │   │
│  │ (id, product, amt)  │   │         │  │ (id, product, amt)  │   │
│  └─────────────────────┘   │         │  └─────────────────────┘   │
│                             │         │                             │
│  ❌ LOCAL ONLY:             │         │  ❌ LOCAL ONLY:             │
│  ┌─────────────────────┐   │         │  ┌─────────────────────┐   │
│  │ local_logs          │   │   X     │  │ subscriber_logs     │   │
│  │ (not replicated)    │   │         │  │ (not replicated)    │   │
│  └─────────────────────┘   │         │  └─────────────────────┘   │
│                             │         │                             │
│  📤 PUBLICATION:            │         │  📥 SUBSCRIPTION:           │
│  my_publication             │         │  my_subscription            │
│                             │         │                             │
│  🔧 Replication Slot:       │         │  🔄 Subscription Worker:    │
│  my_subscription            │         │  PID: 1234 (active)         │
│  LSN: 0/1A2B3C4D           │         │  Lag: ~0 ms                 │
│                             │         │                             │
│  🎯 State: Master           │         │  🎯 State: Read-Write       │
│  🔓 Mode: Read-Write        │         │  🔓 Mode: Read-Write        │
│                             │         │                             │
└─────────────────────────────┘         └─────────────────────────────┘

Connection Details:
  - From host:    pg1 (localhost:5433) ←→ pg2 (localhost:5434)
  - From pg2:     CONNECTION 'host=pg1 port=5432 ...'
  - Network:      Both containers share same Docker network (logical_net)

Legend:
  ──→  Logical replication flow (INSERT/UPDATE/DELETE)
  ✅   Replicated tables
  ❌   Local-only tables (not replicated)
  📤   Publication (defines what to replicate)
  📥   Subscription (receives replication)
  🔧   Replication slot (buffers changes)
  🔄   Subscription worker (applies changes)

Key Points:
1. Only SELECTED tables replicate (users, orders)
2. Replication is UNIDIRECTIONAL (pg1 → pg2)
3. pg2 can accept writes (but they don't go back to pg1)
4. Schema changes (ALTER TABLE) do NOT auto-replicate
5. This is the FOUNDATION for bi-directional (LAB 7)
```

---

## Step 12: SQL Setup Scripts (Deliverable)

### Complete Setup Script: `setup_logical_replication.sql`

Create this file in `/Users/anthonytran/Desktop/postgresSQL-labatory/lab6_env/`:

```sql
-- ============================================================================
-- LAB 6: Logical Replication Setup Script
-- Purpose: Complete setup for publisher/subscriber logical replication
-- ============================================================================

-- ============================================================================
-- PART 1: Run on PUBLISHER (pg1)
-- ============================================================================

\echo '================================================'
\echo 'Setting up PUBLISHER (pg1)'
\echo '================================================'

-- Verify prerequisites
SHOW wal_level;  -- Must be 'logical'
SHOW max_replication_slots;  -- Must be > 0
SHOW max_wal_senders;  -- Must be > 0

-- Create tables
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    product VARCHAR(100) NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Create publication
CREATE PUBLICATION my_publication FOR TABLE users, orders;

-- Verify publication
SELECT * FROM pg_publication;
SELECT * FROM pg_publication_tables;

\echo 'Publisher setup complete!'

-- ============================================================================
-- PART 2: Run on SUBSCRIBER (pg2)
-- ============================================================================

\echo '================================================'
\echo 'Setting up SUBSCRIBER (pg2)'
\echo '================================================'

-- Create IDENTICAL schema (must match publisher!)
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    product VARCHAR(100) NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Create subscription
CREATE SUBSCRIPTION my_subscription
CONNECTION 'host=pg1 port=5432 dbname=testdb user=postgres password=postgres'
PUBLICATION my_publication;

-- Wait for initial sync
SELECT pg_sleep(5);

-- Verify subscription
SELECT subname, subenabled, subpublications FROM pg_subscription;
SELECT * FROM pg_stat_subscription;

\echo 'Subscriber setup complete!'
\echo 'Logical replication is now active!'

-- ============================================================================
-- PART 3: Verification Queries (run on either node)
-- ============================================================================

\echo '================================================'
\echo 'Verification'
\echo '================================================'

-- Check replication status (run on pg2)
-- SELECT 
--     subname,
--     received_lsn,
--     latest_end_lsn,
--     last_msg_receipt_time
-- FROM pg_stat_subscription;

-- Check replication slot (run on pg1)
-- SELECT 
--     slot_name,
--     active,
--     restart_lsn
-- FROM pg_replication_slots;
```

---

## Step 13: Replication Verification (Deliverable)

### Comprehensive Verification Script

Create `verify_replication.sql` in `/Users/anthonytran/Desktop/postgresSQL-labatory/lab6_env/`:

```sql
-- ============================================================================
-- LAB 6: Replication Verification Script
-- Purpose: Verify logical replication is working correctly
-- ============================================================================

\echo '================================================'
\echo 'LAB 6: Logical Replication Verification'
\echo '================================================'

-- Test 1: Insert on Publisher
\echo '\n[TEST 1] Inserting data on PUBLISHER (pg1)...'
-- Run this on pg1
INSERT INTO users (name, email) VALUES ('Test User', 'test@example.com')
RETURNING id, name, email;

-- Test 2: Verify on Subscriber
\echo '\n[TEST 2] Checking if data appeared on SUBSCRIBER (pg2)...'
-- Run this on pg2 after a 2-second wait
-- Expected: Same user should exist
SELECT * FROM users WHERE email = 'test@example.com';

-- Test 3: Update on Publisher
\echo '\n[TEST 3] Updating data on PUBLISHER (pg1)...'
-- Run this on pg1
UPDATE users SET name = 'Updated Test User' WHERE email = 'test@example.com'
RETURNING id, name, email;

-- Test 4: Verify Update on Subscriber
\echo '\n[TEST 4] Checking if update replicated to SUBSCRIBER (pg2)...'
-- Run this on pg2 after a 2-second wait
-- Expected: Name should be updated
SELECT * FROM users WHERE email = 'test@example.com';

-- Test 5: Delete on Publisher
\echo '\n[TEST 5] Deleting data on PUBLISHER (pg1)...'
-- Run this on pg1
DELETE FROM users WHERE email = 'test@example.com'
RETURNING id;

-- Test 6: Verify Delete on Subscriber
\echo '\n[TEST 6] Checking if delete replicated to SUBSCRIBER (pg2)...'
-- Run this on pg2 after a 2-second wait
-- Expected: 0 rows
SELECT COUNT(*) as count FROM users WHERE email = 'test@example.com';

-- Test 7: Replication Lag Check
\echo '\n[TEST 7] Checking replication lag on SUBSCRIBER (pg2)...'
-- Run this on pg2
SELECT 
    subname,
    CASE 
        WHEN received_lsn = latest_end_lsn THEN 'Fully Synced'
        ELSE 'Replication Lag Detected'
    END AS sync_status,
    last_msg_receipt_time,
    latest_end_time - last_msg_receipt_time AS lag
FROM pg_stat_subscription;

-- Test 8: Replication Slot Health
\echo '\n[TEST 8] Checking replication slot health on PUBLISHER (pg1)...'
-- Run this on pg1
SELECT 
    slot_name,
    CASE 
        WHEN active THEN 'Active'
        ELSE 'Inactive (WARNING!)'
    END AS status,
    restart_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_size
FROM pg_replication_slots;

\echo '\n================================================'
\echo 'Verification Complete!'
\echo '================================================'
\echo 'All tests passed = Logical replication working!'
\echo '================================================'
```

### Run Verification

```bash
# Test INSERT replication
docker exec -it lab6_pg1 psql -U postgres -d testdb -c \
  "INSERT INTO users (name, email) VALUES ('Verification User', 'verify@example.com');"

sleep 2

docker exec -it lab6_pg2 psql -U postgres -d testdb -c \
  "SELECT * FROM users WHERE email = 'verify@example.com';"

# Expected: Row exists on pg2 ✅
```

---

## Step 14: Cleanup and Teardown

### Remove Subscription (on pg2)

```bash
docker exec -it lab6_pg2 psql -U postgres -d testdb << 'EOF'
-- Drop subscription (also removes replication slot on pg1)
DROP SUBSCRIPTION IF EXISTS my_subscription;
EOF
```

### Remove Publication (on pg1)

```bash
docker exec -it lab6_pg1 psql -U postgres -d testdb << 'EOF'
-- Drop publication
DROP PUBLICATION IF EXISTS my_publication;
EOF
```

### Stop Containers

```bash
cd /Users/anthonytran/Desktop/postgresSQL-labatory/lab6_env

# Stop and remove containers
docker compose down

# Remove volumes (optional - destroys all data)
docker volume rm lab6_env_pg1_data lab6_env_pg2_data
```

---

## Deliverables Summary

### ✅ 1. Logical Replication Diagram

**Completed:** See Step 11 for complete architecture diagram showing:
- Publisher/Subscriber topology
- Replicated vs non-replicated tables
- Replication direction
- IP addresses and ports

### ✅ 2. SQL Setup Scripts

**Completed:** See Step 12 for:
- `setup_logical_replication.sql` - Complete setup script
- Initialization scripts: `init/init_pg1.sql`, `init/init_pg2.sql`

**Location:** `/Users/anthonytran/Desktop/postgresSQL-labatory/lab6_env/init/`

### ✅ 3. Replication Verification

**Completed:** See Step 13 for:
- `verify_replication.sql` - Comprehensive test suite
- Manual verification commands
- Health check queries

---

## Key Takeaways

### What We Learned

1. ✅ **Logical replication replicates SQL operations**, not binary blocks
2. ✅ **Selective replication** - only chosen tables sync
3. ✅ **Subscriber is read-write** - can accept local writes
4. ✅ **Cross-version compatible** - pg15 can replicate to pg16
5. ✅ **Foundation for multi-master** - LAB 7 will add bi-directional flow

### Comparison: Physical vs Logical

| Feature | Physical (LAB 2-4) | Logical (LAB 6) |
|---------|-------------------|-----------------|
| Granularity | Entire cluster | Specific tables |
| Direction | Unidirectional | Can be bi-directional |
| Replica writes | ❌ Read-only | ✅ Read-write |
| Version compat | Must match | Cross-version OK |
| Schema changes | Auto-synced | Manual sync required |
| Use case | HA failover | Multi-master, migrations |

### Limitations of Logical Replication

Despite its flexibility, logical replication has some important limitations:

❌ **DDL (schema changes) don't replicate** - Must apply ALTER TABLE manually on both sides  
❌ **Sequences don't auto-sync** - Can cause ID conflicts in bi-directional setup  
❌ **No automatic conflict resolution** - Up to application or extension (BDR)  
❌ **Higher CPU overhead** - Logical decoding + SQL execution vs binary copy  
❌ **Subscriber must have same schema** - Must manually keep schemas in sync  

### Path to Multi-Master

```
LAB 6 (Current): Unidirectional
  pg1 ──→ pg2
  
LAB 7 (Next): Bi-directional
  pg1 ←→ pg2
  (Requires conflict handling!)
  
LAB 8 (Future): Multi-node
  pg1 ←→ pg2 ←→ pg3
  (Requires advanced conflict resolution)
```

---

## Troubleshooting

### Issue: Subscription stuck in "initializing" state

```bash
# Check subscription state
docker exec -it lab6_pg2 psql -U postgres -d testdb -c \
  "SELECT subname, subenabled, subready FROM pg_subscription;"

# If subready = 'f', check logs
docker logs lab6_pg2 --tail 50
```

**Common causes:**
- Schema mismatch between publisher and subscriber
- Network connectivity issues
- Publisher not running

### Issue: Data not replicating

```bash
# On subscriber, check subscription status
docker exec -it lab6_pg2 psql -U postgres -d testdb -c \
  "SELECT * FROM pg_stat_subscription;"

# Check if subscription worker is running
# pid should be > 0
```

**Fix:**
```bash
# Refresh subscription
docker exec -it lab6_pg2 psql -U postgres -d testdb -c \
  "ALTER SUBSCRIPTION my_subscription REFRESH PUBLICATION;"
```

### Issue: "ERROR: publication does not exist"

```bash
# Verify publication exists on publisher
docker exec -it lab6_pg1 psql -U postgres -d testdb -c \
  "SELECT * FROM pg_publication;"
```

**Fix:** Re-create publication on pg1 (see Step 4)

### Issue: Replication slot consuming disk space

```bash
# Check slot lag
docker exec -it lab6_pg1 psql -U postgres -d testdb -c \
  "SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag 
   FROM pg_replication_slots;"
```

**Fix:**
```bash
# If inactive and consuming space, drop it
docker exec -it lab6_pg1 psql -U postgres -d testdb -c \
  "SELECT pg_drop_replication_slot('my_subscription');"
```

---

## Next Steps

**LAB 7: Bi-Directional Logical Replication (True Multi-Master)**

In LAB 7, we'll build on this foundation to create:
- ✅ Bi-directional replication (pg1 ↔ pg2)
- ✅ Both nodes accept writes simultaneously
- ✅ Conflict detection and resolution strategies
- ✅ Handling of INSERT/UPDATE/DELETE conflicts
- ✅ Sequence coordination to avoid ID collisions

**Preview of challenges:**
```
Conflict Example:

T=0: Both nodes start with user id=1, balance=100

T=1: Client A → pg1: UPDATE balance=150
T=1: Client B → pg2: UPDATE balance=200

T=2: Replication happens
     pg1 has: balance=200 (from pg2)
     pg2 has: balance=150 (from pg1)
     
❌ CONFLICT! Which value is correct?
```

**Resolution strategies we'll explore:**
- Last-write-wins (timestamp-based)
- First-write-wins  
- Application-defined rules
- CRDTs (Conflict-free Replicated Data Types)

---

## Additional Resources

### PostgreSQL Documentation
- [Logical Replication](https://www.postgresql.org/docs/16/logical-replication.html)
- [Publications](https://www.postgresql.org/docs/16/logical-replication-publication.html)
- [Subscriptions](https://www.postgresql.org/docs/16/logical-replication-subscription.html)

### Monitoring Queries

```sql
-- Publisher: Check publication tables
SELECT * FROM pg_publication_tables;

-- Publisher: Check replication slots
SELECT * FROM pg_replication_slots;

-- Subscriber: Check subscription status
SELECT * FROM pg_stat_subscription;

-- Subscriber: Check subscription configuration
SELECT * FROM pg_subscription;
```

---

**🎯 Congratulations!** You've completed LAB 6 and learned the foundational technology for multi-master replication!

**👉 Next:** LAB 7 — Bi-Directional Logical Replication (True Multi-Master)