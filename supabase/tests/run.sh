#!/usr/bin/env bash
# Slice A+B database exit test runner.
#
# Runs every Slice A+B SQL suite, including generation and daily-coordination
# lifecycle coverage,
# against the running local Supabase Postgres container, printing a
# PASS/FAIL line per assertion (emitted by the .sql files themselves via
# RAISE NOTICE) plus a final summary, and exits non-zero if any suite failed.
#
# Every .sql file runs its entire body inside one transaction that ends in
# ROLLBACK, so no fixture rows or test-harness objects persist regardless of
# outcome, and neither file touches supabase/migrations or seed.sql.

set -uo pipefail

export PATH="$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROJECT_ID="$(sed -nE 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "${PROJECT_ROOT}/supabase/config.toml" | head -n1)"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: could not derive project_id from ${PROJECT_ROOT}/supabase/config.toml" >&2
  exit 1
fi

CONTAINER="supabase_db_${PROJECT_ID}"
if ! docker ps --format '{{.Names}}' | awk -v expected="${CONTAINER}" '$0 == expected { found = 1 } END { exit !found }'; then
  echo "ERROR: expected Postgres container ${CONTAINER} is not running" >&2
  echo "Start this project's local stack with: supabase start" >&2
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

run_suite "${SCRIPT_DIR}/commands.sql" "Core write commands suite"
commands_status=$?
[[ ${commands_status} -ne 0 ]] && overall_status=1

run_suite "${SCRIPT_DIR}/generation.sql" "Generation lifecycle suite"
generation_status=$?
[[ ${generation_status} -ne 0 ]] && overall_status=1

run_suite "${SCRIPT_DIR}/coordination.sql" "Daily coordination suite"
coordination_status=$?
[[ ${coordination_status} -ne 0 ]] && overall_status=1

run_suite "${SCRIPT_DIR}/invitations.sql" "Household invitations suite"
invitations_status=$?
[[ ${invitations_status} -ne 0 ]] && overall_status=1

run_suite "${SCRIPT_DIR}/socialization.sql" "Socialization passport suite"
socialization_status=$?
[[ ${socialization_status} -ne 0 ]] && overall_status=1

run_suite "${SCRIPT_DIR}/training.sql" "Training goals and sessions suite"
training_status=$?
[[ ${training_status} -ne 0 ]] && overall_status=1

echo ""
echo "=================================================================="
echo "SLICE A+B DATABASE TEST SUMMARY"
echo "=================================================================="
printf '  %-24s %s\n' "RLS isolation suite:" "$([[ ${rls_status} -eq 0 ]] && echo PASS || echo FAIL)"
printf '  %-24s %s\n' "Invariants suite:" "$([[ ${invariants_status} -eq 0 ]] && echo PASS || echo FAIL)"
printf '  %-24s %s\n' "Core write commands:" "$([[ ${commands_status} -eq 0 ]] && echo PASS || echo FAIL)"
printf '  %-24s %s\n' "Generation lifecycle:" "$([[ ${generation_status} -eq 0 ]] && echo PASS || echo FAIL)"
printf '  %-24s %s\n' "Daily coordination:" "$([[ ${coordination_status} -eq 0 ]] && echo PASS || echo FAIL)"
printf '  %-24s %s\n' "Household invitations:" "$([[ ${invitations_status} -eq 0 ]] && echo PASS || echo FAIL)"
printf '  %-24s %s\n' "Socialization passport:" "$([[ ${socialization_status} -eq 0 ]] && echo PASS || echo FAIL)"
printf '  %-24s %s\n' "Training goals/sessions:" "$([[ ${training_status} -eq 0 ]] && echo PASS || echo FAIL)"
echo "=================================================================="

if [[ ${overall_status} -eq 0 ]]; then
  echo "OVERALL: PASS"
else
  echo "OVERALL: FAIL"
fi

exit "${overall_status}"
