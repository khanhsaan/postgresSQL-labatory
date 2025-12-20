CREATE TABLE wal_test(
    id SERIAL PRIMARY KEY,
    message TEXT
);

INSERT INTO wal_test(message)
SELECT 'message' || generate_series(1, 10000);