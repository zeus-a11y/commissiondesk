CREATE OR REPLACE PACKAGE BODY test_pkg_commission AS

  c_today CONSTANT DATE := DATE '2026-11-21';
  g_seq   PLS_INTEGER := 0;

  -- ---------------------------------------------------------------- fixtures

  -- Each test starts from an empty book (utPLSQL rolls everything back afterwards):
  --   TM (manager) -> TS (senior) -> TA (advisor, has PAN), TB (advisor, no PAN)
  PROCEDURE setup_hierarchy IS
  BEGIN
    DELETE FROM commission_txn;
    DELETE FROM commission_exception;
    DELETE FROM agent_statement;
    DELETE FROM commission_run;
    DELETE FROM premium_receipt;
    DELETE FROM policy;
    DELETE FROM agent_audit;
    UPDATE agent SET parent_code = NULL;
    DELETE FROM agent;
    INSERT INTO agent (agent_code, name, branch, agent_level, parent_code, pan, joined_on)
    VALUES ('TM', 'Test Manager', 'Test', 'MANAGER', NULL, 'AAAPM1234A', DATE '2020-01-01');
    INSERT INTO agent (agent_code, name, branch, agent_level, parent_code, pan, joined_on)
    VALUES ('TS', 'Test Senior', 'Test', 'SENIOR', 'TM', 'AAAPS1234A', DATE '2020-01-01');
    INSERT INTO agent (agent_code, name, branch, agent_level, parent_code, pan, joined_on)
    VALUES ('TA', 'Test Advisor', 'Test', 'ADVISOR', 'TS', 'AAAPA1234A', DATE '2020-01-01');
    INSERT INTO agent (agent_code, name, branch, agent_level, parent_code, pan, joined_on)
    VALUES ('TB', 'No-PAN Advisor', 'Test', 'ADVISOR', 'TS', NULL, DATE '2020-01-01');
  END setup_hierarchy;

  FUNCTION new_policy(p_agent VARCHAR2, p_product VARCHAR2, p_issue DATE) RETURN VARCHAR2 IS
    l_no policy.policy_no%TYPE;
  BEGIN
    g_seq := g_seq + 1;
    l_no := 'TP' || LPAD(g_seq, 6, '0');
    INSERT INTO policy (policy_no, product_code, agent_code, holder_name, issue_date, pay_mode, modal_premium)
    VALUES (l_no, p_product, p_agent, 'Holder ' || g_seq, p_issue, 'ANNUAL', 1000);
    RETURN l_no;
  END new_policy;

  PROCEDURE receipt(p_policy VARCHAR2, p_due DATE, p_paid DATE, p_amount NUMBER, p_year NUMBER DEFAULT 1) IS
  BEGIN
    INSERT INTO premium_receipt (policy_no, due_date, paid_date, amount, policy_year)
    VALUES (p_policy, p_due, p_paid, p_amount, p_year);
  END receipt;

  FUNCTION run(p_period DATE) RETURN NUMBER IS
    l_run NUMBER;
  BEGIN
    pkg_commission.calculate(p_period, l_run, c_today);
    RETURN l_run;
  END run;

  PROCEDURE run_and_approve(p_period DATE) IS
  BEGIN
    pkg_commission.approve(run(p_period), 'ut');
  END run_and_approve;

  FUNCTION posted(p_run NUMBER, p_agent VARCHAR2, p_type VARCHAR2) RETURN NUMBER IS
    l_amt NUMBER;
  BEGIN
    SELECT NVL(SUM(amount), 0) INTO l_amt FROM commission_txn
     WHERE run_id = p_run AND agent_code = p_agent AND txn_type = p_type;
    RETURN l_amt;
  END posted;

  FUNCTION stmt(p_run NUMBER, p_agent VARCHAR2) RETURN agent_statement%ROWTYPE IS
    l_row agent_statement%ROWTYPE;
  BEGIN
    SELECT * INTO l_row FROM agent_statement WHERE run_id = p_run AND agent_code = p_agent;
    RETURN l_row;
  END stmt;

  -- ---------------------------------------------------------------- rates

  PROCEDURE base_first_year_rate IS
    l_run NUMBER;
  BEGIN
    receipt(new_policy('TA', 'TRM', DATE '2026-01-05'), DATE '2026-01-05', DATE '2026-01-07', 10000);
    l_run := run(DATE '2026-01-01');
    ut.expect(posted(l_run, 'TA', 'BASE')).to_equal(3000);       -- term year 1: 30%
  END;

  PROCEDURE renewal_rate_no_override IS
    l_run NUMBER;
  BEGIN
    receipt(new_policy('TA', 'TRM', DATE '2025-01-05'), DATE '2026-01-05', DATE '2026-01-07', 10000, 2);
    l_run := run(DATE '2026-01-01');
    ut.expect(posted(l_run, 'TA', 'BASE')).to_equal(750);        -- term years 2-3: 7.5%
    ut.expect(posted(l_run, 'TS', 'OVERRIDE')).to_equal(0);
    ut.expect(posted(l_run, 'TM', 'OVERRIDE')).to_equal(0);
  END;

  PROCEDURE dated_rate_change IS
    l_run NUMBER;
  BEGIN
    -- endowment first-year rate was 25% until 31 Mar 2025, 20% after; the due date decides
    receipt(new_policy('TA', 'END', DATE '2025-03-20'), DATE '2025-03-20', DATE '2025-04-02', 10000);
    receipt(new_policy('TB', 'END', DATE '2025-04-02'), DATE '2025-04-02', DATE '2025-04-02', 10000);
    l_run := run(DATE '2025-04-01');
    ut.expect(posted(l_run, 'TA', 'BASE')).to_equal(2500);
    ut.expect(posted(l_run, 'TB', 'BASE')).to_equal(2000);
  END;

  PROCEDURE fy_start_is_april IS
  BEGIN
    ut.expect(pkg_commission.fy_start(DATE '2026-02-10')).to_equal(DATE '2025-04-01');
    ut.expect(pkg_commission.fy_start(DATE '2026-03-31')).to_equal(DATE '2025-04-01');
    ut.expect(pkg_commission.fy_start(DATE '2026-04-01')).to_equal(DATE '2026-04-01');
  END;

  -- ---------------------------------------------------------------- hierarchy

  PROCEDURE overrides_two_levels IS
    l_run NUMBER;
  BEGIN
    receipt(new_policy('TA', 'TRM', DATE '2026-01-05'), DATE '2026-01-05', DATE '2026-01-07', 10000);
    l_run := run(DATE '2026-01-01');
    ut.expect(posted(l_run, 'TS', 'OVERRIDE')).to_equal(300);    -- 10% of 3,000
    ut.expect(posted(l_run, 'TM', 'OVERRIDE')).to_equal(150);    -- 5% of 3,000
  END;

  PROCEDURE hierarchy_cycle_rejected IS
  BEGIN
    UPDATE agent SET parent_code = 'TA' WHERE agent_code = 'TM';
  END;

  PROCEDURE audit_masks_pan IS
    l_old agent_audit.old_value%TYPE;
    l_new agent_audit.new_value%TYPE;
  BEGIN
    UPDATE agent SET pan = 'BBBPA9999B' WHERE agent_code = 'TA';
    SELECT old_value, new_value INTO l_old, l_new FROM agent_audit WHERE agent_code = 'TA' AND column_name = 'PAN';
    ut.expect(l_old).to_equal('AAxxxxxx4A');
    ut.expect(l_new).to_equal('BBxxxxxx9B');
  END;

  -- ---------------------------------------------------------------- exceptions queue

  PROCEDURE missing_rate_queued_batch_continues IS
    l_run NUMBER;
    l_exc NUMBER;
    l_msg commission_exception.message%TYPE;
  BEGIN
    -- pension commission only exists for due dates from 1 Apr 2026
    receipt(new_policy('TA', 'PEN', DATE '2026-01-05'), DATE '2026-01-05', DATE '2026-01-07', 50000);
    receipt(new_policy('TA', 'TRM', DATE '2026-01-05'), DATE '2026-01-05', DATE '2026-01-07', 10000);
    l_run := run(DATE '2026-01-01');
    SELECT COUNT(*), MAX(message) INTO l_exc, l_msg FROM commission_exception WHERE run_id = l_run;
    ut.expect(l_exc).to_equal(1);
    ut.expect(l_msg).to_be_like('No commission rate configured%');
    ut.expect(posted(l_run, 'TA', 'BASE')).to_equal(3000);       -- the term receipt still paid
  END;

  PROCEDURE orphan_after_termination IS
    l_run NUMBER;
    l_pol VARCHAR2(12) := new_policy('TA', 'TRM', DATE '2025-01-03');
    l_pol2 VARCHAR2(12) := new_policy('TA', 'TRM', DATE '2025-01-25');
    l_exc NUMBER;
  BEGIN
    UPDATE agent SET status = 'TERMINATED', terminated_on = DATE '2026-01-10' WHERE agent_code = 'TA';
    receipt(l_pol,  DATE '2026-01-03', DATE '2026-01-05', 10000, 2);   -- before leaving: paid
    receipt(l_pol2, DATE '2026-01-25', DATE '2026-01-25', 10000, 2);   -- after leaving: orphan
    l_run := run(DATE '2026-01-01');
    ut.expect(posted(l_run, 'TA', 'BASE')).to_equal(750);
    SELECT COUNT(*) INTO l_exc FROM commission_exception WHERE run_id = l_run AND policy_no = l_pol2;
    ut.expect(l_exc).to_equal(1);
  END;

  -- ---------------------------------------------------------------- clawback and bonus

  PROCEDURE clawback_full_year_one IS
    l_pol VARCHAR2(12) := new_policy('TA', 'TRM', DATE '2026-01-05');
    l_run NUMBER;
  BEGIN
    receipt(l_pol, DATE '2026-01-05', DATE '2026-01-07', 10000);
    receipt(new_policy('TB', 'TRM', DATE '2025-02-01'), DATE '2026-02-01', DATE '2026-02-01', 100, 2);
    run_and_approve(DATE '2026-01-01');
    UPDATE policy SET status = 'LAPSED', lapse_date = DATE '2026-02-15' WHERE policy_no = l_pol;
    l_run := run(DATE '2026-02-01');
    ut.expect(posted(l_run, 'TA', 'CLAWBACK')).to_equal(-3000);
    ut.expect(posted(l_run, 'TS', 'CLAWBACK')).to_equal(-300);
    ut.expect(posted(l_run, 'TM', 'CLAWBACK')).to_equal(-150);
  END;

  PROCEDURE clawback_half_year_two IS
    l_pol VARCHAR2(12) := new_policy('TA', 'TRM', DATE '2025-01-05');
    l_run NUMBER;
  BEGIN
    receipt(l_pol, DATE '2025-01-05', DATE '2025-01-07', 10000);
    run_and_approve(DATE '2025-01-01');
    UPDATE policy SET status = 'LAPSED', lapse_date = DATE '2026-02-04' WHERE policy_no = l_pol;  -- 13 months in
    FOR m IN 1 .. 12 LOOP
      run_and_approve(ADD_MONTHS(DATE '2025-01-01', m));
    END LOOP;
    l_run := run(DATE '2026-02-01');
    ut.expect(posted(l_run, 'TA', 'CLAWBACK')).to_equal(-1500);
  END;

  PROCEDURE clawback_once IS
    l_pol VARCHAR2(12) := new_policy('TA', 'TRM', DATE '2026-01-05');
    l_run NUMBER;
    l_n   NUMBER;
  BEGIN
    receipt(l_pol, DATE '2026-01-05', DATE '2026-01-07', 10000);
    run_and_approve(DATE '2026-01-01');
    UPDATE policy SET status = 'LAPSED', lapse_date = DATE '2026-02-15' WHERE policy_no = l_pol;
    l_run := run(DATE '2026-02-01');
    l_run := run(DATE '2026-02-01');
    SELECT COUNT(*) INTO l_n FROM commission_txn WHERE policy_no = l_pol AND txn_type = 'CLAWBACK' AND agent_code = 'TA';
    ut.expect(l_n).to_equal(1);
  END;

  PROCEDURE bonus_tier IS
    l_run NUMBER;
  BEGIN
    -- Rs 2,00,000 of first-year premium in the month clears the Rs 1,50,000 tier: 5% bonus
    receipt(new_policy('TA', 'TRM', DATE '2026-01-05'), DATE '2026-01-05', DATE '2026-01-07', 120000);
    receipt(new_policy('TA', 'TRM', DATE '2026-01-06'), DATE '2026-01-06', DATE '2026-01-08', 80000);
    receipt(new_policy('TB', 'TRM', DATE '2026-01-06'), DATE '2026-01-06', DATE '2026-01-08', 100000);
    l_run := run(DATE '2026-01-01');
    ut.expect(posted(l_run, 'TA', 'BONUS')).to_equal(3000);      -- 5% of 60,000
    ut.expect(posted(l_run, 'TB', 'BONUS')).to_equal(0);         -- 1,00,000 is under the tier
  END;

  -- ---------------------------------------------------------------- statements and tax

  PROCEDURE tds_threshold_catch_up IS
    l_jan NUMBER;
    l_feb NUMBER;
  BEGIN
    receipt(new_policy('TA', 'TRM', DATE '2026-01-05'), DATE '2026-01-05', DATE '2026-01-07', 50000);  -- 15,000
    l_jan := run(DATE '2026-01-01');
    ut.expect(stmt(l_jan, 'TA').tds_amount).to_equal(0);
    pkg_commission.approve(l_jan, 'ut');

    receipt(new_policy('TA', 'TRM', DATE '2026-02-05'), DATE '2026-02-05', DATE '2026-02-07', 33333.33);  -- 10,000
    l_feb := run(DATE '2026-02-01');
    -- FY credits now 25,000 > 20,000: 2% on all of it
    ut.expect(stmt(l_feb, 'TA').tds_amount).to_equal(500);
    ut.expect(stmt(l_feb, 'TA').net_payable).to_equal(9500);
  END;

  PROCEDURE tds_no_pan IS
    l_run NUMBER;
  BEGIN
    receipt(new_policy('TB', 'TRM', DATE '2026-01-05'), DATE '2026-01-05', DATE '2026-01-07', 100000);  -- 30,000
    l_run := run(DATE '2026-01-01');
    ut.expect(stmt(l_run, 'TB').tds_rate).to_equal(20);
    ut.expect(stmt(l_run, 'TB').tds_amount).to_equal(6000);
  END;

  PROCEDURE debit_carried_forward IS
    l_pol VARCHAR2(12) := new_policy('TA', 'TRM', DATE '2026-01-05');
    l_feb NUMBER;
    l_mar NUMBER;
  BEGIN
    receipt(l_pol, DATE '2026-01-05', DATE '2026-01-07', 10000);                         -- +3,000 in Jan
    run_and_approve(DATE '2026-01-01');
    UPDATE policy SET status = 'LAPSED', lapse_date = DATE '2026-02-15' WHERE policy_no = l_pol;
    receipt(new_policy('TA', 'TRM', DATE '2025-02-03'), DATE '2026-02-03', DATE '2026-02-03', 10000, 2);  -- +750 in Feb
    l_feb := run(DATE '2026-02-01');
    ut.expect(stmt(l_feb, 'TA').net_payable).to_equal(0);
    ut.expect(stmt(l_feb, 'TA').carry_forward).to_equal(-2250);                         -- 750 - 3,000
    pkg_commission.approve(l_feb, 'ut');

    receipt(new_policy('TA', 'TRM', DATE '2026-03-02'), DATE '2026-03-02', DATE '2026-03-02', 10000);    -- +3,000 in Mar
    l_mar := run(DATE '2026-03-01');
    ut.expect(stmt(l_mar, 'TA').brought_forward).to_equal(-2250);
    ut.expect(stmt(l_mar, 'TA').net_payable).to_equal(750);
  END;

  -- ---------------------------------------------------------------- run lifecycle

  PROCEDURE approved_period_locked IS
    l_run NUMBER;
  BEGIN
    run_and_approve(DATE '2026-01-01');
    l_run := run(DATE '2026-01-01');
  END;

  PROCEDURE previous_month_must_be_approved IS
    l_run NUMBER;
  BEGIN
    l_run := run(DATE '2026-01-01');
    l_run := run(DATE '2026-02-01');
  END;

  PROCEDURE future_period_rejected IS
    l_run NUMBER;
  BEGIN
    l_run := run(DATE '2026-12-01');
  END;

  PROCEDURE recalculation_is_idempotent IS
    l_run   NUMBER;
    l_first NUMBER;
    l_n1    NUMBER;
    l_n2    NUMBER;
    l_sum1  NUMBER;
    l_sum2  NUMBER;
  BEGIN
    receipt(new_policy('TA', 'TRM', DATE '2026-01-05'), DATE '2026-01-05', DATE '2026-01-07', 10000);
    receipt(new_policy('TB', 'END', DATE '2025-01-09'), DATE '2026-01-09', DATE '2026-01-10', 40000, 2);
    l_first := run(DATE '2026-01-01');
    SELECT COUNT(*), SUM(amount) INTO l_n1, l_sum1 FROM commission_txn WHERE run_id = l_first;
    l_run := run(DATE '2026-01-01');
    SELECT COUNT(*), SUM(amount) INTO l_n2, l_sum2 FROM commission_txn WHERE run_id = l_run;
    ut.expect(l_run).to_equal(l_first);
    ut.expect(l_n2).to_equal(l_n1);
    ut.expect(l_sum2).to_equal(l_sum1);
  END;

  PROCEDURE overlapping_rate_rejected IS
  BEGIN
    -- term year 2-3 is already 7.5% from 2022; a 2026 window for year 3 overlaps it
    INSERT INTO commission_rate (product_code, year_from, year_to, rate_pct, effective_from)
    VALUES ('TRM', 3, 5, 6, DATE '2026-04-01');
  END;

END test_pkg_commission;
/
