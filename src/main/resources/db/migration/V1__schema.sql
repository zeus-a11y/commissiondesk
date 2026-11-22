-- CommissionDesk schema: agents, products, the board-approved commission policy,
-- the policy book, premium receipts, and everything a monthly commission run produces.

CREATE TABLE agent (
  agent_code      VARCHAR2(10)  CONSTRAINT pk_agent PRIMARY KEY,
  name            VARCHAR2(80)  NOT NULL,
  branch          VARCHAR2(40)  NOT NULL,
  agent_level     VARCHAR2(10)  NOT NULL CONSTRAINT ck_agent_level CHECK (agent_level IN ('ADVISOR', 'SENIOR', 'MANAGER')),
  parent_code     VARCHAR2(10)  CONSTRAINT fk_agent_parent REFERENCES agent (agent_code),
  pan             VARCHAR2(10)  CONSTRAINT ck_agent_pan CHECK (pan IS NULL OR REGEXP_LIKE(pan, '^[A-Z]{5}[0-9]{4}[A-Z]$')),
  joined_on       DATE          NOT NULL,
  status          VARCHAR2(10)  DEFAULT 'ACTIVE' NOT NULL CONSTRAINT ck_agent_status CHECK (status IN ('ACTIVE', 'TERMINATED')),
  terminated_on   DATE,
  CONSTRAINT ck_agent_terminated CHECK ((status = 'TERMINATED' AND terminated_on IS NOT NULL) OR (status = 'ACTIVE' AND terminated_on IS NULL)),
  CONSTRAINT ck_agent_not_own_parent CHECK (parent_code IS NULL OR parent_code <> agent_code)
);
CREATE INDEX ix_agent_parent ON agent (parent_code);

CREATE TABLE agent_audit (
  audit_id        NUMBER GENERATED ALWAYS AS IDENTITY CONSTRAINT pk_agent_audit PRIMARY KEY,
  agent_code      VARCHAR2(10)  NOT NULL,
  changed_at      TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  changed_by      VARCHAR2(128) DEFAULT SYS_CONTEXT('USERENV', 'SESSION_USER') NOT NULL,
  column_name     VARCHAR2(30)  NOT NULL,
  old_value       VARCHAR2(80),
  new_value       VARCHAR2(80)
);

CREATE TABLE product (
  product_code    VARCHAR2(10)  CONSTRAINT pk_product PRIMARY KEY,
  name            VARCHAR2(60)  NOT NULL,
  product_type    VARCHAR2(10)  NOT NULL CONSTRAINT ck_product_type CHECK (product_type IN ('TERM', 'ENDOWMENT', 'ULIP', 'PENSION'))
);

-- Commission as % of premium by product and policy year, with effective-dated windows so a
-- policy change never rewrites history. Overlapping windows are rejected by trg_rate_no_overlap.
CREATE TABLE commission_rate (
  rate_id         NUMBER GENERATED ALWAYS AS IDENTITY CONSTRAINT pk_commission_rate PRIMARY KEY,
  product_code    VARCHAR2(10)  NOT NULL CONSTRAINT fk_rate_product REFERENCES product,
  year_from       NUMBER(2)     NOT NULL CONSTRAINT ck_rate_year_from CHECK (year_from >= 1),
  year_to         NUMBER(2)     NOT NULL,
  rate_pct        NUMBER(5, 2)  NOT NULL CONSTRAINT ck_rate_pct CHECK (rate_pct BETWEEN 0 AND 100),
  effective_from  DATE          NOT NULL,
  effective_to    DATE          DEFAULT DATE '9999-12-31' NOT NULL,
  CONSTRAINT ck_rate_years CHECK (year_to >= year_from),
  CONSTRAINT ck_rate_dates CHECK (effective_to > effective_from)
);
CREATE INDEX ix_rate_lookup ON commission_rate (product_code, year_from, year_to, effective_from);

CREATE TABLE policy (
  policy_no       VARCHAR2(12)  CONSTRAINT pk_policy PRIMARY KEY,
  product_code    VARCHAR2(10)  NOT NULL CONSTRAINT fk_policy_product REFERENCES product,
  agent_code      VARCHAR2(10)  NOT NULL CONSTRAINT fk_policy_agent REFERENCES agent,
  holder_name     VARCHAR2(80)  NOT NULL,
  issue_date      DATE          NOT NULL,
  pay_mode        VARCHAR2(12)  NOT NULL CONSTRAINT ck_policy_mode CHECK (pay_mode IN ('ANNUAL', 'HALF_YEARLY', 'MONTHLY')),
  modal_premium   NUMBER(12, 2) NOT NULL CONSTRAINT ck_policy_premium CHECK (modal_premium > 0),
  status          VARCHAR2(10)  DEFAULT 'IN_FORCE' NOT NULL CONSTRAINT ck_policy_status CHECK (status IN ('IN_FORCE', 'LAPSED')),
  lapse_date      DATE,
  CONSTRAINT ck_policy_lapse CHECK ((status = 'LAPSED' AND lapse_date IS NOT NULL) OR (status = 'IN_FORCE' AND lapse_date IS NULL))
);
CREATE INDEX ix_policy_agent ON policy (agent_code);
CREATE INDEX ix_policy_lapse ON policy (lapse_date);

CREATE TABLE premium_receipt (
  receipt_id      NUMBER GENERATED ALWAYS AS IDENTITY CONSTRAINT pk_premium_receipt PRIMARY KEY,
  policy_no       VARCHAR2(12)  NOT NULL CONSTRAINT fk_receipt_policy REFERENCES policy,
  due_date        DATE          NOT NULL,
  paid_date       DATE          NOT NULL,
  amount          NUMBER(12, 2) NOT NULL CONSTRAINT ck_receipt_amount CHECK (amount > 0),
  policy_year     NUMBER(2)     NOT NULL CONSTRAINT ck_receipt_year CHECK (policy_year >= 1),
  CONSTRAINT uq_receipt_due UNIQUE (policy_no, due_date)
);
CREATE INDEX ix_receipt_paid ON premium_receipt (paid_date);

-- One run per month. CALCULATED runs can be recalculated; APPROVED runs are locked.
CREATE TABLE commission_run (
  run_id          NUMBER GENERATED ALWAYS AS IDENTITY CONSTRAINT pk_commission_run PRIMARY KEY,
  period          DATE          NOT NULL CONSTRAINT uq_run_period UNIQUE,
  status          VARCHAR2(12)  NOT NULL CONSTRAINT ck_run_status CHECK (status IN ('CALCULATED', 'APPROVED')),
  receipts        NUMBER        DEFAULT 0 NOT NULL,
  transactions    NUMBER        DEFAULT 0 NOT NULL,
  exceptions      NUMBER        DEFAULT 0 NOT NULL,
  gross_amount    NUMBER(14, 2) DEFAULT 0 NOT NULL,
  calculated_at   TIMESTAMP,
  elapsed_ms      NUMBER,
  approved_at     TIMESTAMP,
  approved_by     VARCHAR2(40),
  CONSTRAINT ck_run_period_month CHECK (period = TRUNC(period, 'MM'))
);

CREATE TABLE commission_txn (
  txn_id          NUMBER GENERATED ALWAYS AS IDENTITY CONSTRAINT pk_commission_txn PRIMARY KEY,
  run_id          NUMBER        NOT NULL CONSTRAINT fk_txn_run REFERENCES commission_run ON DELETE CASCADE,
  agent_code      VARCHAR2(10)  NOT NULL CONSTRAINT fk_txn_agent REFERENCES agent,
  policy_no       VARCHAR2(12)  CONSTRAINT fk_txn_policy REFERENCES policy,
  receipt_id      NUMBER        CONSTRAINT fk_txn_receipt REFERENCES premium_receipt,
  txn_type        VARCHAR2(10)  NOT NULL CONSTRAINT ck_txn_type CHECK (txn_type IN ('BASE', 'OVERRIDE', 'BONUS', 'CLAWBACK')),
  premium_year    VARCHAR2(2)   CONSTRAINT ck_txn_premium_year CHECK (premium_year IN ('FY', 'RN')),
  basis_amount    NUMBER(14, 2) NOT NULL,
  rate_pct        NUMBER(5, 2)  NOT NULL,
  amount          NUMBER(14, 2) NOT NULL
);
-- Idempotency, enforced by the database rather than trusted to the batch code:
-- a receipt earns one BASE and one OVERRIDE per upline agent, ever; a policy is clawed back once
-- per agent; an agent gets one BONUS per run. (Function-based, because Oracle treats composite
-- keys with NULLs as duplicates, which a plain UNIQUE (receipt_id, ...) would trip over.)
CREATE UNIQUE INDEX ux_txn_receipt ON commission_txn (
  CASE WHEN txn_type IN ('BASE', 'OVERRIDE') THEN receipt_id END,
  CASE WHEN txn_type IN ('BASE', 'OVERRIDE') THEN txn_type END,
  CASE WHEN txn_type IN ('BASE', 'OVERRIDE') THEN agent_code END);
CREATE UNIQUE INDEX ux_txn_clawback ON commission_txn (
  CASE WHEN txn_type = 'CLAWBACK' THEN policy_no END,
  CASE WHEN txn_type = 'CLAWBACK' THEN agent_code END);
CREATE UNIQUE INDEX ux_txn_bonus ON commission_txn (
  CASE WHEN txn_type = 'BONUS' THEN run_id END,
  CASE WHEN txn_type = 'BONUS' THEN agent_code END);
CREATE INDEX ix_txn_run_agent ON commission_txn (run_id, agent_code);
CREATE INDEX ix_txn_policy ON commission_txn (policy_no, txn_type);

-- Rows the run could not process (no rate configured, inactive agent ...), kept for ops follow-up.
CREATE TABLE commission_exception (
  exception_id    NUMBER GENERATED ALWAYS AS IDENTITY CONSTRAINT pk_commission_exception PRIMARY KEY,
  run_id          NUMBER        NOT NULL CONSTRAINT fk_exc_run REFERENCES commission_run ON DELETE CASCADE,
  receipt_id      NUMBER,
  policy_no       VARCHAR2(12),
  ora_code        NUMBER,
  message         VARCHAR2(400) NOT NULL
);

-- What each agent is paid for a run: gross, clawback, carried-forward debit, TDS, net.
CREATE TABLE agent_statement (
  run_id          NUMBER        NOT NULL CONSTRAINT fk_stmt_run REFERENCES commission_run ON DELETE CASCADE,
  agent_code      VARCHAR2(10)  NOT NULL CONSTRAINT fk_stmt_agent REFERENCES agent,
  base_amount     NUMBER(14, 2) DEFAULT 0 NOT NULL,
  override_amount NUMBER(14, 2) DEFAULT 0 NOT NULL,
  bonus_amount    NUMBER(14, 2) DEFAULT 0 NOT NULL,
  clawback_amount NUMBER(14, 2) DEFAULT 0 NOT NULL,
  brought_forward NUMBER(14, 2) DEFAULT 0 NOT NULL,
  taxable_amount  NUMBER(14, 2) DEFAULT 0 NOT NULL,
  tds_rate        NUMBER(5, 2)  DEFAULT 0 NOT NULL,
  tds_amount      NUMBER(14, 2) DEFAULT 0 NOT NULL,
  net_payable     NUMBER(14, 2) DEFAULT 0 NOT NULL,
  carry_forward   NUMBER(14, 2) DEFAULT 0 NOT NULL,
  gst_rcm         NUMBER(14, 2) DEFAULT 0 NOT NULL,
  CONSTRAINT pk_agent_statement PRIMARY KEY (run_id, agent_code),
  CONSTRAINT ck_stmt_net CHECK (net_payable >= 0 AND carry_forward <= 0)
);

CREATE TABLE run_log (
  log_id          NUMBER GENERATED ALWAYS AS IDENTITY CONSTRAINT pk_run_log PRIMARY KEY,
  logged_at       TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  period          DATE,
  severity        VARCHAR2(5)   NOT NULL,
  message         VARCHAR2(1000) NOT NULL
);
