CREATE TABLE HealthCheck(
    id SERIAL PRIMARY KEY,
    node_name TEXT,
    created_at TIMESTAMP DEFAULT now()
);

INSERT INTO HealthCheck(node_name)
VALUES('pg_node1');