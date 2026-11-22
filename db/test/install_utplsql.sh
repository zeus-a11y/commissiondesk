#!/usr/bin/env bash
# Installs utPLSQL into the running Oracle container (schema UT3, public synonyms).
# Usage: db/test/install_utplsql.sh <container> [sys-password]
set -euo pipefail
CONTAINER=${1:?container name}
SYS_PWD=${2:-oracle}
VERSION=v.3.2.3
WORK=$(mktemp -d "${TMPDIR:-.}/utplsql.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

base="https://github.com/utPLSQL/utPLSQL/releases/download/$VERSION"
curl -sSfL -o "$WORK/utPLSQL.tar.gz" "$base/utPLSQL.tar.gz"
curl -sSfL -o "$WORK/utPLSQL.tar.gz.sha256" "$base/utPLSQL.tar.gz.sha256"
expected=$(awk '{print $NF}' "$WORK/utPLSQL.tar.gz.sha256")  # BSD format: SHA256 (file) = hash
actual=$(sha256sum "$WORK/utPLSQL.tar.gz" | awk '{print $1}')
[ "$expected" = "$actual" ] || { echo "utPLSQL checksum mismatch"; exit 1; }

docker exec -i "$CONTAINER" sh -c 'cat > /tmp/utPLSQL.tar.gz' < "$WORK/utPLSQL.tar.gz"
docker exec -i "$CONTAINER" bash -s <<SH
set -e
cd /tmp && rm -rf utPLSQL && tar -xzf utPLSQL.tar.gz
cd utPLSQL/source
sqlplus -s -L "sys/$SYS_PWD@//localhost/FREEPDB1 as sysdba" @install_headless.sql ut3 ut3 users > /tmp/utplsql_install.log 2>&1 || { tail -40 /tmp/utplsql_install.log; exit 1; }
tail -3 /tmp/utplsql_install.log
SH
