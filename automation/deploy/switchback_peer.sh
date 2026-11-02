#!/usr/bin/env bash
# =============================================================================
# deploy/switchback_peer.sh — Complete Switchback on lnx113 (Manual Fallback)
# Run as: root  ON: lnx113
# Only needed if DG Broker was unavailable in switchback_local.sh.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../patch.conf"
source "${SCRIPT_DIR}/../lib_common.sh"

verify_node "${STANDBY_HOST}"
setup_log "switchback_peer"
FAILED=0

section "SWITCHBACK PEER: ${STANDBY_HOST} → PHYSICAL STANDBY"

step "Initiate switchover on ${STANDBY_HOST} (current primary)"
runora "
  export ORACLE_HOME=${NEW_DB_HOME}
  export ORACLE_SID=${STANDBY_SID}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  \${ORACLE_HOME}/bin/sqlplus -s / as sysdba <<'SQLEOF'
ALTER DATABASE COMMIT TO SWITCHOVER TO PHYSICAL STANDBY WITH SESSION SHUTDOWN;
SHUTDOWN ABORT;
STARTUP MOUNT;
EXIT;
SQLEOF
" && pass "${STANDBY_HOST} in MOUNT mode (physical standby)" \
  || die "Switchover initiation failed on ${STANDBY_HOST}"

log ""
log "  ${STANDBY_HOST} is now in MOUNT mode."
log "  Return to ${PRIMARY_HOST} — switchback_local.sh will complete automatically."
log "  Then come back here and run: bash deploy/validate_peer.sh"

print_summary "switchback_peer"
