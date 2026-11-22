-- The sales hierarchy as a tree, with each agent's path and depth.
CREATE OR REPLACE VIEW v_agent_tree AS
SELECT a.agent_code, a.name, a.branch, a.agent_level, a.parent_code, a.status,
       LEVEL                                      AS depth,
       SYS_CONNECT_BY_PATH(a.agent_code, '/')     AS path,
       CONNECT_BY_ROOT a.agent_code               AS root_code,
       CONNECT_BY_ISLEAF                          AS is_leaf
  FROM agent a
 START WITH a.parent_code IS NULL
CONNECT BY PRIOR a.agent_code = a.parent_code
 ORDER SIBLINGS BY a.agent_code;

-- One row per run: what the month cost and what was withheld.
CREATE OR REPLACE VIEW v_run_summary AS
SELECT r.run_id, r.period, TO_CHAR(r.period, 'YYYY-MM') AS period_key, r.status, r.receipts, r.transactions, r.exceptions, r.elapsed_ms,
       r.calculated_at, r.approved_at, r.approved_by,
       COUNT(s.agent_code)                        AS agents_paid,
       NVL(SUM(s.base_amount), 0)                 AS base_amount,
       NVL(SUM(s.override_amount), 0)             AS override_amount,
       NVL(SUM(s.bonus_amount), 0)                AS bonus_amount,
       NVL(SUM(s.clawback_amount), 0)             AS clawback_amount,
       NVL(SUM(s.tds_amount), 0)                  AS tds_amount,
       NVL(SUM(s.net_payable), 0)                 AS net_payable,
       NVL(SUM(s.carry_forward), 0)               AS carry_forward,
       NVL(SUM(s.gst_rcm), 0)                     AS gst_rcm
  FROM commission_run r
  LEFT JOIN agent_statement s ON s.run_id = r.run_id
 GROUP BY r.run_id, r.period, r.status, r.receipts, r.transactions, r.exceptions, r.elapsed_ms,
          r.calculated_at, r.approved_at, r.approved_by;

-- Statements with rankings: rank within branch, share of the branch's commission,
-- and the agent's financial-year-to-date earnings.
CREATE OR REPLACE VIEW v_statement_ranked AS
SELECT s.run_id, r.period, r.status AS run_status, s.agent_code, a.name, a.branch, a.agent_level,
       s.base_amount, s.override_amount, s.bonus_amount, s.clawback_amount, s.brought_forward,
       s.taxable_amount, s.tds_rate, s.tds_amount, s.net_payable, s.carry_forward, s.gst_rcm,
       s.base_amount + s.override_amount + s.bonus_amount + s.clawback_amount AS earned,
       RANK() OVER (PARTITION BY s.run_id, a.branch
                    ORDER BY s.base_amount + s.override_amount + s.bonus_amount + s.clawback_amount DESC) AS branch_rank,
       ROUND(100 * RATIO_TO_REPORT(GREATEST(s.taxable_amount, 0)) OVER (PARTITION BY s.run_id, a.branch), 1) AS branch_share_pct,
       SUM(s.taxable_amount) OVER (PARTITION BY s.agent_code, pkg_commission.fy_start(r.period)
                                   ORDER BY r.period ROWS UNBOUNDED PRECEDING) AS fytd_taxable
  FROM agent_statement s
  JOIN commission_run r ON r.run_id = s.run_id
  JOIN agent a ON a.agent_code = s.agent_code;

-- 13-month persistency of each agent's first-year business: of the policies issued 13 to 24
-- months ago, the share still in force. Clawbacks are the cost of the ones that were not.
CREATE OR REPLACE VIEW v_agent_persistency AS
SELECT a.agent_code, a.name, a.branch,
       COUNT(*)                                                   AS cohort,
       SUM(CASE WHEN p.status = 'IN_FORCE' OR p.lapse_date >= ADD_MONTHS(p.issue_date, 13) THEN 1 ELSE 0 END) AS persisted,
       ROUND(100 * AVG(CASE WHEN p.status = 'IN_FORCE' OR p.lapse_date >= ADD_MONTHS(p.issue_date, 13) THEN 1 ELSE 0 END), 1) AS persistency_13m
  FROM agent a
  JOIN policy p ON p.agent_code = a.agent_code
 WHERE p.issue_date BETWEEN ADD_MONTHS(TRUNC(SYSDATE), -24) AND ADD_MONTHS(TRUNC(SYSDATE), -13)
 GROUP BY a.agent_code, a.name, a.branch;
