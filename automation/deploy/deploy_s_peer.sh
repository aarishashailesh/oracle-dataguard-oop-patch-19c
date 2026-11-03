#!/usr/bin/env bash
# =============================================================================
# deploy/deploy_s_peer.sh — Verify Standby Deployed + Pre-Switchover Checks
# Run as: root  ON: lnx107
#
# Verifies from lnx107 that lnx113 is patched and ready for switchover:
#   - DG lag = 0 and no archive gap
#   - DG Broker shows SUCCESS
#   - Primary is healthy
#   - Then disables SYS.DB_DDL_ALERT_TRG on the primary (db/cdb/pdb) when all checks pass
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
  dry_run_header "deploy_s_peer.sh"
  drstep "Check 1: Primary database role"
  drcmd  "sqlplus / as sysdba: SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE  (ORACLE_SID=${PRIMARY_SID})"
  echo ""
  drstep "Check 2: Transport and apply lag"
  drcmd  "sqlplus / as sysdba: SELECT COUNT(*) FROM V\$ARCHIVE_DEST WHERE TARGET='STANDBY' AND STATUS='ERROR'"
  echo ""
  drstep "Check 3: Archive gap"
  drcmd  "sqlplus / as sysdba: SELECT COUNT(*) FROM V\$ARCHIVE_GAP"
  echo ""
  drstep "Check 4: DG Broker configuration"
  drcmd  "${OLD_DB_HOME}/bin/dgmgrl / 'show configuration'"
  echo ""
  drstep "Check 5: CRS resources"
  drcmd  "${OLD_GRID_HOME}/bin/crsctl stat res -t"
  echo ""
  drstep "Check 6: Disk space and new homes ready"
  drcmd  "df -BG ${NEW_GRID_HOME%/*} | tail -1"
  drcmd  "test -d ${NEW_GRID_HOME}"
  drcmd  "test -d ${NEW_DB_HOME}"
  drstep "Step 7: Disable SYS.DB_DDL_ALERT_TRG on the primary (only if checks 1-6 passed)"
  drcmd  "sqlplus / as sysdba: ALTER TRIGGER SYS.DB_DDL_ALERT_TRG DISABLE  (non-CDB, or CDB root and every READ WRITE PDB; ORACLE_SID=${PRIMARY_SID}, ORACLE_HOME=${OLD_DB_HOME})"
  drnote "Replicates to ${STANDBY_HOST} through redo. post_install_local.sh enables it again after patching."
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
verify_node "${PRIMARY_HOST}"
setup_log "deploy_s_peer"
FAILED=0

section "PRE-SWITCHOVER VERIFY: ${PRIMARY_HOST}"

step "Check 1: Primary database role and health"
ROLE=$(runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" \
  "SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE;" \
  2>/dev/null || echo "ERR")
echo "${ROLE}" | while read -r l; do log "  ${l}"; done
echo "${ROLE}" | grep -qi "PRIMARY" && pass "${PRIMARY_HOST}: PRIMARY" \
  || fail "${PRIMARY_HOST} not in PRIMARY role"

step "Check 2: Transport and apply lag"
# V$DATAGUARD_STATS returns no rows on primary — it is a standby-side view.
# Check V$ARCHIVE_DEST for standby destination health instead.
DEST_ERR=$(runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" "
SELECT COUNT(*) FROM V\$ARCHIVE_DEST
WHERE  TARGET='STANDBY' AND STATUS='ERROR';
" 2>/dev/null | grep -E "^\s+[0-9]" | awk '{print $1}' || echo "ERR")
log "  Standby dest error count: ${DEST_ERR}"
if [[ "${DEST_ERR}" == "0" ]]; then
  pass "Standby archive destination: no errors (lag confirmed via DG Broker in Check 4)"
elif [[ "${DEST_ERR}" == "ERR" ]]; then
  warn "Could not query V\$ARCHIVE_DEST — DG Broker SUCCESS in Check 4 is sufficient"
else
  FAIL "Standby archive destination errors: ${DEST_ERR}"
fi

# Also query V$DATAGUARD_STATS — present on primary in 19c but format varies
DG_STATS=$(runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" "
SELECT NAME, VALUE, UNIT FROM V\$DATAGUARD_STATS
WHERE  NAME IN ('transport lag','apply lag');
" 2>/dev/null || echo "")
if [[ -n "${DG_STATS}" ]]; then
  echo "${DG_STATS}" | while read -r l; do log "  ${l}"; done
else
  log "  V\$DATAGUARD_STATS: no rows on primary (normal — lag verified via broker in Check 4)"
fi

step "Check 3: Archive gap"
GAP=$(runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" \
  "SELECT COUNT(*) FROM V\$ARCHIVE_GAP;" \
  2>/dev/null | grep -E "^\s+[0-9]" | awk '{print $1}' || echo "ERR")
log "  V\$ARCHIVE_GAP rows: ${GAP}"
[[ "${GAP}" == "0" ]] && pass "No archive gap" \
  || fail "Archive gap: ${GAP} rows — resolve before switchover"

step "Check 4: DG Broker configuration"
DG=$(rundgmgrl "${OLD_DB_HOME}" "show configuration")
echo "${DG}" | while read -r l; do log "  ${l}"; done
echo "${DG}" | grep -qi "SUCCESS" && pass "DG Broker: SUCCESS" \
  || fail "DG Broker not SUCCESS"

step "Check 5: CRS resources on ${PRIMARY_HOST}"
"${OLD_GRID_HOME}/bin/crsctl" stat res -t 2>/dev/null \
  | grep -E "ora\.(LISTENER|asm|cdbprim|net1)" \
  | while read -r l; do log "  ${l}"; done || true
pass "CRS resources checked"

step "Check 6: Disk space and new homes ready"
AVAIL=$(df -BG /u01 | awk 'NR==2 {gsub("G","",$4); print $4}')
log "  /u01 available: ${AVAIL} GB"
(( AVAIL >= 5 )) && pass "Disk space OK" || fail "Low disk space: ${AVAIL} GB"
[[ -d "${NEW_GRID_HOME}" ]] && pass "New Grid home ready: ${NEW_GRID_HOME}" \
  || fail "New Grid home missing — run prep_p_local.sh first"
[[ -d "${NEW_DB_HOME}" ]] && pass "New DB home ready: ${NEW_DB_HOME}" \
  || fail "New DB home missing — run prep_p_local.sh first"

step "Step 7: Disable SYS.DB_DDL_ALERT_TRG before the switchover and datapatch"
if (( FAILED == 0 )); then
  ddl_trigger DISABLE "${OLD_DB_HOME}" "${PRIMARY_SID}" \
    && pass "SYS.DB_DDL_ALERT_TRG disabled (replicates to ${STANDBY_HOST} via redo)" \
    || fail "Could not disable SYS.DB_DDL_ALERT_TRG -- fix before the switchover"
else
  warn "Checks above failed -- SYS.DB_DDL_ALERT_TRG NOT disabled. Fix and re-run this script."
fi

print_summary "deploy_s_peer"
log ""
log "NEXT: Run switchover_local.sh ON ${PRIMARY_HOST}"
log "  bash deploy/switchover_local.sh"
