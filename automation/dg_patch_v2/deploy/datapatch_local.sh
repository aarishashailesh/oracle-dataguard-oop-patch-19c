#!/usr/bin/env bash
# =============================================================================
# deploy/datapatch_local.sh — Verify Datapatch Applied via Redo (lnx107)
# Run as: root  ON: lnx107 (physical standby)
# Confirms that SQL dictionary changes have propagated from lnx113 via redo.
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
  dry_run_header "datapatch_local.sh"
  drstep "Check 1: MRP still running"
  drcmd  "sqlplus / as sysdba: SELECT PROCESS, STATUS, SEQUENCE# FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%'  (ORACLE_SID=${PRIMARY_SID}, ORACLE_HOME=${NEW_DB_HOME})"
  echo ""
  drstep "Check 2: Apply lag"
  drcmd  "sqlplus / as sysdba: SELECT VALUE FROM V\$DATAGUARD_STATS WHERE NAME='apply lag'  (ORACLE_SID=${PRIMARY_SID})"
  echo ""
  drstep "Check 3: Archive gap"
  drcmd  "sqlplus / as sysdba: SELECT COUNT(*) FROM V\$ARCHIVE_GAP  (ORACLE_SID=${PRIMARY_SID})"
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
verify_node "${PRIMARY_HOST}"
setup_log "datapatch_local"
FAILED=0

section "DATAPATCH VERIFY: ${PRIMARY_HOST} (standby — verify redo applied)"

step "Check 1: MRP still running"
MRP=$(runsql "${NEW_DB_HOME}" "${PRIMARY_SID}" "
SELECT PROCESS, STATUS, SEQUENCE# FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';
" 2>/dev/null || echo "ERR")
echo "${MRP}" | while read -r l; do log "  ${l}"; done
echo "${MRP}" | grep -qi "APPLYING_LOG\|WAIT_FOR_LOG" && pass "MRP running" \
  || fail "MRP not running on ${PRIMARY_HOST}"

step "Check 2: Apply lag"
ALAG=$(get_dg_lag "${NEW_DB_HOME}" "${PRIMARY_SID}" "apply lag")
log "  Apply lag: ${ALAG}"
[[ "${ALAG}" == "+00 00:00:00" ]] && pass "Apply lag = 0" \
  || warn "Apply lag: ${ALAG} — dictionary changes still propagating"

step "Check 3: Archive gap"
GAP=$(runsql "${NEW_DB_HOME}" "${PRIMARY_SID}" \
  "SELECT COUNT(*) FROM V\$ARCHIVE_GAP;" \
  2>/dev/null | grep -E "^\s+[0-9]" | awk '{print $1}' || echo "ERR")
[[ "${GAP}" == "0" ]] && pass "No archive gap" || fail "Archive gap: ${GAP}"

print_summary "datapatch_local"
log ""
log "NEXT: Run switchback_local.sh ON ${PRIMARY_HOST} (this node)"
log "  bash deploy/switchback_local.sh"
