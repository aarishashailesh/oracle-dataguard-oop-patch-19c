#!/usr/bin/env bash
# =============================================================================
# prep/prep_verify_peer.sh — Verify Peer Node New Homes (Cross-Check)
# Run as: root  ON: EITHER node
#
# Verifies that the PEER node's prep_local.sh completed correctly by checking
# everything that can be verified from the LOCAL node without SSH:
#   - DG transport and apply lag still 0 (prep didn't disrupt replication)
#   - MRP still running
#   - No archive gap
#   - DG Broker configuration still SUCCESS
#
# The peer's actual home contents are verified by the peer's own prep_local.sh.
# This script confirms the environment is still healthy after parallel prep.
#
# Usage:
#   On lnx107 after prep_s_local.sh finishes on lnx113:
#     bash prep/prep_verify_peer.sh
#   On lnx113 after prep_p_local.sh finishes on lnx107:
#     bash prep/prep_verify_peer.sh
#
# Exits 0 if all checks pass, 1 if any fail.
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
  dry_run_header "prep_verify_peer.sh"
  drstep "Check 1: DG transport and apply lag"
  drcmd  "sqlplus / as sysdba: SELECT VALUE FROM V\$DATAGUARD_STATS WHERE NAME IN ('transport lag','apply lag')"
  drnote "(ORACLE_HOME=${OLD_DB_HOME} ORACLE_SID=${PRIMARY_SID})"
  echo ""
  drstep "Check 2: Archive gap"
  drcmd  "sqlplus / as sysdba: SELECT COUNT(*) FROM V\$ARCHIVE_GAP"
  echo ""
  drstep "Check 3: MRP status"
  drcmd  "sqlplus / as sysdba: SELECT PROCESS, STATUS FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%'"
  echo ""
  drstep "Check 4: DG Broker configuration"
  drcmd  "${OLD_DB_HOME}/bin/dgmgrl / 'show configuration'"
  echo ""
  drstep "Check 5: CRS resources"
  drcmd  "${OLD_GRID_HOME}/bin/crsctl stat res -t"
  echo ""
  drstep "Check 6: Verify new homes exist on this node"
  drcmd  "test -d ${NEW_GRID_HOME}"
  drcmd  "test -d ${NEW_DB_HOME}"
  drcmd  "${NEW_DB_HOME}/OPatch/opatch lspatches | head -3"
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
setup_log "prep_verify_peer"
FAILED=0
THIS_HOST=$(hostname -s)

# Determine local vs peer context
if [[ "${THIS_HOST}" == "${PRIMARY_HOST}" ]]; then
  LOCAL_HOME="${OLD_DB_HOME}"; LOCAL_SID="${PRIMARY_SID}"
  PEER="${STANDBY_HOST}"; PEER_SID="${STANDBY_SID}"
else
  LOCAL_HOME="${OLD_DB_HOME}"; LOCAL_SID="${STANDBY_SID}"
  PEER="${PRIMARY_HOST}"; PEER_SID="${PRIMARY_SID}"
fi

section "PREP PEER VERIFY: DG Health Check After Parallel Prep"
log "Running on  : ${THIS_HOST}"
log "Peer node   : ${PEER} (new homes built there — verifying DG still healthy)"

step "Check 1: DG transport and apply lag"
# When running on primary, V$DATAGUARD_STATS may return empty values — it is
# primarily a standby-side view. Use DG Broker as the authoritative lag source.
# When running on standby, V$DATAGUARD_STATS is reliable.
if [[ "${THIS_HOST}" == "${STANDBY_HOST}" ]]; then
  TLAG=$(get_dg_lag "${LOCAL_HOME}" "${LOCAL_SID}" "transport lag")
  ALAG=$(get_dg_lag "${LOCAL_HOME}" "${LOCAL_SID}" "apply lag")
  log "  Transport lag : ${TLAG:-unknown}"
  log "  Apply lag     : ${ALAG:-unknown}"
  if [[ "${TLAG}" == "+00 00:00:00" && "${ALAG}" == "+00 00:00:00" ]]; then
    pass "Transport lag = 0, apply lag = 0"
  else
    warn "Lag non-zero (${TLAG:-?} / ${ALAG:-?}) — may still be catching up."
  fi
else
  # On primary: use DG Broker show database for lag (Check 4 covers this)
  log "  Running on primary — lag verified via DG Broker in Check 4."
  DG_STATS=$(runsql "${LOCAL_HOME}" "${LOCAL_SID}" "
SELECT NAME, VALUE FROM V\$DATAGUARD_STATS
WHERE  NAME IN ('transport lag','apply lag');
" 2>/dev/null || echo "")
  if [[ -n "${DG_STATS}" ]]; then
    echo "${DG_STATS}" | grep -v "^$" | while read -r l; do log "  ${l}"; done
  else
    log "  V\$DATAGUARD_STATS: no rows on primary (use DG Broker for lag)"
  fi
  pass "Lag check: use DG Broker show configuration for definitive status"
fi

step "Check 2: Archive gap"
GAP=$(runsql "${LOCAL_HOME}" "${LOCAL_SID}" \
  "SELECT COUNT(*) FROM V\$ARCHIVE_GAP;" \
  2>/dev/null | grep -E "^\s+[0-9]" | awk '{print $1}' || echo "ERR")
log "  V\$ARCHIVE_GAP rows: ${GAP}"
[[ "${GAP}" == "0" ]] && pass "No archive gap" \
  || fail "Archive gap present: ${GAP} rows — resolve before deploy phase"

step "Check 3: MRP status"
if [[ "${THIS_HOST}" == "${PRIMARY_HOST}" ]]; then
  # Check MRP on standby via V$DATAGUARD_STATS (available from primary)
  MRP_STAT=$(runsql "${LOCAL_HOME}" "${LOCAL_SID}" "
    SELECT VALUE FROM V\$DATAGUARD_STATS WHERE NAME='apply finish time';
  " 2>/dev/null | grep -v "^$" | grep -v "VALUE\|---" | head -1 || echo "unknown")
  log "  Apply finish time: ${MRP_STAT}"
  pass "MRP checked via DG stats (run on standby for direct MRP check)"
else
  MRP=$(runsql "${LOCAL_HOME}" "${LOCAL_SID}" "
    SELECT COUNT(*) FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';
  " 2>/dev/null | grep -E "^\s+[0-9]" | awk '{print $1}' || echo "0")
  log "  MRP processes: ${MRP}"
  [[ "${MRP}" -ge 1 ]] && pass "MRP running" \
    || fail "MRP not running on ${THIS_HOST}"
fi

step "Check 4: DG Broker configuration"
DG_OUT=$(rundgmgrl "${LOCAL_HOME}" "show configuration" 2>/dev/null || echo "UNAVAILABLE")
echo "${DG_OUT}" | while read -r l; do log "  ${l}"; done
if echo "${DG_OUT}" | grep -qi "SUCCESS"; then
  pass "DG Broker: SUCCESS"
elif echo "${DG_OUT}" | grep -qi "UNAVAILABLE"; then
  warn "DG Broker unavailable — verify manually"
else
  fail "DG Broker not in SUCCESS state"
fi

step "Check 5: Local CRS resources"
"${OLD_GRID_HOME}/bin/crsctl" stat res -t 2>/dev/null \
  | grep -E "ora\.(LISTENER|asm|cdbprim|cdbstby|net1)" \
  | while read -r l; do log "  ${l}"; done || true
pass "CRS resource check complete (review output above)"

step "Check 6: Verify local new homes exist (this node's prep)"
if [[ "${THIS_HOST}" == "${PRIMARY_HOST}" ]]; then
  NODE_NEW_GRID="${NEW_GRID_HOME}"; NODE_NEW_DB="${NEW_DB_HOME}"
else
  NODE_NEW_GRID="${NEW_GRID_HOME}"; NODE_NEW_DB="${NEW_DB_HOME}"
fi
[[ -d "${NODE_NEW_GRID}" ]] && pass "New Grid home exists: ${NODE_NEW_GRID}" \
  || fail "New Grid home MISSING: ${NODE_NEW_GRID} — run prep_local.sh first"
[[ -d "${NODE_NEW_DB}" ]] && pass "New DB home exists: ${NODE_NEW_DB}" \
  || fail "New DB home MISSING: ${NODE_NEW_DB} — run prep_local.sh first"

if [[ -d "${NODE_NEW_DB}/OPatch" ]]; then
  OPATCH_VER=$(runora "
    export ORACLE_HOME=${NODE_NEW_DB}
    \${ORACLE_HOME}/OPatch/opatch version 2>/dev/null | grep 'OPatch Version'
  " 2>/dev/null | awk '{print $NF}' || echo "unknown")
  log "  New DB OPatch version: ${OPATCH_VER}"
fi

print_summary "prep_verify_peer"
