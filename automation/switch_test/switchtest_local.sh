#!/usr/bin/env bash
# =============================================================================
# switch_test/switchtest_local.sh — Test Switchover + Switchback (lnx107)
# Run as: root  ON: lnx107
#
# Changes from v1:
#   - Lag check: added -n guard -- V$DATAGUARD_STATS returns no rows on primary;
#     empty value is treated as zero lag (correct), not as non-zero (bug)
#   - Switchover/switchback: use rundgmgrl_auth (sys/password) instead of
#     rundgmgrl (/). DG Broker requires SYSDBA credentials to connect to the
#     remote instance during switchover. OS auth (/) is read-only only.
#   - Added require_dg_password call -- prompts once, reused for both operations
#   - Archive log switch: added 30s delay after switchover before issuing the
#     switch, allowing the new primary time to fully open before accepting DDL
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
  dry_run_header "switchtest_local.sh"
  drnote "SYS password will be prompted once and reused for both switchover and switchback"
  echo ""
  drstep "Pre-test: Verify DG health"
  drcmd  "sqlplus / as sysdba: SELECT VALUE FROM V\$DATAGUARD_STATS  (ORACLE_SID=${PRIMARY_SID})"
  drcmd  "sqlplus / as sysdba: SELECT COUNT(*) FROM V\$ARCHIVE_GAP"
  drcmd  "${OLD_DB_HOME}/bin/dgmgrl / 'show configuration'"
  echo ""
  drstep "SWITCHOVER: ${PRIMARY_HOST} -> STANDBY | ${STANDBY_HOST} -> PRIMARY"
  drcmd  "${OLD_DB_HOME}/bin/dgmgrl sys/<password>@${PRIMARY_DB_UNIQUE_NAME} 'switchover to ${STANDBY_DB_UNIQUE_NAME}'"
  drnote "DG Broker connects to ${STANDBY_HOST} over DG network using password file"
  drnote "New primary opens: ${STANDBY_HOST} (ORACLE_HOME=${NEW_DB_HOME})"
  drnote "Old primary restarts as standby: ${PRIMARY_HOST} MOUNTED -> READ ONLY WITH APPLY"
  echo ""
  drstep "Verify ${PRIMARY_HOST} is PHYSICAL STANDBY"
  drcmd  "sqlplus / as sysdba: SELECT OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE  (ORACLE_SID=${PRIMARY_SID})"
  drcmd  "sqlplus / as sysdba: SELECT PROCESS, STATUS FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%'"
  echo ""
  drstep "Archive log switch (wait 30s for new primary to open)"
  drcmd  "sleep 30"
  drcmd  "sqlplus / as sysdba: ALTER SYSTEM ARCHIVE LOG CURRENT  (on ${PRIMARY_SID} as standby)"
  echo ""
  drstep "SWITCHBACK: ${PRIMARY_HOST} -> PRIMARY | ${STANDBY_HOST} -> STANDBY"
  drcmd  "${OLD_DB_HOME}/bin/dgmgrl sys/<password>@${PRIMARY_DB_UNIQUE_NAME} 'switchover to ${PRIMARY_DB_UNIQUE_NAME}'"
  echo ""
  drstep "Verify ${PRIMARY_HOST} is back to PRIMARY"
  drcmd  "sqlplus / as sysdba: SELECT OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE  (ORACLE_SID=${PRIMARY_SID})"
  drcmd  "${OLD_DB_HOME}/bin/dgmgrl / 'show configuration'"
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
verify_node "${PRIMARY_HOST}"
setup_log "switchtest_local"
require_dg_password
FAILED=0

section "SWITCH TEST: Switchover + Switchback (${PRIMARY_HOST})"
log "This test performs a planned switchover then immediately switchbacks."
log "Net result: original roles are restored."

# ---------------------------------------------------------------------------
step "Pre-test: Verify DG health before switchover"
TLAG=$(get_dg_lag "${OLD_DB_HOME}" "${PRIMARY_SID}" "transport lag")
ALAG=$(get_dg_lag "${OLD_DB_HOME}" "${PRIMARY_SID}" "apply lag")
log "  Transport lag: '${TLAG}'  Apply lag: '${ALAG}'"
# V$DATAGUARD_STATS returns no rows on primary -- empty means zero lag (correct).
# Only fail if a value is explicitly present and non-zero.
if [[ -n "${TLAG}" && "${TLAG}" != "+00 00:00:00" ]] || \
   [[ -n "${ALAG}" && "${ALAG}" != "+00 00:00:00" ]]; then
  fail "DG lag non-zero before switchover -- wait for sync before proceeding"
  exit 1
fi
pass "DG lag = 0 (confirmed via Broker below)"

GAP=$(runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" \
  "SELECT COUNT(*) FROM V\$ARCHIVE_GAP;" \
  2>/dev/null | grep -E "^\s+[0-9]" | awk '{print $1}' || echo "ERR")
[[ "${GAP}" == "0" ]] && pass "No archive gap" \
  || { fail "Archive gap present: ${GAP}"; exit 1; }

DG_PRE=$(rundgmgrl "${OLD_DB_HOME}" "show configuration")
log "Pre-switchover configuration:"
echo "${DG_PRE}" | while read -r l; do log "  ${l}"; done
echo "${DG_PRE}" | grep -qi "SUCCESS" && pass "DG Broker pre-state: SUCCESS" \
  || { fail "DG Broker not SUCCESS before switchover"; exit 1; }

# ---------------------------------------------------------------------------
step "SWITCHOVER: ${PRIMARY_HOST} -> STANDBY  |  ${STANDBY_HOST} -> PRIMARY"
log "  Using DG Broker with sys credentials (required for cross-instance connection)..."

SWOUT=$(rundgmgrl_auth "${OLD_DB_HOME}" "${PRIMARY_DB_UNIQUE_NAME}" \
  "switchover to ${STANDBY_DB_UNIQUE_NAME}" 2>&1 || echo "BROKER_FAILED")
echo "${SWOUT}" | while read -r l; do log "  [dgmgrl] ${l}"; done

if echo "${SWOUT}" | grep -qi "succeeded"; then
  pass "Switchover via DG Broker: SUCCESS"
else
  fail "DG Broker switchover failed -- check alert log"
  log "  Alert log: $(find "${ADR_BASE}/rdbms" -name 'alert_*.log' | head -1)"
  exit 1
fi

# ---------------------------------------------------------------------------
step "Verify ${PRIMARY_HOST} is now PHYSICAL STANDBY"
sleep 20
ROLE=$(runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" \
  "SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE;" \
  2>/dev/null || echo "ERR")
echo "${ROLE}" | while read -r l; do log "  ${l}"; done
echo "${ROLE}" | grep -qi "PHYSICAL STANDBY" \
  && pass "${PRIMARY_HOST}: PHYSICAL STANDBY OK" \
  || fail "${PRIMARY_HOST} not in PHYSICAL STANDBY role"

MRP=$(runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" \
  "SELECT COUNT(*) FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';" \
  2>/dev/null | grep -E "^\s+[0-9]" | awk '{print $1}' || echo "0")
log "  MRP processes on ${PRIMARY_HOST}: ${MRP}"
[[ "${MRP}" -ge 1 ]] && pass "MRP running on ${PRIMARY_HOST} (now standby)" \
  || warn "MRP not yet running -- may take a moment"

# Archive log switch -- delay to allow new primary (lnx113) to fully open
log "  Waiting 30s for new primary to fully open before archive log switch..."
sleep 30
log "  Issuing archive log switch on new primary (${STANDBY_HOST}) via SQL*Plus..."
runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" \
  "ALTER SYSTEM ARCHIVE LOG CURRENT;" 2>/dev/null \
  && log "  Archive log switch issued." \
  || warn "Archive log switch returned non-zero (new primary may not be fully open yet)"

# ---------------------------------------------------------------------------
step "SWITCHBACK: ${PRIMARY_HOST} -> PRIMARY  |  ${STANDBY_HOST} -> STANDBY"
log "  Switching back to original roles via DG Broker..."

SBOUT=$(rundgmgrl_auth "${OLD_DB_HOME}" "${PRIMARY_DB_UNIQUE_NAME}" \
  "switchover to ${PRIMARY_DB_UNIQUE_NAME}" 2>&1 || echo "BROKER_FAILED")
echo "${SBOUT}" | while read -r l; do log "  [dgmgrl] ${l}"; done

if echo "${SBOUT}" | grep -qi "succeeded"; then
  pass "Switchback via DG Broker: SUCCESS"
else
  fail "DG Broker switchback failed -- check alert log and restore manually"
  exit 1
fi

# ---------------------------------------------------------------------------
step "Verify ${PRIMARY_HOST} is back to PRIMARY"
sleep 20
ROLE=$(runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" \
  "SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE;" \
  2>/dev/null || echo "ERR")
echo "${ROLE}" | while read -r l; do log "  ${l}"; done
echo "${ROLE}" | grep -qi "PRIMARY" \
  && pass "${PRIMARY_HOST}: PRIMARY OK (original role restored)" \
  || fail "${PRIMARY_HOST} not back in PRIMARY role"

step "Final DG Broker show configuration"
DG_POST=$(rundgmgrl "${OLD_DB_HOME}" "show configuration")
echo "${DG_POST}" | while read -r l; do log "  ${l}"; done
echo "${DG_POST}" | grep -qi "SUCCESS" \
  && pass "DG Broker post-state: SUCCESS" \
  || fail "DG Broker not in SUCCESS after switchback"

step "Final lag check"
TLAG2=$(get_dg_lag "${OLD_DB_HOME}" "${PRIMARY_SID}" "transport lag")
ALAG2=$(get_dg_lag "${OLD_DB_HOME}" "${PRIMARY_SID}" "apply lag")
log "  Transport lag: '${TLAG2}'  Apply lag: '${ALAG2}'"

print_summary "switchtest_local"
log ""
log "NEXT: Run switchtest_peer.sh ON ${STANDBY_HOST} to confirm ${STANDBY_HOST} saw roles correctly."
log "  bash switch_test/switchtest_peer.sh"
