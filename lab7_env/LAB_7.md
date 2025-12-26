# LAB 7 — Bidirectional Replication (Mini Multi-Master)

**Goal:** Implement true bidirectional replication - your first real multi-master experience where both nodes can accept writes simultaneously.

By the end of Lab 7, you will:
- Configure bidirectional logical replication between two PostgreSQL nodes
- Understand replication origin filtering (prevents infinite loops)
- Enable writes from both nodes simultaneously
- Identify and handle basic conflicts
- Understand the limitations of native PostgreSQL logical replication
- Build the foundation for production multi-master systems

---

## Why Bidirectional Replication?

### The Evolution

```
LAB 2-4: Single Primary (HA Failover)
  Primary → Replica (read-only)
  ❌ Only one node accepts writes
  ❌ Failover causes 30-60s downtime

LAB 6: Unidirectional Logical Replication  
  pg1 (pub) → pg2 (sub)
  ✅ pg2 can write, but changes don't go back to pg1
  ❌ Still not true multi-master

LAB 7: Bidirectional Replication (THIS LAB)
  pg1 ↔ pg2
  ✅ Both nodes accept writes
  ✅ Changes replicate in both directions
  ✅ True multi-master (with limitations)
```

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│          BIDIRECTIONAL LOGICAL REPLICATION                   │
│                                                              │
│  ┌────────────────────┐         ┌────────────────────┐      │
│  │   Node 1 (pg1)     │         │   Node 2 (pg2)     │      │
│  │  Publisher + Sub   │ ◄─────► │  Publisher + Sub   │      │
│  ├────────────────────┤         ├────────────────────┤      │
│  │                    │         │                    │      │
│  │  Publication:      │         │  Publication:      │      │
│  │  pg1_publication   │────────►│  (subscribes to    │      │
│  │                    │         │   pg1_publication) │      │
│  │                    │         │                    │      │
│  │  Subscription:     │◄────────│  pg2_publication   │      │
│  │  pg2_subscription  │         │                    │      │
│  │  (subscribes to    │         │                    │      │
│  │   pg2_publication) │         │                    │      │
│  │                    │         │                    │      │
│  │  Sequence: ODD     │         │  Sequence: EVEN    │      │
│  │  (1,3,5,7...)      │         │  (2,4,6,8...)      │      │
│  │                    │         │                    │      │
│  └────────────────────┘         └────────────────────┘      │
│                                                              │
│  Key Feature: Replication Origin Filtering                  │
│  - pg1 won't re-replicate changes that came from pg2        │
│  - pg2 won't re-replicate changes that came from pg1        │
│  - Prevents infinite replication loops!                     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### The Infinite Loop Problem (and Solution)

**Without origin filtering:**
```
1. User writes to pg1: INSERT id=1
2. pg1 replicates to pg2: INSERT id=1
3. pg2 sees it as a new change, replicates back to pg1: INSERT id=1
4. pg1 sees it as a new change, replicates to pg2: INSERT id=1
5. INFINITE LOOP! 💥
```

**With origin filtering (built-in to PostgreSQL):**
```
1. User writes to pg1: INSERT id=1 (origin=local)
2. pg1 replicates to pg2: INSERT id=1 (origin=pg1)
3. pg2 receives, marks origin=pg1
4. pg2's subscription to pg1 filters out origin=pg1 changes
5. ✅ No loop! Change stops propagating
```

---

## Prerequisites

### Clean Slate

```bash
cd /Users/anthonytran/Desktop/postgresSQL-labatory/lab7_env

# Stop any previous labs
cd ..
docker compose -f lab6_env/docker-compose.yml down 2>/dev/null || true
docker compose -f docker-compose-patroni.yml down 2>/dev/null || true

# Return to lab7
cd lab7_env
```

---

## Step 1: Create Docker Compose for Bidirectional Setup

Create `docker-compose.yml` in `/Users/anthonytran/Desktop/postgresSQL-labatory/lab7_env/`:

```yaml
services:
  pg1:
    image: postgres:16
    container_name: lab7_pg1
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
      - bidirectional_net
    command:
      - "postgres"
      - "-c"
      - "wal_level=logical"
      - "-c"
      - "max_replication_slots=10"
      - "-c"
      - "max_wal_senders=10"
      - "-c"
      - "shared_preload_libraries=pg_stat_statements"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d testdb"]
      interval: 5s
      timeout: 5s
      retries: 5

  pg2:
    image: postgres:16
    container_name: lab7_pg2
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
      - bidirectional_net
    command:
      - "postgres"
      - "-c"
      - "wal_level=logical"
      - "-c"
      - "max_replication_slots=10"
      - "-c"
      - "max_wal_senders=10"
      - "-c"
      - "shared_preload_libraries=pg_stat_statements"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d testdb"]
      interval: 5s
      timeout: 5s
      retries: 5

networks:
  bidirectional_net:
    driver: bridge

volumes:
  pg1_data:
  pg2_data:
```

**Key Configuration:**
- `max_replication_slots=10` - Increased for bidirectional setup (each node has pub & sub)
- `max_wal_senders=10` - Support multiple concurrent replication connections
- Both nodes have identical configuration (symmetric setup)

---

## Step 2: Create Initialization Scripts

### Create `init/init_pg1.sql` (Node 1)

```bash
mkdir -p /Users/anthonytran/Desktop/postgresSQL-labatory/lab7_env/init
```

Create `/Users/anthonytran/Desktop/postgresSQL-labatory/lab7_env/init/init_pg1.sql`:

```sql
-- init_pg1.sql
-- Initialize pg1 for bidirectional replication

-- Create schema
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    node_origin VARCHAR(10),  -- Track which node created this record
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    product VARCHAR(100) NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    node_origin VARCHAR(10),
    created_at TIMESTAMP DEFAULT NOW()
);

-- Configure sequences for pg1 to use ODD numbers
ALTER SEQUENCE users_id_seq RESTART WITH 1 INCREMENT BY 2;
ALTER SEQUENCE orders_id_seq RESTART WITH 1 INCREMENT BY 2;

-- Insert initial data with node_origin tracking
INSERT INTO users (name, email, node_origin) VALUES 
    ('Alice', 'alice@example.com', 'pg1'),
    ('Bob', 'bob@example.com', 'pg1'),
    ('Charlie', 'charlie@example.com', 'pg1');

INSERT INTO orders (user_id, product, amount, node_origin) VALUES 
    (1, 'Laptop', 1200.00, 'pg1'),
    (1, 'Mouse', 25.00, 'pg1');

-- Show initialization
SELECT 'pg1 initialized with ODD IDs' AS status;
SELECT id, name, node_origin FROM users ORDER BY id;
SELECT 'Sequence config:' AS info, last_value, increment_by FROM users_id_seq;
```

### Create `init/init_pg2.sql` (Node 2)

Create `/Users/anthonytran/Desktop/postgresSQL-labatory/lab7_env/init/init_pg2.sql`:

```sql
-- init_pg2.sql
-- Initialize pg2 for bidirectional replication

-- Create IDENTICAL schema
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    node_origin VARCHAR(10),
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    product VARCHAR(100) NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    node_origin VARCHAR(10),
    created_at TIMESTAMP DEFAULT NOW()
);

-- Configure sequences for pg2 to use EVEN numbers
ALTER SEQUENCE users_id_seq RESTART WITH 2 INCREMENT BY 2;
ALTER SEQUENCE orders_id_seq RESTART WITH 2 INCREMENT BY 2;

-- Insert initial data with node_origin tracking
INSERT INTO users (name, email, node_origin) VALUES 
    ('David', 'david@example.com', 'pg2'),
    ('Eve', 'eve@example.com', 'pg2');

INSERT INTO orders (user_id, product, amount, node_origin) VALUES 
    (2, 'Keyboard', 75.00, 'pg2');

-- Show initialization
SELECT 'pg2 initialized with EVEN IDs' AS status;
SELECT id, name, node_origin FROM users ORDER BY id;
SELECT 'Sequence config:' AS info, last_value, increment_by FROM users_id_seq;
```

---

## Step 3: Start the Containers

```bash
cd /Users/anthonytran/Desktop/postgresSQL-labatory/lab7_env

# Start both nodes
docker compose up -d

# Wait for initialization
echo "Waiting for PostgreSQL to initialize..."
sleep 15

# Verify both nodes are running
docker ps | grep lab7
```

### Verify Initial State

```bash
# Check pg1
docker exec -i lab7_pg1 psql -U postgres -d testdb -c "
SELECT id, name, node_origin FROM users ORDER BY id;
"

# Expected: 1-Alice, 3-Bob, 5-Charlie (all node_origin='pg1')

# Check pg2
docker exec -i lab7_pg2 psql -U postgres -d testdb -c "
SELECT id, name, node_origin FROM users ORDER BY id;
"

# Expected: 2-David, 4-Eve (all node_origin='pg2')
```

---

## Step 4: Set Up Bidirectional Replication

### Step 4a: Create Publication on pg1

```bash
docker exec -i lab7_pg1 psql -U postgres -d testdb << 'EOF'
-- Create publication on pg1
CREATE PUBLICATION pg1_publication 
FOR TABLE users, orders;

-- Verify
SELECT * FROM pg_publication;
SELECT * FROM pg_publication_tables;
EOF
```

### Step 4b: Create Publication on pg2

```bash
docker exec -i lab7_pg2 psql -U postgres -d testdb << 'EOF'
-- Create publication on pg2
CREATE PUBLICATION pg2_publication 
FOR TABLE users, orders;

-- Verify
SELECT * FROM pg_publication;
SELECT * FROM pg_publication_tables;
EOF
```

### Step 4c: Create Subscription on pg1 (subscribes to pg2)

```bash
docker exec -i lab7_pg1 psql -U postgres -d testdb << 'EOF'
-- pg1 subscribes to pg2's publication
CREATE SUBSCRIPTION pg2_subscription
CONNECTION 'host=pg2 port=5432 dbname=testdb user=postgres password=postgres'
PUBLICATION pg2_publication
WITH (copy_data = true, origin = none);

-- Wait a moment for initial sync
SELECT pg_sleep(3);

-- Verify subscription
SELECT subname, subenabled, subpublications FROM pg_subscription;

-- Check replication status
SELECT subname, pid, received_lsn, latest_end_lsn 
FROM pg_stat_subscription;
EOF
```

**Important:** `origin = none` means "only replicate local changes from pg2, not changes pg2 received from elsewhere". This is key for preventing loops!

### Step 4d: Create Subscription on pg2 (subscribes to pg1)

```bash
docker exec -i lab7_pg2 psql -U postgres -d testdb << 'EOF'
-- pg2 subscribes to pg1's publication
CREATE SUBSCRIPTION pg1_subscription
CONNECTION 'host=pg1 port=5432 dbname=testdb user=postgres password=postgres'
PUBLICATION pg1_publication
WITH (copy_data = true, origin = none);

-- Wait a moment for initial sync
SELECT pg_sleep(3);

-- Verify subscription
SELECT subname, subenabled, subpublications FROM pg_subscription;

-- Check replication status
SELECT subname, pid, received_lsn, latest_end_lsn 
FROM pg_stat_subscription;
EOF
```

---

## Step 5: Verify Bidirectional Initial Sync

### Check pg1 (should have data from both nodes)

```bash
docker exec -i lab7_pg1 psql -U postgres -d testdb << 'EOF'
SELECT 'Data on pg1 after bidirectional setup:' AS status;
SELECT id, name, email, node_origin FROM users ORDER BY id;
EOF
```

**Expected output:**
```
 id |  name   |       email        | node_origin 
----+---------+--------------------+-------------
  1 | Alice   | alice@example.com  | pg1          ← Local
  2 | David   | david@example.com  | pg2          ← From pg2!
  3 | Bob     | bob@example.com    | pg1          ← Local
  4 | Eve     | eve@example.com    | pg2          ← From pg2!
  5 | Charlie | charlie@example.com| pg1          ← Local
```

✅ **Success!** pg1 now has data from both itself AND pg2!

### Check pg2 (should have data from both nodes)

```bash
docker exec -i lab7_pg2 psql -U postgres -d testdb << 'EOF'
SELECT 'Data on pg2 after bidirectional setup:' AS status;
SELECT id, name, email, node_origin FROM users ORDER BY id;
EOF
```

**Expected output:**
```
 id |  name   |       email        | node_origin 
----+---------+--------------------+-------------
  1 | Alice   | alice@example.com  | pg1          ← From pg1!
  2 | David   | david@example.com  | pg2          ← Local
  3 | Bob     | bob@example.com    | pg1          ← From pg1!
  4 | Eve     | eve@example.com    | pg2          ← Local
  5 | Charlie | charlie@example.com| pg1          ← From pg1!
```

✅ **Success!** pg2 now has data from both itself AND pg1!

---

## Step 6: Test Bidirectional Writes

### Test 6a: Write to pg1, verify on pg2

```bash
docker exec -i lab7_pg1 psql -U postgres -d testdb << 'EOF'
-- Insert on pg1
INSERT INTO users (name, email, node_origin) 
VALUES ('Frank', 'frank@example.com', 'pg1');

SELECT 'Inserted on pg1:' AS status;
SELECT id, name, node_origin FROM users WHERE name = 'Frank';
EOF
```

**Expected:** id=7 (next odd number), node_origin='pg1'

Wait for replication, then check pg2:

```bash
sleep 2

docker exec -i lab7_pg2 psql -U postgres -d testdb << 'EOF'
SELECT 'Checking pg2 for Frank:' AS status;
SELECT id, name, node_origin FROM users WHERE name = 'Frank';
EOF
```

**Expected:** ✅ Frank appears on pg2 with id=7, node_origin='pg1'

### Test 6b: Write to pg2, verify on pg1

```bash
docker exec -i lab7_pg2 psql -U postgres -d testdb << 'EOF'
-- Insert on pg2
INSERT INTO users (name, email, node_origin) 
VALUES ('Grace', 'grace@example.com', 'pg2');

SELECT 'Inserted on pg2:' AS status;
SELECT id, name, node_origin FROM users WHERE name = 'Grace';
EOF
```

**Expected:** id=6 (next even number), node_origin='pg2'

Wait for replication, then check pg1:

```bash
sleep 2

docker exec -i lab7_pg1 psql -U postgres -d testdb << 'EOF'
SELECT 'Checking pg1 for Grace:' AS status;
SELECT id, name, node_origin FROM users WHERE name = 'Grace';
EOF
```

**Expected:** ✅ Grace appears on pg1 with id=6, node_origin='pg2'

### Test 6c: Simultaneous writes (the real test!)

```bash
# Write to BOTH nodes at the same time
docker exec -i lab7_pg1 psql -U postgres -d testdb -c "
INSERT INTO users (name, email, node_origin) VALUES ('Henry', 'henry@example.com', 'pg1');
" &

docker exec -i lab7_pg2 psql -U postgres -d testdb -c "
INSERT INTO users (name, email, node_origin) VALUES ('Iris', 'iris@example.com', 'pg2');
" &

# Wait for both to complete
wait

echo "Waiting for replication..."
sleep 3

# Check both nodes have both records
docker exec -i lab7_pg1 psql -U postgres -d testdb -c "
SELECT id, name, node_origin FROM users WHERE name IN ('Henry', 'Iris') ORDER BY id;
"

docker exec -i lab7_pg2 psql -U postgres -d testdb -c "
SELECT id, name, node_origin FROM users WHERE name IN ('Henry', 'Iris') ORDER BY id;
"
```

**Expected on BOTH nodes:**
```
 id | name  | node_origin 
----+-------+-------------
  8 | Iris  | pg2          ← Even (from pg2)
  9 | Henry | pg1          ← Odd (from pg1)
```

✅ **TRUE MULTI-MASTER!** Both nodes accepted writes simultaneously and both now have all data!

---

## Step 7: Understanding Replication Origin Filtering

### View Replication Origins

```bash
# On pg1, check where data came from
docker exec -i lab7_pg1 psql -U postgres -d testdb << 'EOF'
-- View replication origins
SELECT 
    local_id,
    external_id,
    remote_lsn,
    local_lsn
FROM pg_replication_origin;

-- Show replication origin names
SELECT 
    roident,
    roname
FROM pg_replication_origin_status;
EOF
```

**Expected output:**
```
 local_id | external_id | remote_lsn | local_lsn 
----------+-------------+------------+-----------
        1 | pg2_sub     | 0/1A2B3C4D | 0/1E2F3A4B

 roident |          roname           
---------+---------------------------
       1 | pg_pg2_subscription
```

This shows pg1 is tracking changes received from pg2 via the `pg2_subscription`.

### How Origin Filtering Prevents Loops

```
┌──────────────────────────────────────────────────────────────┐
│  Without Origin Filtering (INFINITE LOOP)                     │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  1. User → pg1: INSERT (id=9, name='Test')                   │
│  2. pg1 → pg2: Replicate INSERT (id=9)                       │
│  3. pg2 receives, stores INSERT (id=9)                       │
│  4. pg2 thinks: "New local change, must replicate!"          │
│  5. pg2 → pg1: Replicate INSERT (id=9) ← DUPLICATE!         │
│  6. pg1 receives: ERROR or infinite loop! 💥                 │
│                                                               │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  With Origin Filtering (CORRECT)                             │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  1. User → pg1: INSERT (id=9, name='Test')                   │
│     Origin: local (not from replication)                     │
│                                                               │
│  2. pg1 → pg2: Replicate INSERT (id=9)                       │
│     Marks: origin=pg1_subscription                           │
│                                                               │
│  3. pg2 receives, stores INSERT (id=9)                       │
│     Tags it with: origin=pg1_subscription                    │
│                                                               │
│  4. pg2's subscription to pg1 checks:                        │
│     "Does this have origin=pg1_subscription? YES"            │
│     "Then DON'T replicate it back!" ✓                        │
│                                                               │
│  5. Loop prevented! ✓                                        │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

### The `origin = none` Parameter Explained

When we created subscriptions with `origin = none`:

```sql
CREATE SUBSCRIPTION pg2_subscription
CONNECTION 'host=pg2 ...'
PUBLICATION pg2_publication
WITH (copy_data = true, origin = none);  ← This parameter!
```

**What `origin = none` means:**
- Only replicate changes that originated locally on the publisher
- Do NOT replicate changes that the publisher received from elsewhere
- This prevents replication loops in bidirectional setups

**Alternative values:**
- `origin = any` - Replicate all changes (dangerous in bidirectional!)
- `origin = none` - Only local changes (safe for bidirectional) ✓

---

## Step 8: Test UPDATE and DELETE Operations

### Test UPDATE

```bash
# Update on pg1
docker exec -i lab7_pg1 psql -U postgres -d testdb << 'EOF'
UPDATE users 
SET name = 'Alice Smith', updated_at = NOW() 
WHERE id = 1;

SELECT id, name, updated_at FROM users WHERE id = 1;
EOF

# Wait and check pg2
sleep 2

docker exec -i lab7_pg2 psql -U postgres -d testdb << 'EOF'
SELECT 'After UPDATE on pg1:' AS status;
SELECT id, name, updated_at FROM users WHERE id = 1;
EOF
```

**Expected:** ✅ UPDATE replicated to pg2

### Test DELETE

```bash
# Delete on pg2
docker exec -i lab7_pg2 psql -U postgres -d testdb << 'EOF'
DELETE FROM users WHERE id = 2;

SELECT 'Deleted id=2 on pg2' AS status;
SELECT COUNT(*) as remaining FROM users;
EOF

# Wait and check pg1
sleep 2

docker exec -i lab7_pg1 psql -U postgres -d testdb << 'EOF'
SELECT 'After DELETE on pg2:' AS status;
SELECT id FROM users WHERE id = 2;
SELECT COUNT(*) as remaining FROM users;
EOF
```

**Expected:** ✅ DELETE replicated to pg1, id=2 gone from both nodes

---

## Step 9: Monitor Bidirectional Replication

### Check Replication Status on Both Nodes

```bash
# Check pg1's subscriptions
docker exec -i lab7_pg1 psql -U postgres -d testdb << 'EOF'
SELECT 
    subname,
    subenabled,
    subpublications,
    suborigin
FROM pg_subscription;

SELECT 
    subname,
    pid,
    received_lsn,
    latest_end_lsn,
    last_msg_receipt_time
FROM pg_stat_subscription;
EOF
```

```bash
# Check pg2's subscriptions
docker exec -i lab7_pg2 psql -U postgres -d testdb << 'EOF'
SELECT 
    subname,
    subenabled,
    subpublications,
    suborigin
FROM pg_subscription;

SELECT 
    subname,
    pid,
    received_lsn,
    latest_end_lsn,
    last_msg_receipt_time
FROM pg_stat_subscription;
EOF
```

### Check Replication Slots on Both Nodes

```bash
# Check pg1's replication slots (pg2 is subscribed)
docker exec -i lab7_pg1 psql -U postgres -d testdb << 'EOF'
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

**Expected:** Shows slot created by pg2's subscription

```bash
# Check pg2's replication slots (pg1 is subscribed)
docker exec -i lab7_pg2 psql -U postgres -d testdb << 'EOF'
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

**Expected:** Shows slot created by pg1's subscription

---

## Step 10: Understanding Conflicts (Deliverable: Known Limitations)

### Conflict Scenarios

Even with bidirectional replication, conflicts can occur:

#### Conflict Type 1: UPDATE-UPDATE Conflict

```
T=0: Both nodes have user id=1, email='alice@example.com'

T=1: pg1: UPDATE users SET email='alice.new@example.com' WHERE id=1;
T=1: pg2: UPDATE users SET email='alice.other@example.com' WHERE id=1;

T=2: Replication happens
     pg1 receives pg2's update → last-write-wins
     pg2 receives pg1's update → last-write-wins

Result: Both nodes have same email, but which one?
        Depends on timing! (non-deterministic)
```

#### Conflict Type 2: INSERT-INSERT Conflict (UNIQUE constraint)

```
T=0: Both nodes have sequence configured

T=1: pg1: INSERT INTO users (name, email) VALUES ('John', 'john@example.com');
T=1: pg2: INSERT INTO users (name, email) VALUES ('Jane', 'john@example.com');
                                                            ↑ Same email!

T=2: Replication happens
     pg1 → pg2: INSERT Jane
     pg2: ERROR! Duplicate key on email='john@example.com'
```

#### Conflict Type 3: DELETE-UPDATE Conflict

```
T=0: Both nodes have user id=5

T=1: pg1: DELETE FROM users WHERE id=5;
T=1: pg2: UPDATE users SET name='Updated' WHERE id=5;

T=2: Replication happens
     pg1 receives UPDATE for id=5 → ERROR! Row doesn't exist
     pg2 receives DELETE for id=5 → Deletes the updated row

Result: Inconsistent state!
```

### Test a Conflict (Educational)

```bash
# Disable subscription temporarily to create conflict
docker exec -i lab7_pg1 psql -U postgres -d testdb -c "
ALTER SUBSCRIPTION pg2_subscription DISABLE;
"

docker exec -i lab7_pg2 psql -U postgres -d testdb -c "
ALTER SUBSCRIPTION pg1_subscription DISABLE;
"

# Make conflicting updates
docker exec -i lab7_pg1 psql -U postgres -d testdb -c "
UPDATE users SET name='Alice Updated on PG1' WHERE id=1;
"

docker exec -i lab7_pg2 psql -U postgres -d testdb -c "
UPDATE users SET name='Alice Updated on PG2' WHERE id=1;
"

# Check divergent state
docker exec -i lab7_pg1 psql -U postgres -d testdb -c "
SELECT id, name FROM users WHERE id=1;
"

docker exec -i lab7_pg2 psql -U postgres -d testdb -c "
SELECT id, name FROM users WHERE id=1;
"

# Re-enable subscriptions (last-write-wins)
docker exec -i lab7_pg1 psql -U postgres -d testdb -c "
ALTER SUBSCRIPTION pg2_subscription ENABLE;
"

docker exec -i lab7_pg2 psql -U postgres -d testdb -c "
ALTER SUBSCRIPTION pg1_subscription ENABLE;
"

# Wait and check final state
sleep 3

docker exec -i lab7_pg1 psql -U postgres -d testdb -c "
SELECT 'Final state on pg1:' AS status;
SELECT id, name FROM users WHERE id=1;
"

docker exec -i lab7_pg2 psql -U postgres -d testdb -c "
SELECT 'Final state on pg2:' AS status;
SELECT id, name FROM users WHERE id=1;
"
```

**Observation:** Both nodes end up with the same value, but it's based on timing (last write wins), not a deterministic conflict resolution strategy.

---

## Step 11: Known Limitations List (Deliverable)

### Critical Limitations of Native PostgreSQL Bidirectional Replication

| Limitation | Description | Impact | Mitigation |
|------------|-------------|--------|------------|
| **No automatic conflict resolution** | PostgreSQL doesn't detect or resolve conflicts automatically | Data inconsistency, replication errors | Application-level conflict avoidance, use BDR extension |
| **Last-write-wins only** | No timestamp-based or custom conflict resolution | Non-deterministic outcomes | Manual conflict handling, use updated_at columns |
| **Sequence coordination required** | Must manually configure non-overlapping sequences | Primary key conflicts | ODD/EVEN or range-based sequences |
| **DDL not replicated** | Schema changes (ALTER TABLE) must be applied manually on each node | Schema drift, replication breaks | Manual DDL coordination, maintenance windows |
| **No conflict detection UI** | No built-in way to detect conflicts happened | Hidden data inconsistencies | Application-level tracking, monitoring |
| **Replication lag** | Changes aren't instant, can be seconds behind | Stale reads, temporary inconsistency | Monitor `pg_stat_subscription`, use sync commit for critical writes |
| **UNIQUE constraint conflicts** | Inserting same unique value on both nodes causes error | Replication stops, manual intervention needed | Application-level coordination, retry logic |
| **Foreign key challenges** | Related records might not exist yet during replication | Referential integrity errors | Defer constraints, careful insert ordering |
| **No automatic failover** | Still need separate HA solution | Downtime if node fails | Combine with Patroni (LAB 4) |
| **Two-node limit (practical)** | Difficult to scale beyond 2 nodes | Scalability ceiling | Use Citus, BDR, or other multi-master solutions |

### When to Use Native Bidirectional Replication

✅ **Good for:**
- Two-datacenter active-active setup
- Read-write workload distribution
- Geographic data distribution with partitioned writes
- Development/testing multi-master concepts

❌ **Avoid for:**
- Applications with frequent conflicts
- More than 2 nodes
- Mission-critical data without conflict resolution
- Real-time financial transactions
- Applications requiring strong consistency

---

## Step 12: Bidirectional Replication Diagram (Deliverable)

```
┌───────────────────────────────────────────────────────────────────────┐
│               LAB 7: BIDIRECTIONAL REPLICATION                         │
│                  (Multi-Master Setup)                                  │
└───────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────┐         ┌─────────────────────────────┐
│   Node 1 (pg1)              │         │   Node 2 (pg2)              │
│   Port: 5433 (host)         │ ◄─────► │   Port: 5434 (host)         │
│   Internal: pg1:5432        │         │   Internal: pg2:5432        │
├─────────────────────────────┤         ├─────────────────────────────┤
│                             │         │                             │
│  📊 Database: testdb        │         │  📊 Database: testdb        │
│                             │         │                             │
│  ✅ ROLE: Publisher + Sub   │         │  ✅ ROLE: Publisher + Sub   │
│                             │         │                             │
│  📤 PUBLICATION:            │         │  📤 PUBLICATION:            │
│  pg1_publication            │────────►│  (pg2 subscribes to this)   │
│  - users                    │         │                             │
│  - orders                   │         │  pg2_publication            │
│                             │◄────────│  - users                    │
│  📥 SUBSCRIPTION:           │         │  - orders                   │
│  pg2_subscription           │         │                             │
│  - subscribes to pg2_pub   │         │  📥 SUBSCRIPTION:           │
│  - origin = none            │         │  pg1_subscription           │
│                             │         │  - subscribes to pg1_pub    │
│  🔄 Replication Slot:       │         │  - origin = none            │
│  pg1_subscription           │         │                             │
│  (created by pg2)           │         │  🔄 Replication Slot:       │
│                             │         │  pg2_subscription           │
│  📝 Sequence: ODD           │         │  (created by pg1)           │
│  (1, 3, 5, 7, 9...)         │         │                             │
│                             │         │  📝 Sequence: EVEN          │
│  🎯 State: Read-Write       │         │  (2, 4, 6, 8, 10...)        │
│  🔓 Accepts: Local Writes   │         │                             │
│  📥 Receives: pg2's writes  │         │  🎯 State: Read-Write       │
│                             │         │  🔓 Accepts: Local Writes   │
│  🗃️ Data Sources:           │         │  📥 Receives: pg1's writes  │
│  - Local: id=1,3,5,7,9...   │         │                             │
│  - From pg2: id=2,4,6,8...  │         │  🗃️ Data Sources:           │
│                             │         │  - Local: id=2,4,6,8,10...  │
└─────────────────────────────┘         │  - From pg1: id=1,3,5,7...  │
                                        └─────────────────────────────┘

Data Flow Example:
──────────────────

1. Client A → pg1: INSERT (id=11, name='User A')
2. pg1 stores locally with origin=local
3. pg1 → pg2: Replicates INSERT (marks origin=pg1_subscription)
4. pg2 receives, stores with origin=pg1_subscription
5. pg2's subscription to pg1 filters: "origin=pg1? Skip replication back"
6. ✅ No loop!

Simultaneously:
1. Client B → pg2: INSERT (id=12, name='User B')
2. pg2 stores locally with origin=local
3. pg2 → pg1: Replicates INSERT (marks origin=pg2_subscription)
4. pg1 receives, stores with origin=pg2_subscription
5. pg1's subscription to pg2 filters: "origin=pg2? Skip replication back"
6. ✅ No loop!

Final State: Both nodes have User A (id=11) and User B (id=12)

Legend:
  ──→  Replication flow direction
  ✅   Enabled feature
  📤   Publication (data source)
  📥   Subscription (data consumer)
  🔄   Replication slot
  📝   Sequence configuration
  🎯   Node state
  🔓   Write capability
  🗃️   Data origin tracking

Key Points:
1. Both nodes are EQUAL (symmetric setup)
2. Both can accept writes simultaneously
3. Changes replicate in BOTH directions
4. origin=none prevents infinite loops
5. ODD/EVEN sequences prevent ID conflicts
6. NO automatic conflict resolution (manual required)
```

---

## Step 13: Cleanup

```bash
cd /Users/anthonytran/Desktop/postgresSQL-labatory/lab7_env

# Stop containers
docker compose down

# Remove volumes (optional)
docker volume rm lab7_env_pg1_data lab7_env_pg2_data
```

---

## Deliverables Summary

### ✅ 1. Working Bidirectional Writes

**Demonstrated:**
- Write to pg1 → replicates to pg2 ✓
- Write to pg2 → replicates to pg1 ✓
- Simultaneous writes to both nodes ✓
- UPDATE and DELETE operations ✓

### ✅ 2. Explanation of Origin Filtering

**Covered in Step 7:**
- What replication origin is
- How `origin = none` prevents loops
- Visual diagrams of loop prevention
- Viewing origin information in PostgreSQL

### ✅ 3. Known Limitations List

**Covered in Step 11:**
- Complete table of limitations
- Impact and mitigation strategies
- When to use/avoid native bidirectional replication
- Conflict scenarios with examples

---

## Key Takeaways

### What We Achieved

1. ✅ **True multi-master setup** - Both nodes accept writes
2. ✅ **Bidirectional replication** - Changes flow both ways
3. ✅ **Loop prevention** - Origin filtering built-in
4. ✅ **No primary key conflicts** - ODD/EVEN sequences work
5. ✅ **Foundation for production** - Understand limits and trade-offs

### What We Learned

| Concept | Learning |
|---------|----------|
| **Bidirectional Setup** | Each node is both publisher and subscriber |
| **Origin Filtering** | Prevents infinite replication loops automatically |
| **Conflict Reality** | Native PostgreSQL has no automatic conflict resolution |
| **Sequence Strategy** | Non-overlapping ranges are critical |
| **Limitations** | Know when NOT to use this approach |

### Production Considerations

**Before using in production:**

1. **Conflict Strategy** - How will you handle conflicts?
   - Partition writes by region/type?
   - Accept last-write-wins?
   - Use application-level locking?

2. **Monitoring** - Watch for:
   - Replication lag (`pg_stat_subscription`)
   - Replication slot growth
   - Sequence exhaustion
   - Error logs for conflict failures

3. **Testing** - Simulate:
   - Network partitions
   - Simultaneous conflicting writes
   - Node failures and recovery
   - Schema change procedures

4. **Consider Alternatives:**
   - **Citus** - Sharding for horizontal scale
   - **BDR (Bi-Directional Replication)** - Enterprise-grade conflict resolution
   - **Patroni + Read Replicas** - If you don't need multi-write
   - **Application-level sharding** - Partition at app layer

---

## Troubleshooting

### Issue: Replication not working

```bash
# Check subscription status
docker exec -i lab7_pg1 psql -U postgres -d testdb -c "
SELECT * FROM pg_stat_subscription;
"

# Look for pid = NULL (not connected)
# Check logs
docker logs lab7_pg1 --tail 50
```

### Issue: Conflict causing replication to stop

```bash
# Check for errors
docker exec -i lab7_pg1 psql -U postgres -d testdb -c "
SELECT subname, subenabled, subworkercount FROM pg_subscription;
"

# Re-sync if needed
docker exec -i lab7_pg1 psql -U postgres -d testdb -c "
ALTER SUBSCRIPTION pg2_subscription DISABLE;
ALTER SUBSCRIPTION pg2_subscription ENABLE;
"
```

### Issue: Sequence conflicts

```bash
# Check sequence values
docker exec -i lab7_pg1 psql -U postgres -d testdb -c "
SELECT last_value, increment_by FROM users_id_seq;
"

# Reset if needed
docker exec -i lab7_pg1 psql -U postgres -d testdb -c "
ALTER SEQUENCE users_id_seq RESTART WITH 1001 INCREMENT BY 2;
"
```

---

## Next Steps

**LAB 8: Multi-Node Replication with Conflict Resolution**

Building on LAB 7, we'll explore:
- 3+ node setups
- Advanced conflict resolution strategies
- Citus for distributed PostgreSQL
- BDR (Bi-Directional Replication) enterprise features
- Production-ready multi-master architectures

**Or Alternative Path:**
- Combine LAB 4 (Patroni) + LAB 7 (Bidirectional) for geo-distributed HA
- Explore pglogical for more advanced features
- Implement application-level conflict resolution

---

**🎯 Congratulations!** You've built a working bidirectional replication system and understand the trade-offs of multi-master architectures!

**👉 Next:** LAB 8 — Advanced Multi-Master with Conflict Resolution