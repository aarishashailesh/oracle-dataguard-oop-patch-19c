#!/usr/bin/env bash
# =============================================================================
# deploy/datapatch_peer.sh — Run datapatch on Current Primary (lnx113)
# Run as: root  ON: lnx113 (current primary after switchover)
#
# datapatch applies SQL-level data dictionary changes for the new patch level.
# Must run on the CURRENT PRIMARY only. Dictionary changes propagate to the
# standby automatically via redo — do NOT run datapatch on lnx107.
#
# This script uses datapatch directly. AutoUpgrade in patch mode does not
# support run_datapatch as a parameter (only in upgrade mode). Before
# running datapatch, the xml inventory in the database is reloaded via
# DBMS_QOPATCH.load_xml_inventory to prevent stale-inventory failures
# (ORA-20001: Latest xml inventory is not loaded into table).
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
  dry_run_header "datapatch_peer.sh"
  drstep "Step 1: Confirm ${STANDBY_HOST} is PRIMARY"
  drcmd  "sqlplus / as sysdba: SELECT DATABASE_ROLE FROM V\$DATABASE  (ORACLE_SID=${STANDBY_SID}, ORACLE_HOME=${NEW_DB_HOME})"
  echo ""
  drstep "Step 2: Confirm all PDBs open"
  drcmd  "sqlplus / as sysdba: SELECT CON_ID, NAME, OPEN_MODE FROM V\$PDBS ORDER BY CON_ID"
  echo ""
  drstep "Step 3: Reload xml inventory (prevents ORA-20001 after home switch)"
  drcmd  "sqlplus / as sysdba: EXEC SYS.DBMS_QOPATCH.load_xml_inventory  (ORACLE_SID=${STANDBY_SID})"
  echo ""
  drstep "Step 4: Run datapatch -verbose"
  drcmd  "su - ${ORACLE_USER} -c \"ORACLE_HOME=${NEW_DB_HOME} ORACLE_SID=${STANDBY_SID} ${NEW_DB_HOME}/OPatch/datapatch -verbose\""
  drnote "Applies SQL dictionary changes for patch level ${NEW_PATCH_LEVEL} on all open PDBs"
  drnote "Dictionary changes propagate to ${PRIMARY_HOST} (standby) via redo automatically"
  drnote "Estimated time: 15-30 minutes"
  echo ""
  drstep "Step 5: Verify DBA_REGISTRY_SQLPATCH"
  drcmd  "sqlplus / as sysdba: SELECT PATCH_ID, STATUS, DESCRIPTION FROM DBA_REGISTRY_SQLPATCH ORDER BY ACTION_TIME DESC FETCH FIRST 8 ROWS ONLY"
  echo ""
  drstep "Step 6: Run utlrp"
  drcmd  "sqlplus / as sysdba: @?/rdbms/admin/utlrp  (ORACLE_SID=${STANDBY_SID})"
  echo ""
  drstep "Step 7: Check invalid objects"
  drcmd  "sqlplus / as sysdba: SELECT COUNT(*) FROM DBA_OBJECTS WHERE STATUS='INVALID'"
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
verify_node "${STANDBY_HOST}"
setup_log "datapatch_peer"
FAILED=0

section "DATAPATCH: ${STANDBY_HOST} (current primary)"

step "Step 1: Confirm this node is PRIMARY"
ROLE=$(runsql "${NEW_DB_HOME}" "${STANDBY_SID}" \
  "SELECT DATABASE_ROLE FROM V\$DATABASE;" \
  2>/dev/null | grep -v "^$\|DATABASE_ROLE\|---" | sed 's/^[[:space:]]*//' | head -1 || echo "ERR")
[[ "${ROLE}" == "PRIMARY" ]] && pass "Role: PRIMARY OK" \
  || { fail "Not PRIMARY -- datapatch must run on the primary"; exit 1; }

step "Step 2: Confirm all PDBs are open"
runsql "${NEW_DB_HOME}" "${STANDBY_SID}" "
SELECT CON_ID, NAME, OPEN_MODE FROM V\$PDBS ORDER BY CON_ID;
" 2>/dev/null | while read -r l; do log "  ${l}"; done || true
log "  Note: datapatch only applies to open PDBs."

step "Step 3: Reload xml inventory in database (prevents ORA-20001)"
# After an OOP home switch, the xml inventory stored in the database can be
# stale. Reloading it before datapatch prevents DBMS_QOPATCH errors.
log "  Running DBMS_QOPATCH.load_xml_inventory on all containers..."
runsql "${NEW_DB_HOME}" "${STANDBY_SID}" "
EXEC SYS.DBMS_QOPATCH.load_xml_inventory;
" 2>/dev/null && pass "xml inventory reloaded" \
  || warn "DBMS_QOPATCH.load_xml_inventory returned non-zero -- proceeding"

step "Step 4: Run datapatch -verbose"
log "  Applying SQL-level dictionary changes for patch level ${NEW_PATCH_LEVEL}."
log "  Typically takes 15-30 minutes for a CDB with multiple PDBs."
runora "
  export ORACLE_HOME=${NEW_DB_HOME}
  export ORACLE_SID=${STANDBY_SID}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  \${ORACLE_HOME}/OPatch/datapatch -verbose
" && pass "datapatch complete" \
  || { fail "datapatch failed -- review ${NEW_DB_HOME}/cfgtoollogs/datapatch"; exit 1; }

step "Step 5: Verify DBA_REGISTRY_SQLPATCH"
SQLPATCH=$(runsql "${NEW_DB_HOME}" "${STANDBY_SID}" "
SELECT PATCH_ID, STATUS, SUBSTR(DESCRIPTION,1,60) DESCRIPTION
FROM   DBA_REGISTRY_SQLPATCH ORDER BY ACTION_TIME DESC FETCH FIRST 8 ROWS ONLY;
" 2>/dev/null || echo "ERR")
echo "${SQLPATCH}" | while read -r l; do log "  ${l}"; done
echo "${SQLPATCH}" | grep -qi "SUCCESS" && pass "sqlpatch: SUCCESS entries found" \
  || fail "No SUCCESS entries in sqlpatch -- review DBA_REGISTRY_SQLPATCH"

# Count patches where most recent action is not SUCCESS.
# WITH ERRORS (PREV PATCH) entries for historical failed attempts are expected.
FAILED_PATCHES=$(runsql "${NEW_DB_HOME}" "${STANDBY_SID}" "
SELECT COUNT(*) FROM (
  SELECT PATCH_ID, STATUS,
         ROW_NUMBER() OVER (PARTITION BY PATCH_ID ORDER BY ACTION_TIME DESC) RN
  FROM   DBA_REGISTRY_SQLPATCH
) WHERE RN=1 AND STATUS NOT IN ('SUCCESS','WITH ERRORS');
" 2>/dev/null | grep -E "^\s+[0-9]" | awk '{print $1}' || echo "ERR")
log "  Patches with non-SUCCESS latest action: ${FAILED_PATCHES}"
[[ "${FAILED_PATCHES}" == "0" ]] && pass "All current patches SUCCESS" \
  || fail "Non-SUCCESS patches: ${FAILED_PATCHES} -- review DBA_REGISTRY_SQLPATCH"

step "Step 6: Run utlrp (recompile invalid objects)"
runora "
  export ORACLE_HOME=${NEW_DB_HOME}
  export ORACLE_SID=${STANDBY_SID}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  \${ORACLE_HOME}/bin/sqlplus -s / as sysdba <<'SQLEOF'
@?/rdbms/admin/utlrp
EXIT;
SQLEOF
" && pass "utlrp complete" || warn "utlrp returned non-zero"

step "Step 7: Check for invalid objects"
INVALID=$(runsql "${NEW_DB_HOME}" "${STANDBY_SID}" "
SELECT COUNT(*) FROM DBA_OBJECTS WHERE STATUS='INVALID';
" 2>/dev/null | grep -E "^\s+[0-9]" | awk '{print $1}' || echo "ERR")
log "  Invalid objects: ${INVALID}"
[[ "${INVALID}" == "0" ]] && pass "No invalid objects" \
  || warn "Invalid objects: ${INVALID} -- investigate if unexpected"

print_summary "datapatch_peer"
log ""
log "NEXT: Run datapatch_local.sh ON ${PRIMARY_HOST} to verify redo applied"
log "  bash deploy/datapatch_local.sh"
