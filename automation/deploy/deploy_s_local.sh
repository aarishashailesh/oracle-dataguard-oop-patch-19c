#!/usr/bin/env bash
# =============================================================================
# deploy/deploy_s_local.sh — DOWNTIME: AutoUpgrade Deploy on Standby (lnx113)
# Run as: root  ON: lnx113
#
# Changes from v1:
#   - Steps 5-6: replaced opatchauto with gridSetup.sh -switchGridHome + root.sh
#   - Removed stray "\ || {" fragment after password file copy block
#   - Added --from-step N flag to resume after partial completion
#
# Usage:
#   bash deploy/deploy_s_local.sh              # full run
#   bash deploy/deploy_s_local.sh --from-step 6  # resume at GI switch
#
# Steps:
#   1. Stop MRP
#   2. Generate AutoUpgrade config
#   3. AutoUpgrade analyze
#   4. AutoUpgrade deploy (DB home switch)
#   5. Copy password file to new DB home
#   6. GI home switch (gridSetup.sh -switchGridHome + root.sh)
#   7. Verify patch levels
#   8. Start MRP
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
  dry_run_header "deploy_s_local.sh"
  drstep "Step 1: Stop MRP"
  drcmd  "sqlplus / as sysdba: ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL  (ORACLE_SID=${STANDBY_SID})"
  echo ""
  drstep "Step 2: Generate AutoUpgrade config"
  drcmd  "mkdir -p ${LOG_BASE}/${STANDBY_HOST}/autoupgrade"
  drcmd  "cat > ${LOG_BASE}/${STANDBY_HOST}/au_${STANDBY_HOST}.cfg <<EOF"
  drcmd  "  global.autoupg_log_dir=${LOG_BASE}/${STANDBY_HOST}/autoupgrade"
  drcmd  "  global.restoration=no"
  drcmd  "  upg1.source_home=${OLD_DB_HOME}"
  drcmd  "  upg1.target_home=${NEW_DB_HOME}"
  drcmd  "  upg1.sid=${STANDBY_SID}"
  drcmd  "  upg1.run_utlrp=yes"
  drcmd  "  upg1.timezone_upg=no"
  drcmd  "EOF"
  echo ""
  drstep "Step 3: AutoUpgrade analyze"
  drcmd  "chown -R ${ORACLE_USER}:${INSTALL_GROUP} ${ADR_BASE}"
  drcmd  "su - ${ORACLE_USER} -c \"ORACLE_HOME=${NEW_DB_HOME} ORACLE_SID=${STANDBY_SID} ADR_BASE=${ADR_BASE} java -jar ${AUTOUPGRADE_JAR} -config ${LOG_BASE}/${STANDBY_HOST}/au_${STANDBY_HOST}.cfg -mode analyze -noconsole\""
  echo ""
  drstep "Step 4: AutoUpgrade deploy (DB home switch)"
  drcmd  "su - ${ORACLE_USER} -c \"ORACLE_HOME=${NEW_DB_HOME} ORACLE_SID=${STANDBY_SID} ADR_BASE=${ADR_BASE} java -jar ${AUTOUPGRADE_JAR} -config ${LOG_BASE}/${STANDBY_HOST}/au_${STANDBY_HOST}.cfg -mode deploy -noconsole\""
  drnote "AutoUpgrade: stops ${STANDBY_SID}, switches ${OLD_DB_HOME} -> ${NEW_DB_HOME}, restarts MRP"
  echo ""
  drstep "Step 5: Copy password file to new DB home"
  drcmd  "cp ${OLD_DB_HOME}/dbs/orapw${STANDBY_SID} ${NEW_DB_HOME}/dbs/orapw${STANDBY_SID}"
  drcmd  "chown ${ORACLE_USER}:${INSTALL_GROUP} ${NEW_DB_HOME}/dbs/orapw${STANDBY_SID}"
  echo ""
  drstep "Step 6: Switch GI home (gridSetup.sh -switchGridHome + root.sh)"
  drcmd  "su - ${GRID_USER} -c \"${NEW_GRID_HOME}/gridSetup.sh -switchGridHome -responseFile ${GRID_RSP_STANDBY} -silent\" &"
  drcmd  "# (wait for root.sh prompt -- polled from background process log)"
  drcmd  "${NEW_GRID_HOME}/root.sh  # stops old GI stack, starts from ${NEW_GRID_HOME}"
  drnote "Verification: ps -ef | grep ohasd.bin | grep ${NEW_GRID_HOME}"
  echo ""
  drstep "Step 7: Verify patch levels"
  drcmd  "su - ${ORACLE_USER} -c \"${NEW_DB_HOME}/OPatch/opatch lspatches | grep ${DB_APPLY_RU_PATCH}\""
  drcmd  "su - ${GRID_USER}   -c \"${NEW_GRID_HOME}/OPatch/opatch lspatches | grep ${GI_APPLY_RU_PATCH}\""
  echo ""
  drstep "Step 8: Start MRP"
  drcmd  "sqlplus / as sysdba: ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION  (ORACLE_SID=${STANDBY_SID}, ORACLE_HOME=${NEW_DB_HOME})"
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
verify_node "${STANDBY_HOST}"
setup_log "deploy_s_local"
FAILED=0

section "DEPLOY STANDBY: AutoUpgrade on ${STANDBY_HOST}"
log "Old DB home: ${OLD_DB_HOME}"
log "New DB home: ${NEW_DB_HOME}"
log "SID        : ${STANDBY_SID}"

[[ -d "${NEW_GRID_HOME}" ]] || die "NEW_GRID_HOME missing: ${NEW_GRID_HOME} -- run prep_s_local.sh first"
[[ -d "${NEW_DB_HOME}" ]]   || die "NEW_DB_HOME missing: ${NEW_DB_HOME} -- run prep_s_local.sh first"

# ---------------------------------------------------------------------------
if should_run 1; then
  step "Step 1: Stop MRP"
  runsql "${OLD_DB_HOME}" "${STANDBY_SID}" "
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
" 2>/dev/null && log "  MRP cancel issued." || warn "MRP cancel returned non-zero."
  sleep 10
  MRP=$(runsql "${OLD_DB_HOME}" "${STANDBY_SID}" \
    "SELECT COUNT(*) FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';" \
    2>/dev/null | grep -E "^\s+[0-9]" | awk '{print $1}' || echo "0")
  log "  MRP processes remaining: ${MRP} (expected 0)"
fi

# ---------------------------------------------------------------------------
if should_run 2; then
  step "Step 2: Generate AutoUpgrade config"
  AU_LOG_DIR="${LOG_BASE}/${STANDBY_HOST}/autoupgrade"
  mkdir -p "${AU_LOG_DIR}"
  chown "${ORACLE_USER}:${INSTALL_GROUP}" "${AU_LOG_DIR}"
  AU_CFG="${LOG_BASE}/${STANDBY_HOST}/au_${STANDBY_HOST}.cfg"
  cat > "${AU_CFG}" <<AUCFG
# AutoUpgrade config -- ${STANDBY_HOST} -- generated $(date)
# run_datapatch=no: standby cannot execute data dictionary writes.
# datapatch runs on the PRIMARY after switchover (datapatch_peer.sh).
global.autoupg_log_dir=${AU_LOG_DIR}
global.restoration=no
upg1.source_home=${OLD_DB_HOME}
upg1.target_home=${NEW_DB_HOME}
upg1.sid=${STANDBY_SID}
upg1.log_dir=${AU_LOG_DIR}
upg1.run_utlrp=yes
upg1.timezone_upg=no
AUCFG
  chown "${ORACLE_USER}:${INSTALL_GROUP}" "${AU_CFG}"
  pass "AutoUpgrade config: ${AU_CFG}"
fi

# ---------------------------------------------------------------------------
if should_run 3; then
  step "Step 3: AutoUpgrade analyze (pre-check)"
  AU_LOG_DIR="${LOG_BASE}/${STANDBY_HOST}/autoupgrade"
  AU_CFG="${LOG_BASE}/${STANDBY_HOST}/au_${STANDBY_HOST}.cfg"
  chown -R "${ORACLE_USER}:${INSTALL_GROUP}" "${ADR_BASE}" 2>/dev/null || true
  runora "
    export ORACLE_HOME=${NEW_DB_HOME}
    export ORACLE_SID=${STANDBY_SID}
    export ADR_BASE=${ADR_BASE}
    export PATH=\${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin
    \${ORACLE_HOME}/jdk/bin/java \
      -jar ${AUTOUPGRADE_JAR} \
      -config ${AU_CFG} -mode analyze -noconsole
  " && pass "AutoUpgrade analyze complete" \
    || { fail "AutoUpgrade analyze failed -- review ${AU_LOG_DIR}"; exit 1; }
fi

# ---------------------------------------------------------------------------
if should_run 4; then
  step "Step 4: AutoUpgrade deploy (DB home switch)"
  AU_LOG_DIR="${LOG_BASE}/${STANDBY_HOST}/autoupgrade"
  AU_CFG="${LOG_BASE}/${STANDBY_HOST}/au_${STANDBY_HOST}.cfg"
  log "  Shuts down ${STANDBY_SID}, switches home, restarts in managed recovery..."
  runora "
    export ORACLE_HOME=${NEW_DB_HOME}
    export ORACLE_SID=${STANDBY_SID}
    export ADR_BASE=${ADR_BASE}
    export PATH=\${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin
    \${ORACLE_HOME}/jdk/bin/java \
      -jar ${AUTOUPGRADE_JAR} \
      -config ${AU_CFG} -mode deploy -noconsole
  " && pass "AutoUpgrade deploy complete" \
    || { fail "AutoUpgrade deploy failed -- review ${AU_LOG_DIR}"; exit 1; }
fi

# ---------------------------------------------------------------------------
if should_run 5; then
  step "Step 5: Copy password file to new DB home"
  # AutoUpgrade does not copy the password file.
  # DG Broker requires matching password files on both nodes for switchover.
  PW_SRC="${OLD_DB_HOME}/dbs/orapw${STANDBY_SID}"
  PW_DST="${NEW_DB_HOME}/dbs/orapw${STANDBY_SID}"
  if [[ -f "${PW_SRC}" ]]; then
    cp "${PW_SRC}" "${PW_DST}"
    chown "${ORACLE_USER}:${INSTALL_GROUP}" "${PW_DST}"
    chmod 640 "${PW_DST}"
    pass "Password file copied: ${PW_DST}"
  else
    warn "Password file not found at ${PW_SRC} -- DG Broker switchover may fail"
  fi
fi

# ---------------------------------------------------------------------------
if should_run 6; then
  step "Step 6: Switch Grid Infrastructure home"
  # The new GI home was patched during prep via gridSetup.sh -applyRU.
  # gridSetup.sh -switchGridHome reconfigures CRS to start from the new home.
  # Do NOT use opatchauto here -- that applies patches in-place.
  run_gi_switch "${NEW_GRID_HOME}" "${GRID_RSP_STANDBY}" "${GRID_USER}"
fi

# ---------------------------------------------------------------------------
if should_run 7; then
  step "Step 7: Verify patch levels"
  check_patches_in_home "${NEW_DB_HOME}"   "${ORACLE_USER}" "${DB_APPLY_RU_PATCH}" || true
  check_patches_in_home "${NEW_GRID_HOME}" "${GRID_USER}"   "${GI_APPLY_RU_PATCH}" || true
  log "  Note: DBA_REGISTRY_SQLPATCH skipped on standby (read-only)."
  log "        datapatch runs on the primary after switchover."
  pass "Patch level verification complete (standby)"
fi

# ---------------------------------------------------------------------------
if should_run 8; then
  step "Step 8: Start MRP"
  MRP_PRE=$(runsql "${NEW_DB_HOME}" "${STANDBY_SID}" "
SELECT COUNT(*) FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';
" 2>/dev/null | grep -E "^\s+[0-9]" | awk '{print $1}' || echo "0")
  if [[ "${MRP_PRE}" -ge 1 ]]; then
    log "  MRP already running (started by AutoUpgrade) -- skipping."
  else
    runsql "${NEW_DB_HOME}" "${STANDBY_SID}" "
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
" 2>/dev/null && log "  MRP start issued." || warn "MRP start returned non-zero."
  fi
  sleep 15
  MRP2=$(runsql "${NEW_DB_HOME}" "${STANDBY_SID}" "
SELECT PROCESS, STATUS, SEQUENCE# FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';
" 2>/dev/null || echo "ERR")
  echo "${MRP2}" | while read -r l; do log "  ${l}"; done
  echo "${MRP2}" | grep -qi "APPLYING_LOG\|WAIT_FOR_LOG" \
    && pass "MRP running on ${STANDBY_HOST}" \
    || fail "MRP not running -- check alert log"
fi

print_summary "deploy_s_local"
log ""
log "NEXT: Run deploy_s_peer.sh ON ${PRIMARY_HOST}"
log "  bash deploy/deploy_s_peer.sh"
