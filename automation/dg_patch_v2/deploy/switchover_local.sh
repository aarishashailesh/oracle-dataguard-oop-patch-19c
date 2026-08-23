#!/usr/bin/env bash
# =============================================================================
# deploy/switchover_local.sh — Planned Switchover (lnx107)
# Run as: root  ON: lnx107
# ⚠ DOWNTIME PHASE — brief application interruption during role change.
#
# Method A (preferred): DG Broker — runs entirely on lnx107, fully automatic.
#   dgmgrl communicates with lnx113 over the Oracle DG network (not SSH).
#   No peer script needed if this path succeeds.
#
# Method B (fallback): Manual SQL — lnx107 side runs automatically here.
#   Script exits with instructions to run switchover_peer.sh ON lnx113.
#
# Result: lnx113 (CDBSTBY) = PRIMARY  |  lnx107 (CDBPRIM) = PHYSICAL STANDBY
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
  dry_run_header "switchover_local.sh"
  drnote "SYS password will be prompted (used for DG Broker cross-instance connection)"
  drnote "DOWNTIME STARTS at the switchover command below"
  echo ""
  drstep "Method A: Switchover via DG Broker"
  drcmd  "${OLD_DB_HOME}/bin/dgmgrl sys/<password>@${PRIMARY_DB_UNIQUE_NAME} 'switchover to ${STANDBY_DB_UNIQUE_NAME}'"
  drnote "Broker connects to ${STANDBY_HOST} via ${STANDBY_DB_UNIQUE_NAME}_DGMGRL service on port 1521"
  drnote "Result: ${STANDBY_HOST} opens as PRIMARY, ${PRIMARY_HOST} restarts as PHYSICAL STANDBY"
  drnote "DOWNTIME ENDS when ${STANDBY_HOST} opens READ WRITE"
  echo ""
  drstep "Verify ${PRIMARY_HOST} is PHYSICAL STANDBY"
  drcmd  "sqlplus / as sysdba: SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE  (ORACLE_SID=${PRIMARY_SID}, ORACLE_HOME=${OLD_DB_HOME})"
  drcmd  "${OLD_GRID_HOME}/bin/crsctl stat res | grep -E 'ora.(LISTENER|asm|cdbprim)'"
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
verify_node "${PRIMARY_HOST}"
setup_log "switchover_local"
require_dg_password
FAILED=0

section "SWITCHOVER: ${PRIMARY_HOST} → STANDBY  |  ${STANDBY_HOST} → PRIMARY"

SWITCHOVER_DONE=false

# ── Method A: DG Broker (fully automatic — no peer script needed) ─────────────
if [[ "${USE_DG_BROKER:-yes}" == "yes" ]]; then
  step "Method A: Switchover via DG Broker"
  log "  dgmgrl / 'switchover to ${STANDBY_DB_UNIQUE_NAME}'"
  log "  DG Broker coordinates with ${STANDBY_HOST} over DG network."

  SWOUT=$(rundgmgrl_auth "${OLD_DB_HOME}" "${PRIMARY_DB_UNIQUE_NAME}" \
    "switchover to ${STANDBY_DB_UNIQUE_NAME}" 2>&1 || echo "BROKER_FAILED")
  echo "${SWOUT}" | while read -r l; do log "  [dgmgrl] ${l}"; done

  if echo "${SWOUT}" | grep -qi "Switchover succeeded\|succeeded"; then
    pass "DG Broker switchover: SUCCESS — peer script not required"
    SWITCHOVER_DONE=true
  else
    warn "DG Broker switchover non-success — trying manual SQL."
  fi
fi

# ── Method B: Manual SQL ──────────────────────────────────────────────────────
if [[ "${SWITCHOVER_DONE}" != "true" ]]; then
  step "Method B: Manual SQL switchover --  side (automatic)"

  runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" "
ALTER DATABASE COMMIT TO SWITCHOVER TO PHYSICAL STANDBY WITH SESSION SHUTDOWN;
" || die "ALTER DATABASE COMMIT TO SWITCHOVER failed on ${PRIMARY_HOST}"

  runora "
    export ORACLE_HOME=${OLD_DB_HOME}
    export ORACLE_SID=${PRIMARY_SID}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    \${ORACLE_HOME}/bin/sqlplus -s / as sysdba <<'SQLEOF'
SHUTDOWN ABORT;
STARTUP MOUNT;
ALTER DATABASE OPEN READ ONLY;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
EXIT;
SQLEOF
" || die "Failed to start ${PRIMARY_SID} in READ ONLY WITH APPLY mode"
  pass "${PRIMARY_HOST} side: READ ONLY WITH APPLY (physical standby role)"

  log ""
  log "  ┌─────────────────────────────────────────────────────────────┐"
  log "  │  MANUAL ACTION REQUIRED ON ${STANDBY_HOST}                     │"
  log "  │  Run: bash deploy/switchover_peer.sh                        │"
  log "  │  Then return here and run: bash deploy/deploy_p_local.sh    │"
  log "  └─────────────────────────────────────────────────────────────┘"
  log ""

  # Start MRP on lnx107 (now standby) — safe to do before lnx113 opens
  runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" "
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
" 2>/dev/null && log "  MRP start issued on ${PRIMARY_HOST}." || true
fi

# ── Post-switchover local verify ──────────────────────────────────────────────
step "Verify ${PRIMARY_HOST} role post-switchover"
sleep 20
ROLE=$(runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" \
  "SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE;" \
  2>/dev/null || echo "ERR")
echo "${ROLE}" | while read -r l; do log "  ${l}"; done
echo "${ROLE}" | grep -qi "PHYSICAL STANDBY" \
  && pass "${PRIMARY_HOST}: PHYSICAL STANDBY ✓" \
  || fail "${PRIMARY_HOST} not showing PHYSICAL STANDBY"

step "CRS resources on ${PRIMARY_HOST}"
"${OLD_GRID_HOME}/bin/crsctl" stat res -t 2>/dev/null \
  | grep -E "ora\.(LISTENER|asm|cdbprim|net1)" \
  | while read -r l; do log "  ${l}"; done || true

print_summary "switchover_local"
log ""
if [[ "${SWITCHOVER_DONE}" == "true" ]]; then
  log "DG Broker handled switchover automatically."
  log "NEXT: Run deploy_p_local.sh ON ${PRIMARY_HOST} (this node)"
  log "  bash deploy/deploy_p_local.sh"
else
  log "Manual SQL path used."
  log "NEXT STEP 1: Run switchover_peer.sh ON ${STANDBY_HOST}"
  log "  bash deploy/switchover_peer.sh"
  log "NEXT STEP 2: Then run deploy_p_local.sh ON ${PRIMARY_HOST} (this node)"
  log "  bash deploy/deploy_p_local.sh"
fi
