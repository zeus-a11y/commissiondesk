CREATE OR REPLACE PACKAGE pkg_demo_data AS
  /*
   * Synthetic, reproducible demo book: a three-branch sales hierarchy, a policy book issued over
   * three years, and the premium history each policy would have produced, including late payers
   * and early lapses. Same seed, same book.
   */
  PROCEDURE load_book(p_as_of DATE, p_policies PLS_INTEGER DEFAULT 6000, p_seed PLS_INTEGER DEFAULT 42);
  -- Calculate and approve every month with receipts, up to (not including) p_until.
  PROCEDURE run_history(p_until DATE, p_by VARCHAR2 DEFAULT 'demo-seed');
END pkg_demo_data;
/

CREATE OR REPLACE PACKAGE BODY pkg_demo_data AS

  TYPE t_names IS TABLE OF VARCHAR2(20);
  g_first t_names := t_names('Aarav', 'Vivaan', 'Aditya', 'Ishaan', 'Rohan', 'Ananya', 'Diya', 'Saanvi', 'Meera',
                             'Priya', 'Sneha', 'Rahul', 'Vikram', 'Neha', 'Pooja', 'Farhan', 'Zoya', 'Imran',
                             'Sara', 'Cyrus', 'Harpreet', 'Lakshmi', 'Venkat', 'Kavya', 'Nikhil', 'Tanvi');
  g_last  t_names := t_names('Sharma', 'Iyer', 'Nair', 'Patel', 'Shah', 'Mehta', 'Desai', 'Kulkarni', 'Joshi',
                             'Reddy', 'Rao', 'Khan', 'Irani', 'Singh', 'Gill', 'Das', 'Banerjee', 'Pillai',
                             'Menon', 'Gupta', 'Jain', 'Pawar', 'Kamath', 'Bose');

  FUNCTION pick(p_list t_names) RETURN VARCHAR2 IS
  BEGIN
    RETURN p_list(TRUNC(DBMS_RANDOM.VALUE(1, p_list.COUNT + 1)));
  END;

  FUNCTION pan_for(p_n PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'AB' || CHR(65 + MOD(p_n, 26)) || 'P' || CHR(65 + MOD(p_n * 7, 26)) || LPAD(MOD(p_n * 37, 10000), 4, '0') || CHR(65 + MOD(p_n * 3, 26));
  END;

  PROCEDURE load_book(p_as_of DATE, p_policies PLS_INTEGER DEFAULT 6000, p_seed PLS_INTEGER DEFAULT 42) IS
    TYPE t_codes IS TABLE OF VARCHAR2(10);
    l_sellers t_codes := t_codes();
    l_n       PLS_INTEGER := 0;

    TYPE t_policy IS TABLE OF policy%ROWTYPE INDEX BY PLS_INTEGER;
    l_pol     t_policy;
    TYPE t_vc  IS TABLE OF VARCHAR2(12) INDEX BY PLS_INTEGER;
    TYPE t_dt  IS TABLE OF DATE INDEX BY PLS_INTEGER;
    TYPE t_num IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    r_pol t_vc; r_due t_dt; r_paid t_dt; r_amt t_num; r_year t_num;
    l_r   PLS_INTEGER := 0;

    l_branches t_names := t_names('Mumbai West', 'Thane', 'Pune');
    l_mgr VARCHAR2(10); l_snr VARCHAR2(10); l_adv VARCHAR2(10);
    l_name VARCHAR2(60); l_pan VARCHAR2(10);  -- private functions cannot be called inside SQL
  BEGIN
    DBMS_RANDOM.SEED(p_seed);

    -- hierarchy: 3 branch managers -> 3 senior agents each -> 5 advisors each (57 agents)
    FOR b IN 1 .. 3 LOOP
      l_n := l_n + 1;
      l_mgr := 'M' || b;
      l_name := pick(g_first) || ' ' || pick(g_last); l_pan := pan_for(l_n);
      INSERT INTO agent (agent_code, name, branch, agent_level, parent_code, pan, joined_on)
      VALUES (l_mgr, l_name, l_branches(b), 'MANAGER', NULL, l_pan, DATE '2015-04-01' + 90 * b);
      FOR s IN 1 .. 3 LOOP
        l_n := l_n + 1;
        l_snr := 'S' || b || s;
        l_name := pick(g_first) || ' ' || pick(g_last); l_pan := pan_for(l_n);
        INSERT INTO agent (agent_code, name, branch, agent_level, parent_code, pan, joined_on)
        VALUES (l_snr, l_name, l_branches(b), 'SENIOR', l_mgr, l_pan, DATE '2018-04-01' + 60 * s);
        l_sellers.EXTEND; l_sellers(l_sellers.LAST) := l_snr;
        FOR a IN 1 .. 5 LOOP
          l_n := l_n + 1;
          l_adv := 'A' || b || s || a;
          l_name := pick(g_first) || ' ' || pick(g_last);
          l_pan := CASE WHEN l_adv IN ('A115', 'A324') THEN NULL ELSE pan_for(l_n) END;  -- two advisors never gave a PAN
          INSERT INTO agent (agent_code, name, branch, agent_level, parent_code, pan, joined_on)
          VALUES (l_adv, l_name, l_branches(b), 'ADVISOR', l_snr, l_pan, DATE '2021-04-01' + 45 * a);
          -- advisors sell most of the book: list each several times so they are picked more often
          FOR k IN 1 .. 4 LOOP l_sellers.EXTEND; l_sellers(l_sellers.LAST) := l_adv; END LOOP;
        END LOOP;
      END LOOP;
    END LOOP;

    -- policies and their premium history
    FOR i IN 1 .. p_policies LOOP
      DECLARE
        u       NUMBER := DBMS_RANDOM.VALUE;               -- customer's payment discipline
        pr      NUMBER := DBMS_RANDOM.VALUE;
        md      NUMBER := DBMS_RANDOM.VALUE;
        k       PLS_INTEGER;                               -- installments per year
        annual  NUMBER;
        due     DATE;
        n       PLS_INTEGER := 0;
        hazard  NUMBER;
        grace   PLS_INTEGER;
      BEGIN
        l_pol(i).policy_no    := 'CD' || LPAD(i, 8, '0');
        l_pol(i).agent_code   := l_sellers(TRUNC(DBMS_RANDOM.VALUE(1, l_sellers.COUNT + 1)));
        l_pol(i).holder_name  := pick(g_first) || ' ' || pick(g_last);
        l_pol(i).issue_date   := TRUNC(p_as_of) - TRUNC(DBMS_RANDOM.VALUE(0, 3 * 365));
        l_pol(i).product_code := CASE WHEN pr < 0.35 THEN 'TRM' WHEN pr < 0.70 THEN 'END' WHEN pr < 0.94 THEN 'ULP' ELSE 'PEN' END;
        l_pol(i).pay_mode     := CASE WHEN md < 0.40 THEN 'ANNUAL' WHEN md < 0.60 THEN 'HALF_YEARLY' ELSE 'MONTHLY' END;
        k      := CASE l_pol(i).pay_mode WHEN 'ANNUAL' THEN 1 WHEN 'HALF_YEARLY' THEN 2 ELSE 12 END;
        grace  := CASE k WHEN 12 THEN 15 ELSE 30 END;
        annual := CASE l_pol(i).product_code
                    WHEN 'TRM' THEN DBMS_RANDOM.VALUE(8000, 40000)
                    WHEN 'END' THEN DBMS_RANDOM.VALUE(30000, 150000)
                    WHEN 'ULP' THEN DBMS_RANDOM.VALUE(60000, 250000)
                    ELSE DBMS_RANDOM.VALUE(40000, 200000) END;
        l_pol(i).modal_premium := ROUND(annual / k, -1);
        l_pol(i).status := 'IN_FORCE';
        l_pol(i).lapse_date := NULL;

        due := l_pol(i).issue_date;
        WHILE due <= p_as_of LOOP
          -- yearly lapse risk falls with policy age and with payment discipline,
          -- converted to a per-installment probability
          hazard := (0.06 + 0.22 * (1 - u)) * CASE WHEN n < k THEN 1 WHEN n < 2 * k THEN 0.5 ELSE 0.25 END;
          IF n > 0 AND DBMS_RANDOM.VALUE < 1 - POWER(1 - hazard, 1 / k) THEN
            IF due + grace <= p_as_of THEN
              l_pol(i).status := 'LAPSED';
              l_pol(i).lapse_date := due + grace;
            END IF;
            EXIT;
          END IF;
          DECLARE
            paid DATE := due + ROUND(DBMS_RANDOM.VALUE(0, 1) * 25 * (1 - u));
          BEGIN
            EXIT WHEN paid > p_as_of;   -- not yet paid: still within grace
            l_r := l_r + 1;
            r_pol(l_r) := l_pol(i).policy_no; r_due(l_r) := due; r_paid(l_r) := paid;
            r_amt(l_r) := l_pol(i).modal_premium; r_year(l_r) := TRUNC(n / k) + 1;
          END;
          n := n + 1;
          due := ADD_MONTHS(l_pol(i).issue_date, n * 12 / k);
        END LOOP;
      END;
    END LOOP;

    FORALL i IN 1 .. l_pol.COUNT INSERT INTO policy VALUES l_pol(i);
    FORALL i IN 1 .. l_r
      INSERT INTO premium_receipt (policy_no, due_date, paid_date, amount, policy_year)
      VALUES (r_pol(i), r_due(i), r_paid(i), r_amt(i), r_year(i));

    -- one advisor left the company mid-2026: their renewals after that become orphan policies
    UPDATE agent SET status = 'TERMINATED', terminated_on = ADD_MONTHS(TRUNC(p_as_of, 'MM'), -5) - 1
     WHERE agent_code = 'A232';
  END load_book;

  PROCEDURE run_history(p_until DATE, p_by VARCHAR2 DEFAULT 'demo-seed') IS
    l_run NUMBER;
  BEGIN
    FOR m IN (SELECT DISTINCT TRUNC(paid_date, 'MM') AS period FROM premium_receipt
               WHERE paid_date < TRUNC(p_until, 'MM') ORDER BY 1) LOOP
      pkg_commission.calculate(m.period, l_run, p_until);
      pkg_commission.approve(l_run, p_by);
    END LOOP;
  END run_history;

END pkg_demo_data;
/
