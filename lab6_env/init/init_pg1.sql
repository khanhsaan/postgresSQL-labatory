-- init_pg1.sql
-- This runs automatically when pg1 container starts

-- Create schema
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

-- This table will NOT be replicated (to demonstrate selective replication)
CREATE TABLE local_logs
(
    id SERIAL PRIMARY KEY,
    message TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Configure sequences for pg1 to use ODD numbers
ALTER SEQUENCE users_id_seq RESTART WITH 1 INCREMENT by 2;
ALTER SEQUENCE orders_id_seq RESTART WITH 1 INCREMENT by 2;

-- Insert initial data on publisher
INSERT INTO users
    (name, email)
VALUES
    ('Alice', 'alice@example.com'),
    ('Bob', 'bob@example.com'),
    ('Charlie', 'charlie@example.com');

INSERT INTO orders
    (user_id, product, amount)
VALUES
    (1, 'Laptop', 1200.00),
    (1, 'Mouse', 25.00),
    (1, 'Keyboard', 75.00);

INSERT INTO local_logs
    (message)
VALUES
    ('Publisher initialized'),
    ('Initial data loaded');

-- Show what we created
SELECT 'Publisher (pg1) initialized:' AS status;
SELECT 'Users table:' AS info, COUNT(*) AS count
FROM users;
SELECT 'Orders table:' AS info, COUNT(*) AS count
FROM orders;
SELECT 'Local logs table:' AS info, COUNT(*) AS count
FROM local_logs;