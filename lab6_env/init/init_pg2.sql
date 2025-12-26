-- init_pg2.sql
-- This runs automatically when pg2 container starts

-- Create IDENTICAL schema for tables we want to replicate
-- CRITICAL: Schema must match on subscriber!
CREATE TABLE users
(
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE orders
(
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    product VARCHAR(100) NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Subscriber can have its own local tables
CREATE TABLE subscriber_logs
(
    id SERIAL PRIMARY KEY,
    message TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Configure sequences for pg1 to use ODD numbers
ALTER SEQUENCE users_id_seq RESTART WITH 2 INCREMENT by 2;
ALTER SEQUENCE orders_id_seq RESTART WITH 2 INCREMENT by 2;

INSERT INTO subscriber_logs
    (message)
VALUES
    ('Subscriber initialized'),
    ('Waiting for replication setup');

-- Show what we created
SELECT 'Subscriber (pg2) initialized:' AS status;
SELECT 'Users table (empty):' AS info, COUNT(*) AS count
FROM users;
SELECT 'Orders table (empty):' AS info, COUNT(*) AS count
FROM orders;