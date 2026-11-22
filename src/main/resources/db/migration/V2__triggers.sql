-- Rejects commission-rate windows that overlap for the same product and policy year.
-- A row trigger cannot query commission_rate while it is being changed (ORA-04091, mutating
-- table), so this compound trigger remembers the touched products per row and checks them once
-- the statement has finished.
CREATE OR REPLACE TRIGGER trg_rate_no_overlap
  FOR INSERT OR UPDATE ON commission_rate
  COMPOUND TRIGGER

  TYPE t_products IS TABLE OF BOOLEAN INDEX BY VARCHAR2(10);
  g_products t_products;

  AFTER EACH ROW IS
  BEGIN
    g_products(:NEW.product_code) := TRUE;
  END AFTER EACH ROW;

  AFTER STATEMENT IS
    l_product VARCHAR2(10) := g_products.FIRST;
    l_clash   VARCHAR2(200);
  BEGIN
    WHILE l_product IS NOT NULL LOOP
      SELECT MAX('rate ' || a.rate_id || ' overlaps rate ' || b.rate_id || ' for ' || a.product_code)
        INTO l_clash
        FROM commission_rate a
        JOIN commission_rate b
          ON b.product_code = a.product_code
         AND b.rate_id > a.rate_id
         AND a.year_from <= b.year_to AND b.year_from <= a.year_to                 -- policy years overlap
         AND a.effective_from < b.effective_to AND b.effective_from < a.effective_to -- dates overlap
       WHERE a.product_code = l_product;
      IF l_clash IS NOT NULL THEN
        g_products.DELETE;
        RAISE_APPLICATION_ERROR(-20010, 'Overlapping commission rate: ' || l_clash);
      END IF;
      l_product := g_products.NEXT(l_product);
    END LOOP;
    g_products.DELETE;
  END AFTER STATEMENT;
END trg_rate_no_overlap;
/

-- Field-level audit of changes to an agent's hierarchy, level, PAN and status:
-- these drive overrides and TDS, so every change must be traceable.
CREATE OR REPLACE TRIGGER trg_agent_audit
  AFTER UPDATE OF parent_code, agent_level, pan, status ON agent
  FOR EACH ROW
DECLARE
  PROCEDURE log_change(p_column VARCHAR2, p_old VARCHAR2, p_new VARCHAR2) IS
  BEGIN
    -- null-safe "has it changed?"
    IF (p_old IS NULL AND p_new IS NOT NULL) OR (p_old IS NOT NULL AND p_new IS NULL) OR p_old <> p_new THEN
      INSERT INTO agent_audit (agent_code, column_name, old_value, new_value)
      VALUES (:NEW.agent_code, p_column, p_old, p_new);
    END IF;
  END;
BEGIN
  log_change('PARENT_CODE', :OLD.parent_code, :NEW.parent_code);
  log_change('AGENT_LEVEL', :OLD.agent_level, :NEW.agent_level);
  -- never store a full PAN in the audit trail
  log_change('PAN', REGEXP_REPLACE(:OLD.pan, '^(.{2}).{6}', '\1xxxxxx'), REGEXP_REPLACE(:NEW.pan, '^(.{2}).{6}', '\1xxxxxx'));
  log_change('STATUS', :OLD.status, :NEW.status);
END trg_agent_audit;
/

-- An agent cannot become their own ancestor: walk up from the new parent and look for the agent.
CREATE OR REPLACE TRIGGER trg_agent_no_cycle
  FOR UPDATE OF parent_code ON agent
  COMPOUND TRIGGER

  TYPE t_codes IS TABLE OF VARCHAR2(10);
  g_codes t_codes := t_codes();

  AFTER EACH ROW IS
  BEGIN
    IF :NEW.parent_code IS NOT NULL THEN
      g_codes.EXTEND;
      g_codes(g_codes.LAST) := :NEW.agent_code;
    END IF;
  END AFTER EACH ROW;

  AFTER STATEMENT IS
    l_hits NUMBER;
    l_code VARCHAR2(10);
  BEGIN
    FOR i IN 1 .. g_codes.COUNT LOOP
      l_code := g_codes(i);
      SELECT COUNT(*) INTO l_hits
        FROM agent
       WHERE agent_code = l_code
       START WITH agent_code = (SELECT parent_code FROM agent WHERE agent_code = l_code)
       CONNECT BY NOCYCLE PRIOR parent_code = agent_code;
      IF l_hits > 0 THEN
        g_codes.DELETE;
        RAISE_APPLICATION_ERROR(-20011, 'Agent hierarchy cycle: ' || l_code || ' would report to itself');
      END IF;
    END LOOP;
    g_codes.DELETE;
  END AFTER STATEMENT;
END trg_agent_no_cycle;
/
