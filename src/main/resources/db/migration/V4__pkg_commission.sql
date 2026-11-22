CREATE OR REPLACE PACKAGE pkg_commission AS
  /*
   * Monthly agent-commission run.
   *
   *   calculate(period)  books commission for every premium receipt paid in the month:
   *                      BASE to the selling agent, OVERRIDE to the two upline levels,
   *                      CLAWBACK on early lapses, BONUS on volume tiers, then one statement
   *                      per agent with brought-forward debits and TDS (s.194D).
   *   approve(run_id)    locks the run; an approved month can never be recalculated.
   *
   * Neither procedure commits: the caller owns the transaction (the API, or the scheduler job).
   */

  -- Overrides, % of the downline's first-year BASE commission, by distance up the hierarchy.
  c_override_parent      CONSTANT NUMBER := 10;
  c_override_grandparent CONSTANT NUMBER := 5;

  -- Monthly first-year premium volume needed for a bonus on first-year BASE commission.
  c_bonus_tier1_premium  CONSTANT NUMBER := 150000;  c_bonus_tier1_pct CONSTANT NUMBER := 5;
  c_bonus_tier2_premium  CONSTANT NUMBER := 400000;  c_bonus_tier2_pct CONSTANT NUMBER := 10;

  -- Section 194D: 2% for individuals (from 1 Apr 2025), 20% without a PAN (s.206AA),
  -- only once commission credited in the financial year exceeds Rs 20,000.
  c_tds_rate             CONSTANT NUMBER := 2;
  c_tds_rate_no_pan      CONSTANT NUMBER := 20;
  c_tds_threshold        CONSTANT NUMBER := 20000;
  -- GST on agent commission is paid by the insurer under reverse charge, not deducted.
  c_gst_rcm_rate         CONSTANT NUMBER := 18;

  e_period_locked          EXCEPTION; PRAGMA EXCEPTION_INIT(e_period_locked, -20001);
  e_future_period          EXCEPTION; PRAGMA EXCEPTION_INIT(e_future_period, -20002);
  e_previous_not_approved  EXCEPTION; PRAGMA EXCEPTION_INIT(e_previous_not_approved, -20003);
  e_run_not_found          EXCEPTION; PRAGMA EXCEPTION_INIT(e_run_not_found, -20004);

  FUNCTION rate_for(p_product VARCHAR2, p_policy_year NUMBER, p_on DATE) RETURN NUMBER;
  FUNCTION fy_start(p_date DATE) RETURN DATE DETERMINISTIC;

  PROCEDURE calculate(p_period DATE, p_run_id OUT NUMBER, p_today DATE DEFAULT TRUNC(SYSDATE));
  PROCEDURE approve(p_run_id NUMBER, p_by VARCHAR2);
END pkg_commission;
/

CREATE OR REPLACE PACKAGE BODY pkg_commission AS

  c_batch CONSTANT PLS_INTEGER := 2000;

  -- Written in its own transaction so the log survives a failed, rolled-back run.
  PROCEDURE log(p_period DATE, p_severity VARCHAR2, p_message VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO run_log (period, severity, message) VALUES (p_period, p_severity, SUBSTR(p_message, 1, 1000));
    COMMIT;
  END log;

  FUNCTION fy_start(p_date DATE) RETURN DATE DETERMINISTIC IS
  BEGIN
    -- Indian financial year: 1 April to 31 March
    RETURN ADD_MONTHS(TRUNC(ADD_MONTHS(p_date, -3), 'YYYY'), 3);
  END fy_start;

  FUNCTION rate_for(p_product VARCHAR2, p_policy_year NUMBER, p_on DATE) RETURN NUMBER IS
    l_rate commission_rate.rate_pct%TYPE;
  BEGIN
    SELECT rate_pct INTO l_rate
      FROM commission_rate
     WHERE product_code = p_product
       AND p_policy_year BETWEEN year_from AND year_to
       AND p_on >= effective_from AND p_on < effective_to;
    RETURN l_rate;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END rate_for;

  -- Locks or creates the run row for the period, enforcing the run lifecycle.
  FUNCTION open_run(p_period DATE, p_today DATE) RETURN NUMBER IS
    l_run_id commission_run.run_id%TYPE;
    l_status commission_run.status%TYPE;
    l_later  NUMBER;
    l_open   DATE;
  BEGIN
    IF p_period > TRUNC(p_today, 'MM') THEN
      RAISE_APPLICATION_ERROR(-20002, 'Cannot calculate ' || TO_CHAR(p_period, 'Mon YYYY') || ': it has not started yet');
    END IF;

    SELECT MIN(period) INTO l_open FROM commission_run WHERE period < p_period AND status <> 'APPROVED';
    IF l_open IS NOT NULL THEN
      RAISE_APPLICATION_ERROR(-20003, 'Approve ' || TO_CHAR(l_open, 'Mon YYYY') || ' before calculating ' || TO_CHAR(p_period, 'Mon YYYY'));
    END IF;

    SELECT COUNT(*) INTO l_later FROM commission_run WHERE period > p_period;
    IF l_later > 0 THEN
      RAISE_APPLICATION_ERROR(-20001, TO_CHAR(p_period, 'Mon YYYY') || ' is closed: a later month has already been run');
    END IF;

    BEGIN
      SELECT run_id, status INTO l_run_id, l_status FROM commission_run WHERE period = p_period FOR UPDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        INSERT INTO commission_run (period, status) VALUES (p_period, 'CALCULATED') RETURNING run_id INTO l_run_id;
        RETURN l_run_id;
    END;

    IF l_status = 'APPROVED' THEN
      RAISE_APPLICATION_ERROR(-20001, TO_CHAR(p_period, 'Mon YYYY') || ' is approved and locked');
    END IF;
    -- recalculation: throw away the previous attempt's postings (statements are MERGEd later)
    DELETE FROM commission_txn WHERE run_id = l_run_id;
    DELETE FROM commission_exception WHERE run_id = l_run_id;
    RETURN l_run_id;
  END open_run;

  -- BASE commission for every receipt paid in the month, in batches.
  -- A receipt with no configured rate violates commission_txn.rate_pct NOT NULL; SAVE EXCEPTIONS
  -- lets the rest of the batch through and the failures go to the exception queue.
  PROCEDURE book_base(p_run_id NUMBER, p_from DATE, p_to DATE, p_booked OUT NUMBER, p_failed OUT NUMBER) IS
    CURSOR c_receipts IS
      SELECT r.receipt_id, r.policy_no, p.agent_code, r.amount,
             CASE WHEN r.policy_year = 1 THEN 'FY' ELSE 'RN' END AS premium_year,
             cr.rate_pct
        FROM premium_receipt r
        JOIN policy p ON p.policy_no = r.policy_no
        JOIN agent a  ON a.agent_code = p.agent_code
        LEFT JOIN commission_rate cr
          ON cr.product_code = p.product_code
         AND r.policy_year BETWEEN cr.year_from AND cr.year_to
         AND r.due_date >= cr.effective_from AND r.due_date < cr.effective_to
       WHERE r.paid_date >= p_from AND r.paid_date < p_to
         AND (a.terminated_on IS NULL OR r.paid_date <= a.terminated_on)
         AND NOT EXISTS (SELECT 1 FROM commission_txn t WHERE t.receipt_id = r.receipt_id AND t.txn_type = 'BASE');

    TYPE t_rows IS TABLE OF c_receipts%ROWTYPE;
    l_rows   t_rows;
    e_dml    EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_dml, -24381); -- ORA-24381: error(s) in array DML
  BEGIN
    p_booked := 0;
    p_failed := 0;
    OPEN c_receipts;
    LOOP
      FETCH c_receipts BULK COLLECT INTO l_rows LIMIT c_batch;
      EXIT WHEN l_rows.COUNT = 0;
      BEGIN
        FORALL i IN 1 .. l_rows.COUNT SAVE EXCEPTIONS
          INSERT INTO commission_txn (run_id, agent_code, policy_no, receipt_id, txn_type, premium_year, basis_amount, rate_pct, amount)
          VALUES (p_run_id, l_rows(i).agent_code, l_rows(i).policy_no, l_rows(i).receipt_id, 'BASE', l_rows(i).premium_year,
                  l_rows(i).amount, l_rows(i).rate_pct, ROUND(l_rows(i).amount * l_rows(i).rate_pct / 100, 2));
        p_booked := p_booked + l_rows.COUNT;
      EXCEPTION
        WHEN e_dml THEN
          -- copy the error list first: the INSERTs below reset the SQL% cursor attributes
          DECLARE
            TYPE t_nums IS TABLE OF PLS_INTEGER;
            l_idx  t_nums := t_nums();
            l_err  t_nums := t_nums();
          BEGIN
            FOR j IN 1 .. SQL%BULK_EXCEPTIONS.COUNT LOOP
              l_idx.EXTEND; l_idx(l_idx.LAST) := SQL%BULK_EXCEPTIONS(j).ERROR_INDEX;
              l_err.EXTEND; l_err(l_err.LAST) := SQL%BULK_EXCEPTIONS(j).ERROR_CODE;
            END LOOP;
            p_booked := p_booked + l_rows.COUNT - l_idx.COUNT;
          FOR j IN 1 .. l_idx.COUNT LOOP
            DECLARE
              l_row  c_receipts%ROWTYPE := l_rows(l_idx(j));
              l_code NUMBER := l_err(j);
              l_msg  VARCHAR2(400);
            BEGIN
              -- SQLERRM is PL/SQL-only, so build the message before the INSERT
              l_msg := CASE WHEN l_code = 1400 AND l_row.rate_pct IS NULL
                            THEN 'No commission rate configured for this product, policy year and due date'
                            ELSE SUBSTR(SQLERRM(-l_code), 1, 400) END;
              INSERT INTO commission_exception (run_id, receipt_id, policy_no, ora_code, message)
              VALUES (p_run_id, l_row.receipt_id, l_row.policy_no, l_code, l_msg);
              p_failed := p_failed + 1;
            END;
          END LOOP;
          END;
      END;
    END LOOP;
    CLOSE c_receipts;
  END book_base;

  PROCEDURE calculate(p_period DATE, p_run_id OUT NUMBER, p_today DATE DEFAULT TRUNC(SYSDATE)) IS
    l_period   DATE := TRUNC(p_period, 'MM');
    l_next     DATE := ADD_MONTHS(TRUNC(p_period, 'MM'), 1);
    l_fy       DATE := fy_start(TRUNC(p_period, 'MM'));
    l_started  PLS_INTEGER := DBMS_UTILITY.GET_TIME;  -- hundredths of a second, time-zone free
    l_receipts NUMBER;
    l_failed   NUMBER;
    l_orphans  NUMBER;
  BEGIN
    p_run_id := open_run(l_period, p_today);

    -- 1. Renewals on policies whose agent has left ("orphan" policies) earn nobody commission
    --    until the policy is reassigned: queue them for operations, set-based.
    INSERT INTO commission_exception (run_id, receipt_id, policy_no, message)
    SELECT p_run_id, r.receipt_id, r.policy_no,
           'Agent ' || a.agent_code || ' left on ' || TO_CHAR(a.terminated_on, 'DD-Mon-YYYY') || ': reassign this orphan policy'
      FROM premium_receipt r
      JOIN policy p ON p.policy_no = r.policy_no
      JOIN agent a  ON a.agent_code = p.agent_code
     WHERE r.paid_date >= l_period AND r.paid_date < l_next
       AND r.paid_date > a.terminated_on;
    l_orphans := SQL%ROWCOUNT;

    -- 2. BASE commission, bulk-bound
    book_base(p_run_id, l_period, l_next, l_receipts, l_failed);

    -- 3. OVERRIDE to the two active upline agents, on first-year BASE only.
    --    CROSS APPLY runs the hierarchical walk once per BASE row.
    INSERT INTO commission_txn (run_id, agent_code, policy_no, receipt_id, txn_type, premium_year, basis_amount, rate_pct, amount)
    SELECT p_run_id, up.agent_code, t.policy_no, t.receipt_id, 'OVERRIDE', 'FY', t.amount, up.pct, ROUND(t.amount * up.pct / 100, 2)
      FROM commission_txn t
     CROSS APPLY (
            SELECT a.agent_code,
                   CASE LEVEL WHEN 2 THEN c_override_parent ELSE c_override_grandparent END AS pct
              FROM agent a
             WHERE LEVEL BETWEEN 2 AND 3
               AND a.status = 'ACTIVE'
             START WITH a.agent_code = t.agent_code
           CONNECT BY a.agent_code = PRIOR a.parent_code AND LEVEL <= 3
           ) up
     WHERE t.run_id = p_run_id AND t.txn_type = 'BASE' AND t.premium_year = 'FY';

    -- 4. CLAWBACK first-year commission (BASE and OVERRIDE, every recipient) when a policy lapses
    --    early: 100% if it lapses in policy year 1, 50% in policy year 2.
    INSERT INTO commission_txn (run_id, agent_code, policy_no, txn_type, premium_year, basis_amount, rate_pct, amount)
    SELECT p_run_id, t.agent_code, p.policy_no, 'CLAWBACK', 'FY', SUM(t.amount), x.pct, -ROUND(SUM(t.amount) * x.pct / 100, 2)
      FROM policy p
     CROSS APPLY (SELECT CASE WHEN MONTHS_BETWEEN(p.lapse_date, p.issue_date) < 12 THEN 100 ELSE 50 END AS pct FROM dual) x
      JOIN commission_txn t ON t.policy_no = p.policy_no AND t.premium_year = 'FY' AND t.txn_type IN ('BASE', 'OVERRIDE')
      JOIN commission_run r ON r.run_id = t.run_id AND (r.status = 'APPROVED' OR r.run_id = p_run_id)
     WHERE p.lapse_date >= l_period AND p.lapse_date < l_next
       AND MONTHS_BETWEEN(p.lapse_date, p.issue_date) < 24
       AND NOT EXISTS (SELECT 1 FROM commission_txn c WHERE c.policy_no = p.policy_no
                          AND c.agent_code = t.agent_code AND c.txn_type = 'CLAWBACK')
     GROUP BY t.agent_code, p.policy_no, x.pct
    HAVING SUM(t.amount) > 0;

    -- 5. BONUS on the month's first-year BASE commission for agents above the volume tiers
    INSERT INTO commission_txn (run_id, agent_code, txn_type, premium_year, basis_amount, rate_pct, amount)
    SELECT p_run_id, agent_code, 'BONUS', 'FY', fy_commission, pct, ROUND(fy_commission * pct / 100, 2)
      FROM (SELECT agent_code, SUM(amount) AS fy_commission,
                   CASE WHEN SUM(basis_amount) >= c_bonus_tier2_premium THEN c_bonus_tier2_pct
                        WHEN SUM(basis_amount) >= c_bonus_tier1_premium THEN c_bonus_tier1_pct END AS pct
              FROM commission_txn
             WHERE run_id = p_run_id AND txn_type = 'BASE' AND premium_year = 'FY'
             GROUP BY agent_code)
     WHERE pct IS NOT NULL;

    -- 6. One statement per agent: this month's postings, plus any debit carried forward from the
    --    previous statement, then TDS on the positive balance with the Rs 20,000 FY threshold
    --    (on crossing it, TDS catches up on everything credited so far this FY).
    MERGE INTO agent_statement s
    USING (
      WITH postings AS (
        SELECT agent_code,
               SUM(CASE txn_type WHEN 'BASE'     THEN amount ELSE 0 END) AS base_amt,
               SUM(CASE txn_type WHEN 'OVERRIDE' THEN amount ELSE 0 END) AS override_amt,
               SUM(CASE txn_type WHEN 'BONUS'    THEN amount ELSE 0 END) AS bonus_amt,
               SUM(CASE txn_type WHEN 'CLAWBACK' THEN amount ELSE 0 END) AS clawback_amt
          FROM commission_txn WHERE run_id = p_run_id GROUP BY agent_code),
      last_stmt AS (
        SELECT agent_code, carry_forward
          FROM (SELECT st.agent_code, st.carry_forward,
                       ROW_NUMBER() OVER (PARTITION BY st.agent_code ORDER BY r.period DESC) AS rn
                  FROM agent_statement st JOIN commission_run r ON r.run_id = st.run_id
                 WHERE r.period < l_period)
         WHERE rn = 1 AND carry_forward < 0),
      fytd AS (
        SELECT st.agent_code, SUM(st.taxable_amount) AS credited
          FROM agent_statement st JOIN commission_run r ON r.run_id = st.run_id
         WHERE r.period >= l_fy AND r.period < l_period
         GROUP BY st.agent_code),
      totals AS (
        SELECT a.agent_code,
               NVL(p.base_amt, 0) AS base_amt, NVL(p.override_amt, 0) AS override_amt,
               NVL(p.bonus_amt, 0) AS bonus_amt, NVL(p.clawback_amt, 0) AS clawback_amt,
               NVL(l.carry_forward, 0) AS brought_forward,
               NVL(f.credited, 0) AS credited_before,
               CASE WHEN a.pan IS NULL THEN c_tds_rate_no_pan ELSE c_tds_rate END AS tds_rate,
               NVL(p.base_amt, 0) + NVL(p.override_amt, 0) + NVL(p.bonus_amt, 0) + NVL(p.clawback_amt, 0)
                 + NVL(l.carry_forward, 0) AS balance
          FROM agent a
          LEFT JOIN postings p  ON p.agent_code = a.agent_code
          LEFT JOIN last_stmt l ON l.agent_code = a.agent_code
          LEFT JOIN fytd f      ON f.agent_code = a.agent_code
         WHERE p.agent_code IS NOT NULL OR l.agent_code IS NOT NULL),
      taxed AS (
        SELECT t.*, GREATEST(balance, 0) AS taxable,
               CASE WHEN balance <= 0 OR credited_before + balance <= c_tds_threshold THEN 0
                    WHEN credited_before <= c_tds_threshold
                      THEN LEAST(balance, ROUND((credited_before + balance) * tds_rate / 100, 2))
                    ELSE ROUND(balance * tds_rate / 100, 2) END AS tds
          FROM totals t)
      SELECT agent_code, base_amt, override_amt, bonus_amt, clawback_amt, brought_forward, taxable,
             CASE WHEN tds > 0 THEN tds_rate ELSE 0 END AS tds_rate, tds,
             taxable - tds AS net, LEAST(balance, 0) AS carry,
             ROUND(taxable * c_gst_rcm_rate / 100, 2) AS gst
        FROM taxed
    ) src
    ON (s.run_id = p_run_id AND s.agent_code = src.agent_code)
    WHEN MATCHED THEN UPDATE SET
      base_amount = src.base_amt, override_amount = src.override_amt, bonus_amount = src.bonus_amt,
      clawback_amount = src.clawback_amt, brought_forward = src.brought_forward, taxable_amount = src.taxable,
      tds_rate = src.tds_rate, tds_amount = src.tds, net_payable = src.net, carry_forward = src.carry, gst_rcm = src.gst
    WHEN NOT MATCHED THEN INSERT
      (run_id, agent_code, base_amount, override_amount, bonus_amount, clawback_amount, brought_forward,
       taxable_amount, tds_rate, tds_amount, net_payable, carry_forward, gst_rcm)
    VALUES
      (p_run_id, src.agent_code, src.base_amt, src.override_amt, src.bonus_amt, src.clawback_amt, src.brought_forward,
       src.taxable, src.tds_rate, src.tds, src.net, src.carry, src.gst);

    -- a recalculation can leave statements for agents who no longer have postings
    DELETE FROM agent_statement s
     WHERE s.run_id = p_run_id
       AND NOT EXISTS (SELECT 1 FROM commission_txn t WHERE t.run_id = p_run_id AND t.agent_code = s.agent_code)
       AND s.brought_forward = 0;

    UPDATE commission_run r
       SET receipts      = l_receipts + l_failed + l_orphans,
           transactions  = (SELECT COUNT(*) FROM commission_txn WHERE run_id = r.run_id),
           exceptions    = l_failed + l_orphans,
           gross_amount  = (SELECT NVL(SUM(amount), 0) FROM commission_txn WHERE run_id = r.run_id),
           calculated_at = SYSTIMESTAMP,
           elapsed_ms    = (DBMS_UTILITY.GET_TIME - l_started) * 10
     WHERE r.run_id = p_run_id;

    log(l_period, 'INFO', 'Calculated run ' || p_run_id || ': ' || l_receipts || ' receipts booked, '
        || (l_failed + l_orphans) || ' exceptions');
  EXCEPTION
    WHEN OTHERS THEN
      log(l_period, 'ERROR', 'Run failed: ' || SQLERRM || ' ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      RAISE;
  END calculate;

  PROCEDURE approve(p_run_id NUMBER, p_by VARCHAR2) IS
    l_status commission_run.status%TYPE;
    l_period DATE;
  BEGIN
    SELECT status, period INTO l_status, l_period FROM commission_run WHERE run_id = p_run_id FOR UPDATE;
    IF l_status = 'APPROVED' THEN
      RAISE_APPLICATION_ERROR(-20001, 'Run ' || p_run_id || ' is already approved');
    END IF;
    UPDATE commission_run SET status = 'APPROVED', approved_at = SYSTIMESTAMP, approved_by = p_by WHERE run_id = p_run_id;
    log(l_period, 'INFO', 'Run ' || p_run_id || ' approved by ' || p_by);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20004, 'No commission run ' || p_run_id);
  END approve;

END pkg_commission;
/
