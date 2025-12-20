# LAB 2
By the end of Lab 2, you will:
- Set up primary → standby replication
- Watch WAL flow in real time
- Understand how replicas stay in sync
- Be able to prove replication is working

## Step 1: Decide roles
| Node     | Role           |
| -------- | -------------- |
| pg_node1 | Primary        |
| pg_node2 | Standby        |
| pg_node3 | Unused (later) |

## Step 2: Prepare primary (pg_node1)
What is a Replication User?
A replication user is a special PostgreSQL role that has permission to:
- Connect to the primary database
- Stream WAL (Write-Ahead Log) data
- Copy the entire database during base backup

Think of it as a "service account" specifically for replication tasks.

Create a replication user script `create_repl_user.sql`:
```sql
CREATE ROLE repl_user WITH REPLICATION LOGIN PASSWORD 'repl_pass';
```

Create replication user:
```bash
psql -h localhost -p 5433 -U postgres -d labdb -f /Users/anthonytran/Desktop/postgresSQL-labatory/lab2_env/create_repl_user.sql
```

## Step 3: Configure primary for replication
### Enter container:
```bash
docker exec -it pg_node1 bash
```

### Configure `postgresql.conf`:
```bash
sed -i "s/#wal_level = replica/wal_level = replica/" /var/lib/postgresql/data/postgresql.conf
sed -i "s/#max_wal_senders = 10/max_wal_senders = 5/" /var/lib/postgresql/data/postgresql.conf
sed -i "s/#max_replication_slots = 10/max_replication_slots = 5/" /var/lib/postgresql/data/postgresql.conf
```
### Explaination:

- Command 1: Enable WAL for replication
    ```
    sed -i "s/#wal_level = replica/wal_level = replica/" /var/lib/postgresql/data/postgresql.conf
    ```
- Command 2: Set max WAL senders
    ```
    sed -i "s/#max_wal_senders = 10/max_wal_senders = 5/" /var/lib/postgresql/data/postgresql.conf
    ```
    What `max_wal_senders = 5` means:

    - Allows up to 5 standby servers to connect simultaneously
    - Each standby needs 1 WAL sender process
    - We set it to 5 (enough for this lab, default is 10)

    __Why it matters:__ Without WAL senders, standbys can't connect to receive WAL data.

- __Command 3__: Set max replication slots
    ```
    sed -i "s/#max_replication_slots = 10/max_replication_slots = 5/" /var/lib/postgresql/data/postgresql.conf
    ```

    What `max_replication_slots = 5` means:

    - Replication slots are "bookmarks" that track which WAL data each standby needs
    - If a standby disconnects, the primary keeps the needed WAL files
    - Without slots, the primary might delete WAL files the standby still needs

    __Why it matters__: Prevents data loss if a standby falls behind temporarily.

### Configure `pg_hba.conf`:
```bash
echo "host replication repl_user 0.0.0.0/0 md5" >> /var/lib/postgresql/data/pg_hba.conf
```
### Explaination:
- `host`: Connection type (TCP/IP)
- `replication`: Special database for replication connections (not a real database)
- `0.0.0.0/0`: Allow from any IP address
- `md5`: Use password authentication

    __What it does:__

    - Adds a new rule to the bottom of pg_hba.conf
    - Allows repl_user to make replication connections from any IP

    __Why it matters:__ Without this, repl_user would be rejected even with correct password.

### Exit container and restart pg_node1:
```bash
exit
docker restart pg_node1
```
__Why restart is required:__
- PostgreSQL only reads postgresql.conf and pg_hba.conf at startup
- Some settings (like wal_level) require a full restart
After restart, the new settings take effect
## Step 4: Prepare standby (pg_node2)
⚠️ **This step is destructive by design.**

Stop and remove pg_node2:
```bash
docker stop pg_node2
docker rm pg_node2
```

Remove ALL pg_node2 volumes:
```bash
docker volume rm postgressql-labatory_pg_node2_data
```

Verify only the correct volume prefix exists:
```bash
docker volume ls | grep pg_node2
```

Expected: You should see only volumes with the `postgressql-labatory_` prefix (or none if you removed them all).

## Step 5: Take base backup
This step creates a physical copy of pg_node1's entire data directory and writes it to a new volume for pg_node2. This is the foundation of PostgreSQL replication.

### Run `pg_basebackup` to clone pg_node1's data:
```bash
docker run --rm -it \
  --network postgressql-labatory_default \
  -v postgressql-labatory_pg_node2_data:/var/lib/postgresql/data \
  postgres:16 \
  pg_basebackup \
    -h pg_node1 \
    -U repl_user \
    -D /var/lib/postgresql/data \
    -Fp -Xs -P -R
```

Password: `repl_pass`

### **What this does:**
- Connects to pg_node1 over the Docker network
- Takes a physical backup of the entire data directory
- Writes it to the new volume `postgressql-labatory_pg_node2_data`
- `-R` (Recovery/Standby mode) ⭐ Most Important!
    1. `standby.signal`
        - Empty file that tells PostgreSQL "I'm a standby"
        - Without this file, pg_node2 would start as an independent primary
    2. `postgresql.auto.conf`
        - Contains replication connection setting
        - Tells pg_node2 how to connect to pg_node1 for streaming

### __Why this approach?__

You might wonder: "Why not just copy files with docker cp?"

__Because__:

1. __Consistency__: pg_basebackup ensures a consistent snapshot (all files at the same point in time)
2. __WAL coordination__: Automatically includes the right WAL files
3. __Automatic config__: -R flag sets up standby mode
4. __Safe__: PostgreSQL validates the backup is usable

Manual file copying could result in an inconsistent, unusable backup.

### Expected output:
```
31595/31595 kB (100%), 1/1 tablespace
```

## Step 6: Start pg_node2 as standby

Ensure you're in the correct directory:
```bash
cd /Users/anthonytran/Desktop/postgresSQL-labatory
ls  # Should show docker-compose.yml
```

Start pg_node2:
```bash
docker compose up -d pg_node2
```

**What this does:**
- Recreates the container
- PostgresSQL automatically recognises and attach the volume you just populated with the base backup (`postgressql-labatory_pg_node2_data`) to `pg_node2`
- Starts PostgreSQL as a standby (because of `standby.signal` file)

This mirrors real HA workflows: **destroy replica → reseed → rejoin cluster**

## Step 7: Verify replication

Connect to pg_node1:
```bash
psql -h localhost -p 5433 -U postgres -d labdb
```

Check replication status:
```sql
SELECT client_addr, state, sync_state
FROM pg_stat_replication;
```

✅ **Expected output:**
```
 client_addr |  state     | sync_state
-------------+------------+-----------
 172.xx.xx.x | streaming  | async
```

🎉 **You should see 1 row showing pg_node2 is streaming!**

If you see `(0 rows)`, troubleshoot:
```bash
# Check pg_node2 logs
docker logs pg_node2

# Verify network connectivity
docker exec pg_node2 ping pg_node1

# Check standby status on pg_node2
docker exec -it pg_node2 psql -U postgres -c "SELECT pg_is_in_recovery();"
# Should return: t (true)
```

## Step 8: Test replication
Create `create_reql_test.sql`
```sql
CREATE TABLE repl_test(
    id SERIAL,
    msg TEXT
);

INSERT INTO repl_test(msg)
VALUES('Hello from primary');
```

On **primary (pg_node1)**:
```bash
psql -h localhost -p 5433 -U postgres -d labdb -f /Users/anthonytran/Desktop/postgresSQL-labatory/lab2_env/create_repl_test.sql
```

On **standby (pg_node2)**:
```bash
psql -h localhost -p 5434 -U postgres -d labdb
```

```sql
SELECT * FROM repl_test;
```

✅ **You should see the data!**

⚠️ **Note:** Standby is read-only. Try inserting on pg_node2 and you'll get:
```
ERROR: cannot execute INSERT in a read-only transaction
```

## Common Issues

**Network not found:**
```
Error response from daemon: network postgressql-labatory_default not found
```
Solution: Make sure pg_node1 is running to create the network:
```bash
docker compose up -d pg_node1
```

**Wrong volume attached:**
Check which volume is attached:
```bash
docker inspect pg_node2 | grep -A 10 Mounts
```

**Replication not working:**
1. Check pg_node1 has `wal_level = replica` and was restarted
2. Check `pg_hba.conf` allows replication connections
3. Check pg_node2 logs: `docker logs pg_node2`
4. Verify `standby.signal` exists: `docker exec pg_node2 ls /var/lib/postgresql/data/standby.signal`