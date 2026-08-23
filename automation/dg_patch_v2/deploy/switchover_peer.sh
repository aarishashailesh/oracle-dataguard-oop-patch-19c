#!/usr/bin/env bash
# =============================================================================
# deploy/switchover_peer.sh — Complete Switchover on lnx113 (Manual Fallback)
# Run as: root  ON: lnx113
#
# Only needed if switchover_local.sh used Method B (DG Broker unavailable).
# If DG Broker succeeded on lnx107, skip this script entirely.
#
# Completes the switchover: lnx113 (CDBSTBY) → PRIMARY
# Then starts MRP on lnx107 side via this script (no SSH needed —
# lnx107 already started MRP in switchover_local.sh).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../patch.conf"
source "${SCRIPT_DIR}/../lib_common.sh"

verify_node "${STANDBY_HOST}"
setup_log "switchover_peer"
FAILED=0

section "SWITCHOVER PEER: Complete switchover on ${STANDBY_HOST}"

step "Complete switchover to PRIMARY role"
runora "
  export ORACLE_HOME=${NEW_DB_HOME}
  export ORACLE_SID=${STANDBY_SID}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  \${ORACLE_HOME}/bin/sqlplus -s / as sysdba <<'SQLEOF'
ALTER DATABASE COMMIT TO SWITCHOVER TO PRIMARY WITH SESSION SHUTDOWN;
ALTER DATABASE OPEN;
EXIT;
SQLEOF
" || die "Switchover to PRIMARY failed on ${STANDBY_HOST}"
pass "${STANDBY_DB_UNIQUE_NAME} opened as PRIMARY"

step "Verify ${STANDBY_HOST} is PRIMARY"
sleep 10
ROLE=$(runsql "${NEW_DB_HOME}" "${STANDBY_SID}" \
  "SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE;" \
  2>/dev/null || echo "ERR")
echo "${ROLE}" | while read -r l; do log "  ${l}"; done
echo "${ROLE}" | grep -qi "PRIMARY" \
  && pass "${STANDBY_HOST}: PRIMARY ✓" \
  || fail "${STANDBY_HOST} not in PRIMARY role"

step "Trigger archive log switch from new primary"
runsql "${NEW_DB_HOME}" "${STANDBY_SID}" \
  "ALTER SYSTEM ARCHIVE LOG CURRENT;" 2>/dev/null \
  && pass "Archive log switch issued" || warn "Archive log switch returned non-zero"

step "CRS resources on ${STANDBY_HOST}"
"${NEW_GRID_HOME}/bin/crsctl" stat res -t 2>/dev/null \
  | grep -E "ora\.(LISTENER|asm|cdbstby|net1)" \
  | while read -r l; do log "  ${l}"; done || true

print_summary "switchover_peer"
log ""
log "NEXT: Return to ${PRIMARY_HOST} and run deploy_p_local.sh"
log "  bash deploy/deploy_p_local.sh"
