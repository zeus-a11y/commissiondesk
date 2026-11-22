-- Runs once as SYSDBA when the Oracle container is first created.
-- The application schema gets exactly the privileges its migrations need, nothing more
-- (no DBA, no ANY privileges).
ALTER SESSION SET CONTAINER = FREEPDB1;

CREATE USER commission IDENTIFIED BY "commission"
  DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;

GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE PROCEDURE, CREATE TRIGGER,
      CREATE SEQUENCE, CREATE TYPE, CREATE JOB TO commission;

-- read-only reporting account for BI tools
CREATE USER commission_ro IDENTIFIED BY "commission_ro";
GRANT CREATE SESSION TO commission_ro;
