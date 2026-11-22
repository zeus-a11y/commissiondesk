#!/bin/bash
# Drops and recreates the application schema (dev only). Run inside the oracle container.
sqlplus -s / as sysdba <<SQL
ALTER SESSION SET CONTAINER = FREEPDB1;
BEGIN
  FOR j IN (SELECT job_name FROM dba_scheduler_jobs WHERE owner = 'COMMISSION') LOOP
    DBMS_SCHEDULER.DROP_JOB('COMMISSION.' || j.job_name, force => TRUE);
  END LOOP;
END;
/
DROP USER commission CASCADE;
DROP USER commission_ro CASCADE;
SQL
sqlplus -s / as sysdba @/container-entrypoint-initdb.d/01_create_user.sql
