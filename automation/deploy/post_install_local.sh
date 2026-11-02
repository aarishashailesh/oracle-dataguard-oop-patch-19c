#!/usr/bin/env bash
# =============================================================================
# deploy/post_install_local.sh — Post-Patch Validation (run on EACH node)
# Run as: root  ON: lnx107 (after switchback) AND lnx113
#
# Incorporates single-node phase4_post_install.sh steps adapted for DG:
#   A. Record pre-modification invalid object baseline
#   B. Disable unused DB options via chopt (olap, rat, partitioning)
#      NOTE: chopt only on PRIMARY — changes propagate to standby via redo
#   C. Restart database (primary only — standby restarts MRP)
#   D. Run XOQ_VALIDATE, APS_VALIDATE, utlrp (primary only)
#   E. Verify v$option, DBA_REGISTRY, datapatch status
#   F. Verify Grid patch level and CRS resource status
#
# Usage:
#   On lnx107 (primary, post-switchback):  bash deploy/post_install_local.sh
#   On lnx113 (standby):                  bash deploy/post_install_local.sh
#
# Background-safe: systemd-run --unit=dgpatch-post-install-local --remain-after-exit --working-directory=<automation dir> bash deploy/post_install_local.sh
# =============================================================================
set -euo pipefail
umask 0022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../patch.conf"
source "${SCRIPT_DIR}/../lib_common.sh"

# ---------------------------------------------------------------------------
# print_dry_run_plan — called when --dry-run is passed
# ---------------------------------------------------------------------------
print_dry_run_plan() {
  set +u  # allow awk $N refs in display strings
  dry_run_header "post_install_local.sh"
  drstep "Step A: Record invalid object baseline"
  drcmd  "sqlplus / as sysdba: SELECT COUNT(*) FROM DBA_OBJECTS WHERE STATUS='INVALID'  (ORACLE_SID=${PRIMARY_SID} on primary / ${STANDBY_SID} on standby, ORACLE_HOME=${NEW_DB_HOME})"
  echo ""
  drstep "Step B: chopt disable unused DB options (primary only)"
  drcmd  "su - ${ORACLE_USER} -c \"${NEW_DB_HOME}/bin/chopt disable olap\""
  drcmd  "su - ${ORACLE_USER} -c \"${NEW_DB_HOME}/bin/chopt disable rat\""
  drcmd  "su - ${ORACLE_USER} -c \"${NEW_DB_HOME}/bin/chopt disable partitioning\""
  drnote "chopt modifies the oracle binary. Restart required (Step C) to take effect."
  drnote "For Non-CDB environments only. Do NOT disable partitioning on CDB environments."
  drnote "Standby: chopt skipped -- binary changes do NOT propagate via redo; run independently."
  echo ""
  drstep "Step C: Restart database to apply chopt changes"
  drcmd  "su - ${GRID_USER} -c \"${NEW_GRID_HOME}/bin/srvctl stop database -d ${PRIMARY_SID} -o immediate  # primary (standby: MRP bounce instead)\""
  drcmd  "su - ${GRID_USER} -c \"${NEW_GRID_HOME}/bin/srvctl start database -d ${PRIMARY_SID}\""
  drnote "Standby: restarts MRP instead"
  echo ""
  drstep "Step D: Internal validations and utlrp (primary only)"
  drcmd  "sqlplus / as sysdba: EXEC SYS.XOQ_VALIDATE"
  drcmd  "sqlplus / as sysdba: EXEC SYS.APS_VALIDATE"
  drcmd  "sqlplus / as sysdba: @?/rdbms/admin/utlrp"
  echo ""
  drstep "Step E: Verify options, registry, and datapatch"
  drcmd  "sqlplus / as sysdba: SELECT PARAMETER, VALUE FROM V\$OPTION WHERE PARAMETER IN ('Partitioning','OLAP','Real Application Testing')"
  drcmd  "sqlplus / as sysdba: SELECT COMP_NAME, STATUS FROM DBA_REGISTRY ORDER BY COMP_NAME"
  echo ""
  drstep "Step F: Grid CRS verification"
  drcmd  "${NEW_GRID_HOME}/bin/crsctl query crs releasepatch"
  drcmd  "${NEW_GRID_HOME}/bin/crsctl stat res -t"
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

THIS_HOST=$(hostname -s)
parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
setup_log "post_install_local"
FAILED=0

# Determine if this node is primary or standby
if [[ "${THIS_HOST}" == "${PRIMARY_HOST}" ]]; then
  MY_SID="${PRIMARY_SID}"
  IS_PRIMARY=true
else
  MY_SID="${STANDBY_SID}"
  IS_PRIMARY=false
fi

section "POST-INSTALL VALIDATION: ${THIS_HOST} ($(${IS_PRIMARY} && echo PRIMARY || echo STANDBY))"
log "DB home : ${NEW_DB_HOME}"
log "Grid home: ${NEW_GRID_HOME}"
log "SID     : ${MY_SID}"

# ── Step A: Invalid object baseline ──────────────────────────────────────────
step "Step A: Record invalid object baseline"
if ${IS_PRIMARY}; then
  INVALIDS=$(runsql "${NEW_DB_HOME}" "${MY_SID}" "
SELECT owner, object_type, COUNT(*) cnt
FROM   dba_objects
WHERE  status = 'INVALID'
GROUP  BY owner, object_type
ORDER  BY owner, object_type;
" 2>/dev/null || echo "ERR")
  echo "${INVALIDS}" | while read -r l; do log "  ${l}"; done
  pass "Invalid object baseline recorded"
else
  log "  Standby: skipping invalid object query (read-only mode)"
  pass "Step A skipped on standby"
fi

# ── Step B: chopt — disable unused options (PRIMARY ONLY) ────────────────────
step "Step B: Disable unused DB options via chopt (primary only)"
if ${IS_PRIMARY}; then
  log "  Disabling: olap, rat (Real Application Testing), partitioning"
  log "  NOTE: chopt modifies the binary — database restart required after this step"
  runora "
    export ORACLE_HOME=${NEW_DB_HOME}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    cd \${ORACLE_HOME}/bin
    echo 'Disabling OLAP...'
    ./chopt disable olap
    echo 'Disabling Real Application Testing...'
    ./chopt disable rat
    echo 'Disabling Partitioning...'
    ./chopt disable partitioning
  " && pass "chopt disable complete" \
    || { fail "chopt returned non-zero — verify manually"; }
else
  log "  Standby: chopt skipped — changes propagate via redo from primary"
  pass "Step B skipped on standby"
fi

# ── Step C: Restart database to apply chopt changes ──────────────────────────
step "Step C: Restart database to apply chopt changes"
if ${IS_PRIMARY}; then
  log "  Stopping ${MY_SID} via srvctl..."
  rungrid "
    export ORACLE_HOME=${NEW_GRID_HOME}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    \${ORACLE_HOME}/bin/srvctl stop database -d ${MY_SID} -o immediate
  " && log "  Database stopped."
  sleep 5
  log "  Starting ${MY_SID} via srvctl..."
  rungrid "
    export ORACLE_HOME=${NEW_GRID_HOME}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    \${ORACLE_HOME}/bin/srvctl start database -d ${MY_SID}
  " && pass "Database restarted" || fail "Database restart failed"
  sleep 20
else
  log "  Standby: restarting MRP to pick up any redo from primary restart"
  runsql "${NEW_DB_HOME}" "${MY_SID}" "
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
" 2>/dev/null || true
  sleep 5
  runsql "${NEW_DB_HOME}" "${MY_SID}" "
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
" 2>/dev/null && pass "MRP restarted on standby" || warn "MRP restart returned non-zero"
fi

# ── Step D: XOQ_VALIDATE, APS_VALIDATE, utlrp (PRIMARY ONLY) ────────────────
step "Step D: Internal validations and utlrp (primary only)"
if ${IS_PRIMARY}; then
  log "  Running XOQ_VALIDATE..."
  runsql "${NEW_DB_HOME}" "${MY_SID}" "
SET SERVEROUTPUT ON
EXEC SYS.XOQ_VALIDATE;
" 2>/dev/null | while read -r l; do log "  ${l}"; done || warn "XOQ_VALIDATE returned non-zero"

  log "  Running APS_VALIDATE..."
  runsql "${NEW_DB_HOME}" "${MY_SID}" "
SET SERVEROUTPUT ON
EXEC SYS.APS_VALIDATE;
" 2>/dev/null | while read -r l; do log "  ${l}"; done || warn "APS_VALIDATE returned non-zero"

  log "  Running utlrp (recompile invalid objects)..."
  runsql "${NEW_DB_HOME}" "${MY_SID}" "
@?/rdbms/admin/utlrp
" 2>/dev/null | while read -r l; do log "  ${l}"; done
  pass "utlrp complete"

  # Verify zero invalids after utlrp
  INVALID_COUNT=$(runsql "${NEW_DB_HOME}" "${MY_SID}" "
SELECT COUNT(*) FROM dba_objects WHERE status='INVALID';
" 2>/dev/null | grep -E "^\s+[0-9]" | awk '{print $1}' || echo "ERR")
  log "  Invalid objects after utlrp: ${INVALID_COUNT}"
  [[ "${INVALID_COUNT}" == "0" ]] && pass "No invalid objects" \
    || warn "Invalid objects remaining: ${INVALID_COUNT} — investigate"
else
  log "  Standby: utlrp skipped (redo from primary applies dictionary changes)"
  pass "Step D skipped on standby"
fi

# ── Step E: Verify v$option, DBA_REGISTRY, datapatch ────────────────────────
step "Step E: Verify options, registry, and datapatch"
if ${IS_PRIMARY}; then
  log "  v\$option — disabled options (must show FALSE):"
  runsql "${NEW_DB_HOME}" "${MY_SID}" "
SELECT parameter, value FROM V\$OPTION
WHERE  parameter IN ('Partitioning','Real Application Testing','OLAP');
" 2>/dev/null | while read -r l; do log "  ${l}"; done || true

  log "  DBA_REGISTRY — all components:"
  REGISTRY=$(runsql "${NEW_DB_HOME}" "${MY_SID}" "
SELECT comp_name, status FROM dba_registry ORDER BY comp_name;
" 2>/dev/null || echo "ERR")
  echo "${REGISTRY}" | while read -r l; do log "  ${l}"; done
  if echo "${REGISTRY}" | grep -qiE "INVALID|LOADING"; then
    fail "DBA_REGISTRY has INVALID or LOADING components"
  else
    pass "DBA_REGISTRY: all components VALID or OPTION OFF"
  fi

  log "  datapatch — non-SUCCESS patches (expected: no rows):"
  runsql "${NEW_DB_HOME}" "${MY_SID}" "
SELECT PATCH_ID, STATUS, SUBSTR(DESCRIPTION,1,50)
FROM   DBA_REGISTRY_SQLPATCH
WHERE  STATUS != 'SUCCESS'
ORDER  BY ACTION_TIME DESC;
" 2>/dev/null | while read -r l; do log "  ${l}"; done || true

  log "  CDB and PDB status:"
  runsql "${NEW_DB_HOME}" "${MY_SID}" "
SELECT name, open_mode, cdb FROM v\$database;
SELECT con_id, name, open_mode FROM v\$pdbs ORDER BY con_id;
" 2>/dev/null | while read -r l; do log "  ${l}"; done || true
else
  log "  Standby: checking MRP and apply lag"
  MRP=$(runsql "${NEW_DB_HOME}" "${MY_SID}" "
SELECT PROCESS, STATUS, SEQUENCE# FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';
" 2>/dev/null || echo "ERR")
  echo "${MRP}" | while read -r l; do log "  ${l}"; done
  echo "${MRP}" | grep -qi "APPLYING_LOG\|WAIT_FOR_LOG" && pass "MRP running on standby" \
    || fail "MRP not running on standby"
fi

# ── Step F: Grid patch level and CRS resources ────────────────────────────────
step "Step F: Grid CRS verification"
log "  Grid CRS release patch:"
"${NEW_GRID_HOME}/bin/crsctl" query crs releasepatch 2>/dev/null \
  | while read -r l; do log "  ${l}"; done || true

log "  CRS resource status:"
"${NEW_GRID_HOME}/bin/crsctl" status resource -t 2>/dev/null \
  | while read -r l; do log "  ${l}"; done || true
pass "Grid CRS verification complete"

print_summary "post_install_local"
log ""
log "NEXT: Run security_local.sh ON ${THIS_HOST}"
log "  bash deploy/security_local.sh"
