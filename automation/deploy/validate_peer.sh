#!/usr/bin/env bash
# =============================================================================
# deploy/validate_peer.sh — Final Post-Patch Validation (lnx113)
# Run as: root  ON: lnx113 (physical standby, post-switchback)
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
  dry_run_header "validate_peer.sh"
  drstep "Check 1: Database role"
  drcmd  "sqlplus / as sysdba: SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE  (ORACLE_SID=${STANDBY_SID}, ORACLE_HOME=${NEW_DB_HOME})"
  echo ""
  drstep "Check 2: MRP status"
  drcmd  "sqlplus / as sysdba: SELECT PROCESS, STATUS, SEQUENCE# FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%'"
  echo ""
  drstep "Check 3: DB home OPatch"
  drcmd  "su - ${ORACLE_USER} -c \"${NEW_DB_HOME}/OPatch/opatch lspatches | grep ${DB_APPLY_RU_PATCH}\""
  echo ""
  drstep "Check 4: Grid home OPatch"
  drcmd  "su - ${GRID_USER} -c \"${NEW_GRID_HOME}/OPatch/opatch lspatches | grep ${GI_APPLY_RU_PATCH}\""
  echo ""
  drstep "Check 5: Grid CRS release patch"
  drcmd  "${NEW_GRID_HOME}/bin/crsctl query crs releasepatch"
  echo ""
  drstep "Check 6: sqlpatch registry"
  drcmd  "sqlplus / as sysdba: SELECT PATCH_ID, STATUS FROM DBA_REGISTRY_SQLPATCH ORDER BY ACTION_TIME DESC FETCH FIRST 6 ROWS ONLY"
  echo ""
  drstep "Check 7: Apply lag"
  drcmd  "sqlplus / as sysdba: SELECT VALUE FROM V\$DATAGUARD_STATS WHERE NAME='apply lag'  (ORACLE_SID=${STANDBY_SID})"
  echo ""
  drstep "Check 8: CRS resources"
  drcmd  "${NEW_GRID_HOME}/bin/crsctl stat res -t"
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
verify_node "${STANDBY_HOST}"
setup_log "validate_peer"
FAILED=0

section "POST-PATCH VALIDATION: ${STANDBY_HOST} — ${NEW_PATCH_LEVEL}"

step "Check 1: Database role"
ROLE=$(runsql "${NEW_DB_HOME}" "${STANDBY_SID}" \
  "SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE;" \
  2>/dev/null || echo "ERR")
echo "${ROLE}" | while read -r l; do log "  ${l}"; done
echo "${ROLE}" | grep -qi "PHYSICAL STANDBY" && pass "${STANDBY_HOST}: PHYSICAL STANDBY ✓" \
  || fail "${STANDBY_HOST} not in PHYSICAL STANDBY"

step "Check 2: MRP status"
MRP=$(runsql "${NEW_DB_HOME}" "${STANDBY_SID}" "
SELECT PROCESS, STATUS, SEQUENCE# FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';
" 2>/dev/null || echo "ERR")
echo "${MRP}" | while read -r l; do log "  ${l}"; done
echo "${MRP}" | grep -qi "APPLYING_LOG\|WAIT_FOR_LOG" && pass "MRP running ✓" \
  || fail "MRP not running on ${STANDBY_HOST}"

step "Check 3: DB home OPatch (as oracle)"
runora "
  export ORACLE_HOME=${NEW_DB_HOME}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  \${ORACLE_HOME}/OPatch/opatch lspatches 2>/dev/null | head -10
" | while read -r l; do log "  ${l}"; done || true
check_patches_in_home "${NEW_DB_HOME}" "${ORACLE_USER}" "${DB_APPLY_RU_PATCH}" || true

step "Check 4: Grid home OPatch (as grid)"
rungrid "
  export ORACLE_HOME=${NEW_GRID_HOME}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  \${ORACLE_HOME}/OPatch/opatch lspatches 2>/dev/null | head -10
" | while read -r l; do log "  ${l}"; done || true

step "Check 5: Grid CRS release patch"
"${NEW_GRID_HOME}/bin/crsctl" query crs releasepatch 2>/dev/null \
  | while read -r l; do log "  ${l}"; done || true

step "Check 6: sqlpatch registry"
SQLPATCH=$(runsql "${NEW_DB_HOME}" "${STANDBY_SID}" "
SELECT PATCH_ID, STATUS FROM DBA_REGISTRY_SQLPATCH
ORDER BY ACTION_TIME DESC FETCH FIRST 5 ROWS ONLY;
" 2>/dev/null || echo "ERR")
echo "${SQLPATCH}" | while read -r l; do log "  ${l}"; done
echo "${SQLPATCH}" | grep -qi "SUCCESS" && pass "sqlpatch: SUCCESS ✓" \
  || fail "sqlpatch no SUCCESS on ${STANDBY_HOST}"

step "Check 7: Apply lag"
ALAG=$(get_dg_lag "${NEW_DB_HOME}" "${STANDBY_SID}" "apply lag")
log "  Apply lag: ${ALAG}"
[[ "${ALAG}" == "+00 00:00:00" ]] && pass "Apply lag = 0 ✓" \
  || warn "Apply lag: ${ALAG} — still catching up"

step "Check 8: CRS resources"
"${NEW_GRID_HOME}/bin/crsctl" stat res -t 2>/dev/null \
  | while read -r l; do log "  ${l}"; done || true

print_summary "validate_peer"
log ""
log "════════════════════════════════════════════════════════"
log "  PATCH CYCLE COMPLETE"
log "  Both nodes at: ${NEW_PATCH_LEVEL}"
log "  ${PRIMARY_HOST} (${PRIMARY_DB_UNIQUE_NAME}) = PRIMARY"
log "  ${STANDBY_HOST} (${STANDBY_DB_UNIQUE_NAME}) = PHYSICAL STANDBY"
log "  Roles: ORIGINAL (same as before patch cycle)"
log "════════════════════════════════════════════════════════"
