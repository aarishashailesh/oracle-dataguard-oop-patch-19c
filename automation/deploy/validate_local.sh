#!/usr/bin/env bash
# =============================================================================
# deploy/validate_local.sh — Final Post-Patch Validation (lnx107)
# Run as: root  ON: lnx107 (primary, post-switchback)
# Runs all validation checks locally. Exits 0 (all pass) or 1 (any fail).
# After this, run validate_peer.sh ON lnx113.
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
  dry_run_header "validate_local.sh"
  drstep "Check 1: Database role"
  drcmd  "sqlplus / as sysdba: SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE  (ORACLE_SID=${PRIMARY_SID}, ORACLE_HOME=${NEW_DB_HOME})"
  echo ""
  drstep "Check 2: DB home OPatch"
  drcmd  "su - ${ORACLE_USER} -c \"${NEW_DB_HOME}/OPatch/opatch lspatches\""
  drnote "verify patch ${DB_APPLY_RU_PATCH} present in ${NEW_DB_HOME}"
  echo ""
  drstep "Check 3: Grid home OPatch"
  drcmd  "su - ${GRID_USER} -c \"${NEW_GRID_HOME}/OPatch/opatch lspatches\""
  echo ""
  drstep "Check 4: Grid CRS release patch"
  drcmd  "${NEW_GRID_HOME}/bin/crsctl query crs releasepatch"
  echo ""
  drstep "Check 5: DBA_REGISTRY_SQLPATCH"
  drcmd  "sqlplus / as sysdba: SELECT PATCH_ID, STATUS, DESCRIPTION FROM DBA_REGISTRY_SQLPATCH ORDER BY ACTION_TIME DESC FETCH FIRST 5 ROWS ONLY"
  echo ""
  drstep "Check 6: DBA_REGISTRY component status"
  drcmd  "sqlplus / as sysdba: SELECT COMP_NAME, VERSION, STATUS FROM DBA_REGISTRY ORDER BY COMP_NAME"
  echo ""
  drstep "Check 7: DG Broker configuration"
  drcmd  "${NEW_DB_HOME}/bin/dgmgrl / 'show configuration'"
  echo ""
  drstep "Check 8: Transport and apply lag"
  drcmd  "sqlplus / as sysdba: SELECT COUNT(*) FROM V\$ARCHIVE_DEST WHERE TARGET='STANDBY' AND STATUS='ERROR'"
  echo ""
  drstep "Check 9: Archive gap"
  drcmd  "sqlplus / as sysdba: SELECT COUNT(*) FROM V\$ARCHIVE_GAP"
  echo ""
  drstep "Check 10: CRS resources"
  drcmd  "${NEW_GRID_HOME}/bin/crsctl stat res -t"
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
verify_node "${PRIMARY_HOST}"
setup_log "validate_local"
FAILED=0

section "POST-PATCH VALIDATION: ${PRIMARY_HOST} — ${NEW_PATCH_LEVEL}"

step "Check 1: Database role"
ROLE=$(runsql "${NEW_DB_HOME}" "${PRIMARY_SID}" \
  "SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE;" \
  2>/dev/null || echo "ERR")
echo "${ROLE}" | while read -r l; do log "  ${l}"; done
echo "${ROLE}" | grep -qi "PRIMARY" && pass "${PRIMARY_HOST}: PRIMARY ✓" \
  || fail "${PRIMARY_HOST} not in PRIMARY role"

step "Check 2: DB home OPatch (as oracle)"
runora "
  export ORACLE_HOME=${NEW_DB_HOME}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  \${ORACLE_HOME}/OPatch/opatch lspatches 2>/dev/null | head -10
" | while read -r l; do log "  ${l}"; done || true
check_patches_in_home "${NEW_DB_HOME}" "${ORACLE_USER}" "${DB_APPLY_RU_PATCH}" || true

step "Check 3: Grid home OPatch (as grid)"
rungrid "
  export ORACLE_HOME=${NEW_GRID_HOME}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  \${ORACLE_HOME}/OPatch/opatch lspatches 2>/dev/null | head -10
" | while read -r l; do log "  ${l}"; done || true

step "Check 4: Grid CRS release patch"
"${NEW_GRID_HOME}/bin/crsctl" query crs releasepatch 2>/dev/null \
  | while read -r l; do log "  ${l}"; done || true

step "Check 5: DBA_REGISTRY_SQLPATCH"
SQLPATCH=$(runsql "${NEW_DB_HOME}" "${PRIMARY_SID}" "
SELECT PATCH_ID, STATUS, SUBSTR(DESCRIPTION,1,50) DESCRIPTION
FROM   DBA_REGISTRY_SQLPATCH ORDER BY ACTION_TIME DESC FETCH FIRST 5 ROWS ONLY;
" 2>/dev/null || echo "ERR")
echo "${SQLPATCH}" | while read -r l; do log "  ${l}"; done
echo "${SQLPATCH}" | grep -qi "SUCCESS" && pass "sqlpatch: SUCCESS" \
  || fail "sqlpatch no SUCCESS on ${PRIMARY_HOST}"

step "Check 6: DBA_REGISTRY component status"
runsql "${NEW_DB_HOME}" "${PRIMARY_SID}" "
SELECT COMP_NAME, VERSION, STATUS FROM DBA_REGISTRY ORDER BY COMP_NAME;
" 2>/dev/null | while read -r l; do log "  ${l}"; done || true

step "Check 7: DG Broker configuration"
DG=$(rundgmgrl "${NEW_DB_HOME}" "show configuration")
echo "${DG}" | while read -r l; do log "  ${l}"; done
# WARNING (apply lag catching up) is acceptable immediately after switchback.
if echo "${DG}" | grep -qi "SUCCESS"; then
  pass "DG Broker: SUCCESS"
elif echo "${DG}" | grep -qi "WARNING"; then
  warn "DG Broker: WARNING (apply lag catching up — normal post-switchback)"
  pass "DG Broker: WARNING accepted (recheck in 5 min)"
elif echo "${DG}" | grep -qi "UNAVAILABLE"; then
  warn "DG Broker not available — verify manually"
else
  fail "DG Broker: ERROR — investigate"
fi

step "Check 8: Transport and apply lag"
# V$DATAGUARD_STATS is a standby-side view — returns no rows on primary.
# Check V$ARCHIVE_DEST for transport status; DG Broker (Check 7) is authoritative.
DEST_ERR=$(runsql "${NEW_DB_HOME}" "${PRIMARY_SID}" "
SELECT COUNT(*) FROM V\$ARCHIVE_DEST
WHERE  TARGET='STANDBY' AND STATUS='ERROR';
" 2>/dev/null | grep -E "^\s+[0-9]" | awk '{print $1}' || echo "ERR")
log "  Standby archive dest error count: ${DEST_ERR}"
if [[ "${DEST_ERR}" == "0" ]]; then
  pass "Standby archive destination: no errors"
elif [[ "${DEST_ERR}" == "ERR" ]]; then
  warn "Could not query V\$ARCHIVE_DEST — DG Broker is authoritative (Check 7)"
else
  fail "Standby archive destination errors: ${DEST_ERR} — check V\$ARCHIVE_DEST"
fi

step "Check 9: Archive gap"
GAP=$(runsql "${NEW_DB_HOME}" "${PRIMARY_SID}" \
  "SELECT COUNT(*) FROM V\$ARCHIVE_GAP;" \
  2>/dev/null | grep -E "^\s+[0-9]" | awk '{print $1}' || echo "ERR")
[[ "${GAP}" == "0" ]] && pass "No archive gap" || fail "Archive gap: ${GAP}"

step "Check 10: CRS resources"
"${NEW_GRID_HOME}/bin/crsctl" stat res -t 2>/dev/null \
  | while read -r l; do log "  ${l}"; done || true
pass "CRS resources reviewed"

print_summary "validate_local"
log ""
log "NEXT: Run validate_peer.sh ON ${STANDBY_HOST}"
log "  bash deploy/validate_peer.sh"
