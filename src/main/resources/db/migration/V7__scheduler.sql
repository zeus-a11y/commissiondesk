-- Calculates last month's commission at 02:00 on the 2nd of every month. The run stays
-- CALCULATED for operations to review and approve; a failure is written to run_log by the package.
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'MONTHLY_COMMISSION_RUN',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'DECLARE l_run NUMBER; BEGIN pkg_commission.calculate(ADD_MONTHS(TRUNC(SYSDATE, ''MM''), -1), l_run); COMMIT; END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=MONTHLY; BYMONTHDAY=2; BYHOUR=2; BYMINUTE=0; BYSECOND=0',
    enabled         => TRUE,
    comments        => 'Monthly agent commission calculation');
END;
/
