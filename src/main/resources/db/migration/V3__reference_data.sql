-- Products and the commission policy (illustrative rates, % of premium received).
-- Since the IRDAI (Payment of Commission) Regulations, 2023, insurers set commission in a
-- board-approved policy rather than fixed product caps; these windows model such a policy.

INSERT INTO product (product_code, name, product_type) VALUES ('TRM', 'iProtect Term', 'TERM');
INSERT INTO product (product_code, name, product_type) VALUES ('END', 'Savings Endowment', 'ENDOWMENT');
INSERT INTO product (product_code, name, product_type) VALUES ('ULP', 'Wealth ULIP', 'ULIP');
INSERT INTO product (product_code, name, product_type) VALUES ('PEN', 'Retirement Pension', 'PENSION');

-- Term: high first-year commission, small renewals.
INSERT INTO commission_rate (product_code, year_from, year_to, rate_pct, effective_from) VALUES ('TRM', 1, 1, 30, DATE '2022-04-01');
INSERT INTO commission_rate (product_code, year_from, year_to, rate_pct, effective_from) VALUES ('TRM', 2, 3, 7.5, DATE '2022-04-01');
INSERT INTO commission_rate (product_code, year_from, year_to, rate_pct, effective_from) VALUES ('TRM', 4, 99, 5, DATE '2022-04-01');

-- Endowment: first-year rate cut from 25% to 20% from FY 2025-26 (a dated policy change).
INSERT INTO commission_rate (product_code, year_from, year_to, rate_pct, effective_from, effective_to) VALUES ('END', 1, 1, 25, DATE '2022-04-01', DATE '2025-04-01');
INSERT INTO commission_rate (product_code, year_from, year_to, rate_pct, effective_from) VALUES ('END', 1, 1, 20, DATE '2025-04-01');
INSERT INTO commission_rate (product_code, year_from, year_to, rate_pct, effective_from) VALUES ('END', 2, 3, 7.5, DATE '2022-04-01');
INSERT INTO commission_rate (product_code, year_from, year_to, rate_pct, effective_from) VALUES ('END', 4, 99, 5, DATE '2022-04-01');

-- ULIP: low commission throughout.
INSERT INTO commission_rate (product_code, year_from, year_to, rate_pct, effective_from) VALUES ('ULP', 1, 1, 8, DATE '2022-04-01');
INSERT INTO commission_rate (product_code, year_from, year_to, rate_pct, effective_from) VALUES ('ULP', 2, 99, 2, DATE '2022-04-01');

-- Pension launched before its commission was configured: receipts due before 1 Apr 2026
-- have no rate and land in the exception queue instead of being paid at a guessed rate.
INSERT INTO commission_rate (product_code, year_from, year_to, rate_pct, effective_from) VALUES ('PEN', 1, 1, 7.5, DATE '2026-04-01');
INSERT INTO commission_rate (product_code, year_from, year_to, rate_pct, effective_from) VALUES ('PEN', 2, 99, 2, DATE '2026-04-01');
