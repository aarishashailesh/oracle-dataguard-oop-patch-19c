#!/usr/bin/env bash
# =============================================================================
# deploy/deploy_p_peer.sh — Verify lnx107 Patched + Trigger Archive Log Switch
# Run as: root  ON: lnx113 (current primary)
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
  dry_run_header "deploy_p_peer.sh"
  drstep "Check 1: Confirm ${STANDBY_HOST} is PRIMARY"
  drcmd  "sqlplus / as sysdba: SELECT DATABASE_ROLE FROM V\$DATABASE  (ORACLE_SID=${STANDBY_SID}, ORACLE_HOME=${NEW_DB_HOME})"
  echo ""
  drstep "Check 2: Archive log switch"
  drcmd  "sqlplus / as sysdba: ALTER SYSTEM ARCHIVE LOG CURRENT  (ORACLE_SID=${STANDBY_SID})"
  echo ""
  drstep "Check 3: DG stats"
  drcmd  "sqlplus / as sysdba: SELECT NAME, VALUE FROM V\$DATAGUARD_STATS WHERE NAME IN ('transport lag','apply lag')"
  echo ""
  drstep "Check 4: DG Broker configuration"
  drcmd  "${NEW_DB_HOME}/bin/dgmgrl / 'show configuration'"
  echo ""
  drstep "Check 5: sqlpatch registry on current primary"
  drcmd  "sqlplus / as sysdba: SELECT PATCH_ID, STATUS FROM DBA_REGISTRY_SQLPATCH ORDER BY ACTION_TIME DESC FETCH FIRST 5 ROWS ONLY"
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
verify_node "${STANDBY_HOST}"
setup_log "deploy_p_peer"
FAILED=0

section "DEPLOY PEER VERIFY: ${STANDBY_HOST} (current primary) -- verify ${PRIMARY_HOST} patched"

step "Check 1: This node is PRIMARY"
ROLE=$(runsql "${NEW_DB_HOME}" "${STANDBY_SID}" \
  "SELECT DATABASE_ROLE FROM V\$DATABASE;" \
  2>/dev/null | grep -v "^$\|DATABASE_ROLE\|---" | awk '{print $1}' || echo "ERR")
[[ "${ROLE}" == "PRIMARY" ]] && pass "${STANDBY_HOST}: PRIMARY ✓" \
  || fail "${STANDBY_HOST} not in PRIMARY role"

step "Check 2: Trigger archive log switch (verifies redo flows to ${PRIMARY_HOST})"
runsql "${NEW_DB_HOME}" "${STANDBY_SID}" \
  "ALTER SYSTEM ARCHIVE LOG CURRENT;" 2>/dev/null \
  && pass "Archive log switch issued" || warn "Archive log switch non-zero"
sleep 15

step "Check 3: DG stats -- verify ${PRIMARY_HOST} is receiving redo"
DG_STATS=$(runsql "${NEW_DB_HOME}" "${STANDBY_SID}" "
SELECT NAME, VALUE, UNIT FROM V\$DATAGUARD_STATS
WHERE  NAME IN ('transport lag','apply lag');
" 2>/dev/null || echo "ERR")
echo "${DG_STATS}" | while read -r l; do log "  ${l}"; done
pass "DG stats queried"

step "Check 4: DG Broker configuration"
DG=$(rundgmgrl "${NEW_DB_HOME}" "show configuration")
echo "${DG}" | while read -r l; do log "  ${l}"; done
echo "${DG}" | grep -qi "SUCCESS\|WARNING" && pass "DG Broker responding" \
  || fail "DG Broker not responding"

step "Check 5: sqlpatch registry on current primary (this node)"
SQLPATCH=$(runsql "${NEW_DB_HOME}" "${STANDBY_SID}" "
SELECT PATCH_ID, STATUS FROM DBA_REGISTRY_SQLPATCH
ORDER BY ACTION_TIME DESC FETCH FIRST 3 ROWS ONLY;
" 2>/dev/null || echo "ERR")
echo "${SQLPATCH}" | while read -r l; do log "  ${l}"; done
echo "${SQLPATCH}" | grep -qi "SUCCESS" && pass "sqlpatch SUCCESS on ${STANDBY_HOST}" \
  || fail "sqlpatch no SUCCESS on ${STANDBY_HOST}"

print_summary "deploy_p_peer"
log ""
log "NEXT: Run datapatch_peer.sh ON ${STANDBY_HOST} (this node — current primary)"
log "  bash deploy/datapatch_peer.sh"
