#!/usr/bin/env bash
# =============================================================================
# dg_patch_runbook.sh — Master DG Rolling Patch Runbook
# Run as: root  ON: lnx107 (primary) — drives the full patch cycle
#
# This script is the OPERATOR GUIDE and EXECUTOR for the complete patch cycle.
# It prints each step clearly, runs scripts on the correct node, and for peer
# steps prints exact instructions for the operator to run on the other node.
#
# USAGE:
#   ./dg_patch_runbook.sh [--from-phase <n>] [--phase <n>] [--dry-run]
#
# OPTIONS:
#   --phase <n>      Run only this phase (1-16)
#   --from-phase <n> Resume from this phase
#   --dry-run        Print all steps without executing
#
# FULL PHASE MAP:
#  ── PREP (pre-downtime, no outage, run in background) ──────────────────────
#   1   prep/prep_s_local.sh        ON lnx113  Build+patch new homes (standby)
#   2   prep/prep_p_local.sh        ON lnx107  Build+patch new homes (primary)
#   3   prep/prep_verify_peer.sh    ON either  Verify DG still healthy
#
#  ── SWITCH TEST (optional, proves DG switchover works) ─────────────────────
#   4   switch_test/switchtest_local.sh  ON lnx107  Switchover+switchback test
#   5   switch_test/switchtest_peer.sh   ON lnx113  Confirm roles after test
#
#  ── DEPLOY (downtime window — AutoUpgrade, switchover, datapatch) ──────────
#   6   deploy/deploy_s_local.sh    ON lnx113  AutoUpgrade deploy on standby
#   7   deploy/deploy_s_peer.sh     ON lnx107  Pre-switchover checks
#   8   deploy/switchover_local.sh  ON lnx107  Planned switchover
#   9   deploy/switchover_peer.sh   ON lnx113  Complete switchover (if manual)
#  10   deploy/deploy_p_local.sh    ON lnx107  AutoUpgrade deploy (now standby)
#  11   deploy/deploy_p_peer.sh     ON lnx113  Archive log switch + verify
#  12   deploy/datapatch_peer.sh    ON lnx113  datapatch on current primary
#  13   deploy/datapatch_local.sh   ON lnx107  Verify redo applied
#  14   deploy/switchback_local.sh  ON lnx107  Restore original roles
#  15   deploy/switchback_peer.sh   ON lnx113  Complete switchback (if manual)
#  16   deploy/validate_local.sh    ON lnx107  Full validation
#  17   deploy/validate_peer.sh     ON lnx113  Standby validation
#
#  ── POST-PATCH (both nodes independently, no outage) ───────────────────────
#  18   deploy/post_install_local.sh  ON lnx107  chopt, utlrp, registry
#  18   deploy/post_install_local.sh  ON lnx113  MRP verify (standby)
#  19   deploy/security_local.sh      ON lnx107  FIPS, extproc
#  19   deploy/security_local.sh      ON lnx113  FIPS, extproc
#  20   deploy/aide_local.sh          ON lnx107  AIDE reset (background, ~60min)
#  20   deploy/aide_local.sh          ON lnx113  AIDE reset (background, ~60min)
#
#  ── CLEANUP (opt-in, >=24h after patching) ─────────────────────────────────
#  21   deploy/cleanup_local.sh       ON lnx107  Deinstall old homes
#  21   deploy/cleanup_local.sh       ON lnx113  Deinstall old homes
# =============================================================================
set -euo pipefail
umask 0022

[[ "${EUID}" -ne 0 ]] && { echo "ERROR: Must run as root."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/patch.conf"
source "${SCRIPT_DIR}/lib_common.sh"

verify_node "${PRIMARY_HOST}"
setup_log "dg_patch_runbook"

# ── Arg parsing ───────────────────────────────────────────────────────────────
START_PHASE=1
END_PHASE=17      # Default: through final validation; post-patch is opt-in
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)      START_PHASE="$2"; END_PHASE="$2"; shift 2 ;;
    --from-phase) START_PHASE="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --post-patch) END_PHASE=20; shift ;;
    --cleanup)    END_PHASE=21; shift ;;
    --full)       END_PHASE=21; shift ;;
    -h|--help)    sed -n '3,55p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
run_local() {
  local phase="$1" script="$2" desc="$3"
  section "PHASE ${phase}: ${desc}"
  log "Script: ${SCRIPT_DIR}/${script}"
  log "Node  : $(hostname -s) (LOCAL)"
  [[ "${DRY_RUN}" == "true" ]] && { log "[DRY-RUN] Would execute locally"; return 0; }
  [[ -x "${SCRIPT_DIR}/${script}" ]] || { chmod +x "${SCRIPT_DIR}/${script}" 2>/dev/null || true; }
  local t0=$SECONDS
  bash "${SCRIPT_DIR}/${script}"
  local rc=$? e=$(( SECONDS - t0 ))
  [[ ${rc} -ne 0 ]] && die "Phase ${phase} FAILED (exit ${rc}) after ${e}s"
  log "Phase ${phase} COMPLETE in ${e}s"
}

run_local_bg() {
  # Long-running phases — print the systemd-run command for the operator to run
  local phase="$1" script="$2" desc="$3"
  local logfile="${LOG_DIR:-${LOG_BASE}/$(hostname -s)}/$(basename ${script} .sh).log"
  section "PHASE ${phase}: ${desc} [BACKGROUND]"
  log "Script: ${SCRIPT_DIR}/${script}"
  log "Node  : $(hostname -s) (LOCAL — run in background)"
  log ""
  log "  Run this command:"
  local unit="dgpatch-$(basename "${script}" .sh | tr _ -)"
  log "    systemd-run --unit=${unit} -p KillMode=process --remain-after-exit bash ${SCRIPT_DIR}/${script}"
  log "    tail -f ${logfile}"
  log ""
  log "  Wait for it to complete (RESULT: ALL CHECKS PASSED) before proceeding."
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would run in background"; return 0
  fi
  read -r -p "  Press ENTER when the background job has completed successfully: "
  log "Phase ${phase} confirmed complete."
}

peer_step() {
  local phase="$1" script="$2" desc="$3" peer_host="$4"
  local logfile="${LOG_BASE}/${peer_host}/$(basename ${script} .sh).log"
  section "PHASE ${phase}: ${desc} [PEER: ${peer_host}]"
  log ""
  log "  Run on ${peer_host} as root:"
  log "    bash ${SCRIPT_DIR}/${script}"
  log ""
  log "  Monitor: tail -f ${logfile}"
  log "  Wait for: RESULT: ALL CHECKS PASSED ✓"
  [[ "${DRY_RUN}" == "true" ]] && { log "[DRY-RUN] Peer step noted"; return 0; }
  read -r -p "  Press ENTER when ${peer_host} phase ${phase} is complete: "
  log "Phase ${phase} peer step confirmed."
}

peer_step_optional() {
  local phase="$1" script="$2" desc="$3" peer_host="$4"
  section "PHASE ${phase}: ${desc} [PEER: ${peer_host} — only if broker unavailable]"
  log ""
  log "  Check switchover_local.sh output:"
  log "  - If 'DG Broker path: SUCCESS' → SKIP this step"
  log "  - If 'Manual SQL path' → run on ${peer_host} as root:"
  log "      bash ${SCRIPT_DIR}/${script}"
  [[ "${DRY_RUN}" == "true" ]] && { log "[DRY-RUN] Optional peer step noted"; return 0; }
  read -r -p "  Press ENTER when done (or ENTER to skip if broker succeeded): "
  log "Phase ${phase} optional peer step complete."
}

# ── Banner ────────────────────────────────────────────────────────────────────
section "DG ROLLING PATCH RUNBOOK"
log "Patch    : ${OLD_PATCH_LEVEL} → ${NEW_PATCH_LEVEL}"
log "Primary  : ${PRIMARY_HOST} (${PRIMARY_DB_UNIQUE_NAME})"
log "Standby  : ${STANDBY_HOST} (${STANDBY_DB_UNIQUE_NAME})"
log "Phases   : ${START_PHASE} to ${END_PHASE}"
log "Dry-run  : ${DRY_RUN}"
log ""
log "Script dir: ${SCRIPT_DIR}"
log "Logs      : ${LOG_BASE}/"

# ─────────────────────────────────────────────────────────────────────────────
# PREP PHASE — Pre-downtime, no outage, both nodes in parallel
# ─────────────────────────────────────────────────────────────────────────────
if (( START_PHASE <= 1 && END_PHASE >= 1 )); then
  section "══ PREP PHASE (no outage — both nodes can run in parallel) ══"
  log ""
  log "  Start on ${STANDBY_HOST} first, then immediately start on ${PRIMARY_HOST}."
  log ""
  log "  On ${STANDBY_HOST} as root:"
  log "    systemd-run --unit=dgpatch-prep-s-local -p KillMode=process --remain-after-exit bash ${SCRIPT_DIR}/prep/prep_s_local.sh"
  log "    tail -f ${LOG_BASE}/${STANDBY_HOST}/prep_s_local.log"
  log ""
  [[ "${DRY_RUN}" == "true" ]] || read -r -p "  Press ENTER when standby prep has been STARTED on ${STANDBY_HOST}: "

  run_local_bg 1 "prep/prep_p_local.sh" \
    "Build and patch new Grid+DB homes on ${PRIMARY_HOST} (background, ~90min)"
fi

(( START_PHASE <= 2 && END_PHASE >= 2 )) && \
  peer_step 2 "prep/prep_s_local.sh" \
    "Confirm prep complete on ${STANDBY_HOST}" "${STANDBY_HOST}"

(( START_PHASE <= 3 && END_PHASE >= 3 )) && \
  run_local 3 "prep/prep_verify_peer.sh" \
    "Verify DG still healthy after parallel prep"

# ─────────────────────────────────────────────────────────────────────────────
# SWITCH TEST — Optional
# ─────────────────────────────────────────────────────────────────────────────
if (( START_PHASE <= 4 && END_PHASE >= 4 )); then
  section "══ SWITCH TEST (optional — proves DG switchover before downtime) ══"
  log "  Skip this section if you have already verified DG switchover works."
  [[ "${DRY_RUN}" == "true" ]] || \
    read -r -p "  Run switch test? (ENTER to run, Ctrl-C to skip): "
  run_local 4 "switch_test/switchtest_local.sh" \
    "Test switchover+switchback: ${PRIMARY_HOST}"
fi

(( START_PHASE <= 5 && END_PHASE >= 5 )) && \
  peer_step 5 "switch_test/switchtest_peer.sh" \
    "Confirm roles after switch test" "${STANDBY_HOST}"

# ─────────────────────────────────────────────────────────────────────────────
# DEPLOY PHASE — Downtime window
# ─────────────────────────────────────────────────────────────────────────────
if (( START_PHASE <= 6 && END_PHASE >= 6 )); then
  section "══ DEPLOY PHASE — DOWNTIME WINDOW ══"
  log "  ⚠ Notify stakeholders before proceeding."
  log "  ⚠ All steps from here until validate_peer.sh are the maintenance window."
  [[ "${DRY_RUN}" == "true" ]] || \
    read -r -p "  Confirm maintenance window is in effect (ENTER to proceed): "
fi

(( START_PHASE <= 6 && END_PHASE >= 6 )) && \
  peer_step 6 "deploy/deploy_s_local.sh" \
    "AutoUpgrade deploy on standby ${STANDBY_HOST} (stop MRP, home switch, opatchauto)" \
    "${STANDBY_HOST}"

(( START_PHASE <= 7 && END_PHASE >= 7 )) && \
  run_local 7 "deploy/deploy_s_peer.sh" \
    "Pre-switchover checks from ${PRIMARY_HOST}"

(( START_PHASE <= 8 && END_PHASE >= 8 )) && \
  run_local 8 "deploy/switchover_local.sh" \
    "Planned switchover: ${PRIMARY_HOST}→STANDBY  ${STANDBY_HOST}→PRIMARY"

(( START_PHASE <= 9 && END_PHASE >= 9 )) && \
  peer_step_optional 9 "deploy/switchover_peer.sh" \
    "Complete switchover on ${STANDBY_HOST} (manual SQL fallback only)" \
    "${STANDBY_HOST}"

(( START_PHASE <= 10 && END_PHASE >= 10 )) && \
  run_local 10 "deploy/deploy_p_local.sh" \
    "AutoUpgrade deploy on ${PRIMARY_HOST} (now standby)"

(( START_PHASE <= 11 && END_PHASE >= 11 )) && \
  peer_step 11 "deploy/deploy_p_peer.sh" \
    "Archive log switch + verify from ${STANDBY_HOST} (current primary)" \
    "${STANDBY_HOST}"

(( START_PHASE <= 12 && END_PHASE >= 12 )) && \
  peer_step 12 "deploy/datapatch_peer.sh" \
    "Run datapatch on current primary ${STANDBY_HOST}" "${STANDBY_HOST}"

(( START_PHASE <= 13 && END_PHASE >= 13 )) && \
  run_local 13 "deploy/datapatch_local.sh" \
    "Verify datapatch redo applied to ${PRIMARY_HOST}"

(( START_PHASE <= 14 && END_PHASE >= 14 )) && \
  run_local 14 "deploy/switchback_local.sh" \
    "Planned switchback: restore original roles"

(( START_PHASE <= 15 && END_PHASE >= 15 )) && \
  peer_step_optional 15 "deploy/switchback_peer.sh" \
    "Complete switchback on ${STANDBY_HOST} (manual SQL fallback only)" \
    "${STANDBY_HOST}"

(( START_PHASE <= 16 && END_PHASE >= 16 )) && \
  run_local 16 "deploy/validate_local.sh" \
    "Final post-patch validation: ${PRIMARY_HOST}"

(( START_PHASE <= 17 && END_PHASE >= 17 )) && \
  peer_step 17 "deploy/validate_peer.sh" \
    "Standby validation on ${STANDBY_HOST}" "${STANDBY_HOST}"

# ─────────────────────────────────────────────────────────────────────────────
# POST-PATCH — Both nodes independently, no outage
# ─────────────────────────────────────────────────────────────────────────────
if (( END_PHASE >= 18 )); then
  section "══ POST-PATCH PHASE (both nodes, no outage) ══"

  (( START_PHASE <= 18 && END_PHASE >= 18 )) && \
    run_local 18 "deploy/post_install_local.sh" \
      "chopt, utlrp, registry validation on ${PRIMARY_HOST}"

  (( START_PHASE <= 18 && END_PHASE >= 18 )) && \
    peer_step 18 "deploy/post_install_local.sh" \
      "Post-install validation on ${STANDBY_HOST}" "${STANDBY_HOST}"

  (( START_PHASE <= 19 && END_PHASE >= 19 )) && \
    run_local 19 "deploy/security_local.sh" \
      "Security hardening on ${PRIMARY_HOST} (FIPS, extproc)"

  (( START_PHASE <= 19 && END_PHASE >= 19 )) && \
    peer_step 19 "deploy/security_local.sh" \
      "Security hardening on ${STANDBY_HOST}" "${STANDBY_HOST}"

  if (( START_PHASE <= 20 && END_PHASE >= 20 )); then
    section "PHASE 20: AIDE integrity database reset [BACKGROUND, ~60 min each node]"
    log ""
    log "  Run on BOTH nodes (can run simultaneously):"
    log ""
    log "  On ${PRIMARY_HOST} as root:"
    log "    systemd-run --unit=dgpatch-aide-local -p KillMode=process --remain-after-exit bash ${SCRIPT_DIR}/deploy/aide_local.sh"
    log "    tail -f ${LOG_BASE}/${PRIMARY_HOST}/aide_local.log"
    log ""
    log "  On ${STANDBY_HOST} as root:"
    log "    systemd-run --unit=dgpatch-aide-local -p KillMode=process --remain-after-exit bash ${SCRIPT_DIR}/deploy/aide_local.sh"
    log "    tail -f ${LOG_BASE}/${STANDBY_HOST}/aide_local.log"
    log ""
    [[ "${DRY_RUN}" == "true" ]] || \
      read -r -p "  Press ENTER when AIDE has completed on BOTH nodes: "
    log "Phase 20 AIDE confirmed complete on both nodes."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP — Opt-in, ≥24h after patching
# ─────────────────────────────────────────────────────────────────────────────
if (( START_PHASE <= 21 && END_PHASE >= 21 )); then
  section "══ CLEANUP (opt-in, ≥24h after patching) ══"
  log "  Run on each node independently."
  log "  Each will prompt for YES confirmation."
  log ""
  run_local 21 "deploy/cleanup_local.sh" \
    "Deinstall old homes on ${PRIMARY_HOST}"
  peer_step 21 "deploy/cleanup_local.sh" \
    "Deinstall old homes on ${STANDBY_HOST}" "${STANDBY_HOST}"
fi

# ── Final summary ─────────────────────────────────────────────────────────────
section "PATCH CYCLE COMPLETE"
log "Both nodes at  : ${NEW_PATCH_LEVEL}"
log "Primary        : ${PRIMARY_HOST} (${PRIMARY_DB_UNIQUE_NAME})"
log "Standby        : ${STANDBY_HOST} (${STANDBY_DB_UNIQUE_NAME})"
log "Roles          : Original (same as before patch cycle)"
log ""
log "Logs:"
log "  ${LOG_BASE}/${PRIMARY_HOST}/"
log "  ${LOG_BASE}/${STANDBY_HOST}/"
