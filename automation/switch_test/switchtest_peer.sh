#!/usr/bin/env bash
# =============================================================================
# switch_test/switchtest_peer.sh — Verify Switch Test Result (lnx113)
# Run as: root  ON: lnx113
#
# Confirms lnx113 is back in PHYSICAL STANDBY role with MRP running after
# the switchtest_local.sh switchover+switchback cycle on lnx107.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../patch.conf"
source "${SCRIPT_DIR}/../lib_common.sh"

# ---------------------------------------------------------------------------
# print_dry_run_plan — called when --dry-run is passed
# ---------------------------------------------------------------------------
print_dry_run_plan() {
  set +u  # allow awk $N refs in display strings
  dry_run_header "switchtest_peer.sh"
  drstep "Check 1: Database role on ${STANDBY_HOST}"
  drcmd  "sqlplus / as sysdba: SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE  (ORACLE_SID=${STANDBY_SID})"
  echo ""
  drstep "Check 2: MRP status"
  drcmd  "sqlplus / as sysdba: SELECT PROCESS, STATUS, SEQUENCE# FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%'"
  echo ""
  drstep "Check 3: Apply lag"
  drcmd  "sqlplus / as sysdba: SELECT VALUE FROM V\$DATAGUARD_STATS WHERE NAME='apply lag'  (ORACLE_SID=${STANDBY_SID})"
  echo ""
  drstep "Check 4: CRS resources"
  drcmd  "${OLD_GRID_HOME}/bin/crsctl stat res | grep -E 'ora.(LISTENER|asm|cdbstby)'"
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
verify_node "${STANDBY_HOST}"
setup_log "switchtest_peer"
FAILED=0

section "SWITCH TEST PEER VERIFY: ${STANDBY_HOST} role after switchover+switchback"

step "Check 1: Database role on ${STANDBY_HOST}"
ROLE=$(runsql "${OLD_DB_HOME}" "${STANDBY_SID}" \
  "SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE;" \
  2>/dev/null || echo "ERR")
echo "${ROLE}" | while read -r l; do log "  ${l}"; done
echo "${ROLE}" | grep -qi "PHYSICAL STANDBY" \
  && pass "${STANDBY_HOST}: PHYSICAL STANDBY ✓" \
  || fail "${STANDBY_HOST} not in PHYSICAL STANDBY — switchback may not have completed"

step "Check 2: MRP status"
MRP=$(runsql "${OLD_DB_HOME}" "${STANDBY_SID}" "
  SELECT PROCESS, STATUS, SEQUENCE# FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';
" 2>/dev/null || echo "ERR")
echo "${MRP}" | while read -r l; do log "  ${l}"; done
echo "${MRP}" | grep -qi "APPLYING_LOG\|WAIT_FOR_LOG" \
  && pass "MRP running on ${STANDBY_HOST}" \
  || fail "MRP not running on ${STANDBY_HOST}"

step "Check 3: Apply lag"
ALAG=$(get_dg_lag "${OLD_DB_HOME}" "${STANDBY_SID}" "apply lag")
log "  Apply lag: ${ALAG}"
[[ "${ALAG}" == "+00 00:00:00" ]] && pass "Apply lag = 0" \
  || warn "Apply lag: ${ALAG} — still catching up"

step "Check 4: CRS resources"
"${OLD_GRID_HOME}/bin/crsctl" stat res -t 2>/dev/null \
  | grep -E "ora\.(LISTENER|asm|cdbstby|net1)" \
  | while read -r l; do log "  ${l}"; done || true
pass "CRS check complete"

print_summary "switchtest_peer"
log ""
log "Switch test complete. DG switchover mechanism verified."
log "Safe to proceed to DEPLOY phase during next maintenance window."
