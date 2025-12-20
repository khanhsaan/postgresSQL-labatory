CREATE TABLE repl_test(
    id SERIAL,
    msg TEXT
);

INSERT INTO repl_test(msg)
VALUES('Hello from primary');