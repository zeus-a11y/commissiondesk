#!/usr/bin/env bash
# Compiles the utPLSQL test packages into the app schema and runs them.
# Exits non-zero if any test fails or errors. Usage: db/test/run_tests.sh <container>
set -euo pipefail
CONTAINER=${1:?container name}
CONN="commission/commission@//localhost/FREEPDB1"
HERE=$(cd "$(dirname "$0")" && pwd)

for f in test_pkg_commission.pks test_pkg_commission.pkb; do
  docker exec -i "$CONTAINER" sh -c "cat > /tmp/$f" < "$HERE/$f"
done

out=$(docker exec -i "$CONTAINER" sqlplus -s -L "$CONN" <<'SQL'
set serveroutput on size unlimited feedback off lines 200 pages 0
whenever sqlerror exit failure
@/tmp/test_pkg_commission.pks
@/tmp/test_pkg_commission.pkb
SELECT 'COMPILE ' || object_name || ' ' || status FROM user_objects WHERE object_name = 'TEST_PKG_COMMISSION';
SELECT 'ERR ' || name || ' ' || line || ': ' || text FROM user_errors WHERE name = 'TEST_PKG_COMMISSION';
exec ut.run('test_pkg_commission', a_color_console => false);
SQL
)
echo "$out"
echo "$out" | grep -q "COMPILE TEST_PKG_COMMISSION INVALID" && { echo "test package did not compile"; exit 1; }
echo "$out" | grep -qE "[0-9]+ tests, 0 failed, 0 errored" || { echo "utPLSQL: failures"; exit 1; }
