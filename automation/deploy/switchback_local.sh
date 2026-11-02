#!/usr/bin/env bash
# =============================================================================
# deploy/switchback_local.sh — Planned Switchback: Restore Original Roles
# Run as: root  ON: lnx107
#
# Restores: lnx107 (CDBPRIM) = PRIMARY  |  lnx113 (CDBSTBY) = PHYSICAL STANDBY
#
# Method A (preferred): DG Broker — runs entirely on lnx107, fully automatic.
# Method B (fallback): Manual SQL — requires switchback_peer.sh on lnx113.
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
  dry_run_header "switchback_local.sh"
  drnote "SYS password will be prompted (reused from session if already entered)"
  drnote "DOWNTIME for brief role transition during switchback"
  echo ""
  drstep "Pre-switchback: apply lag check"
  drcmd  "sqlplus / as sysdba: SELECT VALUE FROM V\$DATAGUARD_STATS WHERE NAME='apply lag'  (ORACLE_SID=${PRIMARY_SID}, ORACLE_HOME=${NEW_DB_HOME})"
  drnote "If lag non-zero, waits 30s before proceeding"
  echo ""
  drstep "Method A: Switchback via DG Broker"
  drcmd  "${NEW_DB_HOME}/bin/dgmgrl sys/<password>@${PRIMARY_DB_UNIQUE_NAME} 'switchover to ${PRIMARY_DB_UNIQUE_NAME}'"
  drnote "Result: ${PRIMARY_HOST} opens READ WRITE as PRIMARY, ${STANDBY_HOST} restarts as PHYSICAL STANDBY"
  drnote "DOWNTIME ENDS when ${PRIMARY_HOST} opens READ WRITE"
  echo ""
  drstep "Verify ${PRIMARY_HOST} is back to PRIMARY"
  drcmd  "sqlplus / as sysdba: SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE  (ORACLE_SID=${PRIMARY_SID})"
  echo ""
  drstep "Archive log switch"
  drcmd  "sqlplus / as sysdba: ALTER SYSTEM ARCHIVE LOG CURRENT  (ORACLE_SID=${PRIMARY_SID})"
  drcmd  "${NEW_DB_HOME}/bin/dgmgrl / 'show configuration'"
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
verify_node "${PRIMARY_HOST}"
setup_log "switchback_local"
require_dg_password
FAILED=0

section "SWITCHBACK: Restore Original Roles"
log "Target: ${PRIMARY_HOST} (${PRIMARY_DB_UNIQUE_NAME}) = PRIMARY"
log "Target: ${STANDBY_HOST} (${STANDBY_DB_UNIQUE_NAME}) = PHYSICAL STANDBY"

step "Pre-switchback: apply lag check"
ALAG=$(get_dg_lag "${NEW_DB_HOME}" "${PRIMARY_SID}" "apply lag")
log "  Apply lag on ${PRIMARY_HOST}: ${ALAG}"
if [[ "${ALAG}" != "+00 00:00:00" && -n "${ALAG}" ]]; then
  log "  Apply lag non-zero — waiting 30s..."
  sleep 30
fi

SWITCHBACK_DONE=false

step "Method A: Switchback via DG Broker"
SBOUT=$(rundgmgrl_auth "${NEW_DB_HOME}" "${PRIMARY_DB_UNIQUE_NAME}" \
  "switchover to ${PRIMARY_DB_UNIQUE_NAME}" 2>&1 || echo "BROKER_FAILED")
echo "${SBOUT}" | while read -r l; do log "  [dgmgrl] ${l}"; done

if echo "${SBOUT}" | grep -qi "Switchover succeeded\|succeeded"; then
  pass "DG Broker switchback: SUCCESS — peer script not required"
  SWITCHBACK_DONE=true
else
  warn "DG Broker non-success — using manual SQL."
fi

if [[ "${SWITCHBACK_DONE}" != "true" ]]; then
  log ""
  log "  ┌─────────────────────────────────────────────────────────────┐"
  log "  │  MANUAL ACTION: Run switchback_peer.sh ON ${STANDBY_HOST}         │"
  log "  │    bash deploy/switchback_peer.sh                          │"
  log "  │  Then return here — this node completes automatically.     │"
  log "  └─────────────────────────────────────────────────────────────┘"
  log ""
  log "  Waiting for ${STANDBY_HOST} to initiate switchover (run switchback_peer.sh)..."
  log "  Then completing to PRIMARY on ${PRIMARY_HOST}..."

  runora "
    export ORACLE_HOME=${NEW_DB_HOME}
    export ORACLE_SID=${PRIMARY_SID}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    \${ORACLE_HOME}/bin/sqlplus -s / as sysdba <<'SQLEOF'
ALTER DATABASE COMMIT TO SWITCHOVER TO PRIMARY WITH SESSION SHUTDOWN;
ALTER DATABASE OPEN;
EXIT;
SQLEOF
" || die "Switchover to PRIMARY on ${PRIMARY_HOST} failed"
  pass "${PRIMARY_HOST} opened as PRIMARY"
fi

step "Post-switchback verification on ${PRIMARY_HOST}"
sleep 20
ROLE=$(runsql "${NEW_DB_HOME}" "${PRIMARY_SID}" \
  "SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE;" \
  2>/dev/null || echo "ERR")
echo "${ROLE}" | while read -r l; do log "  ${l}"; done
echo "${ROLE}" | grep -qi "PRIMARY" \
  && pass "${PRIMARY_HOST}: PRIMARY ✓ (original role restored)" \
  || fail "${PRIMARY_HOST} not in PRIMARY role"

step "Archive log switch -- verify redo transport to ${STANDBY_HOST} restored"
runsql "${NEW_DB_HOME}" "${PRIMARY_SID}" \
  "ALTER SYSTEM ARCHIVE LOG CURRENT;" 2>/dev/null \
  && pass "Archive log switch issued" || true
sleep 10
DG_STATS=$(runsql "${NEW_DB_HOME}" "${PRIMARY_SID}" "
SELECT NAME, VALUE FROM V\$DATAGUARD_STATS WHERE NAME IN ('transport lag','apply lag');
" 2>/dev/null || echo "ERR")
echo "${DG_STATS}" | while read -r l; do log "  ${l}"; done

step "DG Broker show configuration"
DG=$(rundgmgrl "${NEW_DB_HOME}" "show configuration")
echo "${DG}" | while read -r l; do log "  ${l}"; done

print_summary "switchback_local"
log ""
if [[ "${SWITCHBACK_DONE}" != "true" ]]; then
  log "Manual SQL path: run switchback_peer.sh ON ${STANDBY_HOST} if not already done."
fi
log "NEXT: Run validate_local.sh ON ${PRIMARY_HOST} (this node)"
log "  bash deploy/validate_local.sh"
