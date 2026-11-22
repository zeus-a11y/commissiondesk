-- Flyway callback, runs after every migrate. Oracle compiles PL/SQL with errors and only warns
-- (ORA-17110), so a broken package would otherwise deploy "successfully". Fail the deployment instead.
DECLARE
  l_bad VARCHAR2(4000);
BEGIN
  SELECT LISTAGG(object_type || ' ' || object_name, ', ') WITHIN GROUP (ORDER BY object_name)
    INTO l_bad
    FROM user_objects
   WHERE status = 'INVALID';
  IF l_bad IS NOT NULL THEN
    RAISE_APPLICATION_ERROR(-20099, 'Invalid PL/SQL after migration: ' || l_bad);
  END IF;
END;
/
