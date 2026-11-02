#!/usr/bin/env bash
# =============================================================================
# deploy/aide_local.sh — Post-Patch AIDE Integrity Database Reset
# Run as: root  ON: lnx107 AND lnx113 (independently)
#
# Incorporates single-node phase7_aide.sh:
#   After patching, Oracle home binaries have changed. The AIDE reference
#   database must be regenerated so future integrity checks have a correct
#   baseline.
#
# BACKGROUND-SAFE: This takes 30-60 minutes. Run with systemd-run.
#   systemd-run --unit=dgpatch-aide-local --remain-after-exit --working-directory=<automation dir> bash deploy/aide_local.sh
#   tail -f /u01/app/oracle/patch_logs/<node>/aide_local.log
#
# Two scenarios:
#   First run  : aide --init   → creates initial aide.db.new.gz
#   After patch: aide --update → compares against aide.db.gz, produces new
# In both cases the new database is promoted to aide.db.gz as the master.
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
  dry_run_header "aide_local.sh"
  drstep "AIDE integrity database reset"
  drnote "Check if /var/lib/aide/aide.db.gz exists (determines init vs update mode)"
  drcmd  "aide --init  # (no existing db: full init, ~60 min)"
  drnote "OR: aide --update  (if existing db.gz found -- incremental update)"
  drcmd  "mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz"
  drnote "Baselines the new ${NEW_DB_HOME} and ${NEW_GRID_HOME} file states"
  drnote "Run after all other post-patch steps. Estimated time: 30-60 minutes."
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

THIS_HOST=$(hostname -s)
parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
setup_log "aide_local"
FAILED=0

section "AIDE INTEGRITY DATABASE RESET: ${THIS_HOST}"

# ── Verify AIDE is installed ──────────────────────────────────────────────────
if ! command -v aide &>/dev/null; then
  warn "aide command not found — skipping AIDE reset."
  log "  Install with: dnf install -y aide"
  log "  Then re-run: bash deploy/aide_local.sh"
  log "=== AIDE SKIPPED (not installed) ==="
  exit 0
fi

AIDE_NEW_DB="/var/lib/aide/aide.db.new.gz"
AIDE_MASTER_DB="/var/lib/aide/aide.db.gz"
AIDE_TIMEOUT=7200    # 2 hours max
INTERVAL=30

# ── Determine mode ────────────────────────────────────────────────────────────
if [[ -s "${AIDE_MASTER_DB}" ]]; then
  AIDE_CMD="--update"
  MASTER_SIZE=$(stat -c%s "${AIDE_MASTER_DB}")
  log "Mode: UPDATE — existing master database found (${MASTER_SIZE} bytes)"
  log "  Will compare current filesystem against ${AIDE_MASTER_DB}"
  rm -f "${AIDE_NEW_DB}"
  log "  Removed previous ${AIDE_NEW_DB} for clean update."
else
  AIDE_CMD="--init"
  log "Mode: INIT — no master database found."
  log "  Creating initial AIDE baseline from current filesystem."
fi

# ── Run AIDE in background ────────────────────────────────────────────────────
log "Running: aide ${AIDE_CMD}  (30-60 min expected)..."
log "Monitoring: tail -f ${STEP_LOG}"
aide "${AIDE_CMD}" &
AIDE_PID=$!
log "AIDE PID: ${AIDE_PID}"

# ── Wait for completion ────────────────────────────────────────────────────────
ELAPSED=0
while true; do
  if ! kill -0 "${AIDE_PID}" 2>/dev/null; then
    # Process ended — check output file
    if [[ -s "${AIDE_NEW_DB}" ]]; then
      FILE_SIZE=$(stat -c%s "${AIDE_NEW_DB}")
      log "AIDE ${AIDE_CMD} complete. Output: ${AIDE_NEW_DB} (${FILE_SIZE} bytes)"
      break
    else
      fail "AIDE process ended but ${AIDE_NEW_DB} is empty or missing."
      log "  Check /var/log/aide/aide.log for details."
      exit 1
    fi
  fi
  ELAPSED=$(( ELAPSED + INTERVAL ))
  if (( ELAPSED >= AIDE_TIMEOUT )); then
    kill "${AIDE_PID}" 2>/dev/null || true
    fail "AIDE timed out after ${AIDE_TIMEOUT}s."
    exit 1
  fi
  # Log progress every 5 minutes
  if (( ELAPSED % 300 == 0 )); then
    log "  AIDE running... ${ELAPSED}s elapsed ($(( ELAPSED / 60 )) min)"
  fi
  sleep "${INTERVAL}"
done

# ── Promote new database to master ────────────────────────────────────────────
step "Promote new AIDE database to master"
cp -f "${AIDE_NEW_DB}" "${AIDE_MASTER_DB}"
chmod 600 "${AIDE_MASTER_DB}"
MASTER_SIZE=$(stat -c%s "${AIDE_MASTER_DB}")
log "  Master: ${AIDE_MASTER_DB} (${MASTER_SIZE} bytes)"
log "  Future aide --check runs will use this as the new baseline."
pass "AIDE master database updated"

print_summary "aide_local"
log ""
log "AIDE reset complete on ${THIS_HOST}."
log "Run on the other node if not already done:"
log "  systemd-run --unit=dgpatch-aide-local --remain-after-exit --working-directory=<automation dir> bash deploy/aide_local.sh"
