#!/usr/bin/env bash
# WP-1 exit test runner: RLS isolation + invariant enforcement.
#
# Runs supabase/tests/rls_isolation.sql and supabase/tests/invariants.sql
# against the running local Supabase Postgres container, printing a
# PASS/FAIL line per assertion (emitted by the .sql files themselves via
# RAISE NOTICE) plus a final summary, and exits non-zero if either suite
# failed.
#
# Both .sql files run their entire body inside one transaction that ends in
# ROLLBACK, so no fixture rows or test-harness objects persist regardless of
# outcome, and neither file touches supabase/migrations or seed.sql.

set -uo pipefail

export PATH="$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTAINER="$(docker ps --format '{{.Names}}' | grep supabase_db | head -n1)"
if [[ -z "${CONTAINER}" ]]; then
  echo "ERROR: no running supabase_db_* container found (is the local Supabase stack up?)" >&2
  exit 1
fi
echo "Using Postgres container: ${CONTAINER}"

run_suite() {
  local file="$1"
  local label="$2"

  echo ""
  echo "=================================================================="
  echo "Running ${label}  (${file})"
  echo "=================================================================="

  docker exec -i "${CONTAINER}" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "${file}"
  local status=$?

  echo "------------------------------------------------------------------"
  if [[ ${status} -eq 0 ]]; then
    echo "${label}: PASS (script completed, all assertions passed, transaction rolled back)"
  else
    echo "${label}: FAIL (see [FAIL] lines above; exit code ${status})"
  fi
  return "${status}"
}

overall_status=0

run_suite "${SCRIPT_DIR}/rls_isolation.sql" "RLS isolation suite"
rls_status=$?
[[ ${rls_status} -ne 0 ]] && overall_status=1

run_suite "${SCRIPT_DIR}/invariants.sql" "Invariants suite"
invariants_status=$?
[[ ${invariants_status} -ne 0 ]] && overall_status=1

echo ""
echo "=================================================================="
echo "WP-1 EXIT TEST SUMMARY"
echo "=================================================================="
printf '  %-24s %s\n' "RLS isolation suite:" "$([[ ${rls_status} -eq 0 ]] && echo PASS || echo FAIL)"
printf '  %-24s %s\n' "Invariants suite:" "$([[ ${invariants_status} -eq 0 ]] && echo PASS || echo FAIL)"
echo "=================================================================="

if [[ ${overall_status} -eq 0 ]]; then
  echo "OVERALL: PASS"
else
  echo "OVERALL: FAIL"
fi

exit "${overall_status}"
