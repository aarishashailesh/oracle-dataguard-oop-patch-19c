#!/usr/bin/env bash
# =============================================================================
# deploy/deploy_p_local.sh — DOWNTIME: AutoUpgrade Deploy on lnx107 (now Standby)
# Run as: root  ON: lnx107
#
# Changes from v1:
#   - Added Step 2b: open standby READ ONLY before AutoUpgrade (was failing with
#     MOUNTED state immediately after switchover)
#   - Added Step 3d: chown /u01/app/oracle/diag before AutoUpgrade analyze
#     (kfod ADR initialization fails when diag dir owned by grid:oinstall)
#   - Steps 6-7: replaced opatchauto with gridSetup.sh -switchGridHome + root.sh
#   - Removed stray "\ || {" fragment after password file copy block
#   - Added --from-step N flag to resume after partial completion
#   - Step 3c clear_recovery_data uses correct java path via ORACLE_HOME/jdk/bin/java
#
# Usage:
#   bash deploy/deploy_p_local.sh              # full run
#   bash deploy/deploy_p_local.sh --from-step 6  # resume at GI switch
#
# Steps:
#   1.  Confirm PHYSICAL STANDBY role
#   2.  Stop MRP
#   2b. Open standby READ ONLY (required for AutoUpgrade analyze)
#   3.  Generate AutoUpgrade config
#   3b. Ensure init/spfile accessible in old home dbs/
#   3c. Clear stale AutoUpgrade recovery data
#   3d. Fix diag directory ownership (kfod ADR fix)
#   4.  AutoUpgrade analyze
#   5.  AutoUpgrade deploy (DB home switch)
#   5b. Copy password file to new DB home
#   6.  GI home switch (gridSetup.sh -switchGridHome + root.sh)
#   7.  Verify patch levels
#   8.  Start MRP
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
  dry_run_header "deploy_p_local.sh"
  drstep "Step 1: Confirm PHYSICAL STANDBY role"
  drcmd  "sqlplus / as sysdba: SELECT DATABASE_ROLE FROM V\$DATABASE  (ORACLE_SID=${PRIMARY_SID})"
  echo ""
  drstep "Step 2: Stop MRP"
  drcmd  "sqlplus / as sysdba: ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL  (ORACLE_SID=${PRIMARY_SID})"
  echo ""
  drstep "Step 2b: Ensure standby OPEN READ ONLY (required for AutoUpgrade)"
  drcmd  "sqlplus / as sysdba: SELECT OPEN_MODE FROM V\$DATABASE  (ORACLE_SID=${PRIMARY_SID})"
  drcmd  "sqlplus / as sysdba: ALTER DATABASE OPEN READ ONLY  (if MOUNTED)"
  drcmd  "sqlplus / as sysdba: ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION"
  echo ""
  drstep "Step 3: Generate AutoUpgrade config"
  drcmd  "cat > ${LOG_BASE}/${PRIMARY_HOST}/au_${PRIMARY_HOST}.cfg <<EOF"
  drcmd  "  global.autoupg_log_dir=${LOG_BASE}/${PRIMARY_HOST}/autoupgrade"
  drcmd  "  global.restoration=no"
  drcmd  "  upg1.source_home=${OLD_DB_HOME}"
  drcmd  "  upg1.target_home=${NEW_DB_HOME}"
  drcmd  "  upg1.sid=${PRIMARY_SID}"
  drcmd  "  upg1.run_utlrp=yes"
  drcmd  "  upg1.timezone_upg=no"
  drcmd  "EOF"
  echo ""
  drstep "Step 3b: Ensure init/spfile accessible in old DB home dbs/"
  drcmd  "sqlplus / as sysdba: CREATE PFILE='${OLD_DB_HOME}/dbs/init${PRIMARY_SID}.ora' FROM SPFILE  (if no pfile/spfile in dbs/)"
  echo ""
  drstep "Step 3c: Clear stale AutoUpgrade recovery data"
  drcmd  "su - ${ORACLE_USER} -c \"ORACLE_HOME=${NEW_DB_HOME} ORACLE_SID=${PRIMARY_SID} java -jar ${AUTOUPGRADE_JAR} -config ${LOG_BASE}/${PRIMARY_HOST}/au_${PRIMARY_HOST}.cfg -clear_recovery_data\""
  echo ""
  drstep "Step 3d: Fix diag directory ownership (kfod ADR requirement)"
  drcmd  "chown -R ${ORACLE_USER}:${INSTALL_GROUP} ${ADR_BASE}"
  drnote "Required: kfod fails with COM-115 if ${ADR_BASE} is owned by grid user"
  echo ""
  drstep "Step 4: AutoUpgrade analyze"
  drcmd  "su - ${ORACLE_USER} -c \"ORACLE_HOME=${NEW_DB_HOME} ORACLE_SID=${PRIMARY_SID} ADR_BASE=${ADR_BASE} java -jar ${AUTOUPGRADE_JAR} -config ${LOG_BASE}/${PRIMARY_HOST}/au_${PRIMARY_HOST}.cfg -mode analyze -noconsole\""
  echo ""
  drstep "Step 5: AutoUpgrade deploy (DB home switch)"
  drcmd  "su - ${ORACLE_USER} -c \"ORACLE_HOME=${NEW_DB_HOME} ORACLE_SID=${PRIMARY_SID} ADR_BASE=${ADR_BASE} java -jar ${AUTOUPGRADE_JAR} -config ${LOG_BASE}/${PRIMARY_HOST}/au_${PRIMARY_HOST}.cfg -mode deploy -noconsole\""
  drnote "AutoUpgrade: stops ${PRIMARY_SID}, switches ${OLD_DB_HOME} -> ${NEW_DB_HOME}, restarts as standby"
  echo ""
  drstep "Step 5b: Copy password file to new DB home"
  drcmd  "cp ${OLD_DB_HOME}/dbs/orapw${PRIMARY_SID} ${NEW_DB_HOME}/dbs/orapw${PRIMARY_SID}"
  drcmd  "chown ${ORACLE_USER}:${INSTALL_GROUP} ${NEW_DB_HOME}/dbs/orapw${PRIMARY_SID}"
  echo ""
  drstep "Step 6: Switch GI home (gridSetup.sh -switchGridHome + root.sh)"
  drcmd  "su - ${GRID_USER} -c \"${NEW_GRID_HOME}/gridSetup.sh -switchGridHome -responseFile ${GRID_RSP_PRIMARY} -silent\" &"
  drcmd  "# (wait for root.sh prompt)"
  drcmd  "${NEW_GRID_HOME}/root.sh  # stops ${OLD_GRID_HOME} CRS, starts ${NEW_GRID_HOME} CRS"
  echo ""
  drstep "Step 7: Verify patch levels"
  drcmd  "su - ${ORACLE_USER} -c \"${NEW_DB_HOME}/OPatch/opatch lspatches | grep ${DB_APPLY_RU_PATCH}\""
  drcmd  "su - ${GRID_USER}   -c \"${NEW_GRID_HOME}/OPatch/opatch lspatches | grep ${GI_APPLY_RU_PATCH}\""
  echo ""
  drstep "Step 8: Start MRP"
  drcmd  "sqlplus / as sysdba: ALTER DATABASE OPEN READ ONLY  (if MOUNTED after AutoUpgrade)"
  drcmd  "sqlplus / as sysdba: ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION  (ORACLE_SID=${PRIMARY_SID}, ORACLE_HOME=${NEW_DB_HOME})"
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
verify_node "${PRIMARY_HOST}"
setup_log "deploy_p_local"
FAILED=0

section "DEPLOY PRIMARY: AutoUpgrade on ${PRIMARY_HOST} (now standby)"
log "Old DB home: ${OLD_DB_HOME}"
log "New DB home: ${NEW_DB_HOME}"
log "SID        : ${PRIMARY_SID} (running as PHYSICAL STANDBY)"

[[ -d "${NEW_GRID_HOME}" ]] || die "NEW_GRID_HOME missing -- run prep_p_local.sh first"
[[ -d "${NEW_DB_HOME}" ]]   || die "NEW_DB_HOME missing -- run prep_p_local.sh first"

# ---------------------------------------------------------------------------
if should_run 1; then
  step "Step 1: Confirm ${PRIMARY_HOST} is in PHYSICAL STANDBY role"
  ROLE_CHECK=$(runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" \
    "SELECT DATABASE_ROLE FROM V\$DATABASE;" \
    2>/dev/null | grep -c "PHYSICAL STANDBY" || echo "0")
  log "  Physical Standby matches: ${ROLE_CHECK}"
  if (( ${ROLE_CHECK:-0} >= 1 )); then
    pass "Role confirmed: PHYSICAL STANDBY"
  else
    warn "Role check inconclusive -- proceeding (switchover confirmed by switchover_local.sh)"
  fi
fi

# ---------------------------------------------------------------------------
if should_run 2; then
  step "Step 2: Stop MRP"
  runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" "
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
" 2>/dev/null && log "  MRP cancel issued." || warn "MRP cancel non-zero (may not be running)."
  sleep 10
fi

# ---------------------------------------------------------------------------
if should_run 3; then
  step "Step 2b: Ensure standby is OPEN READ ONLY (required for AutoUpgrade)"
  # After switchover, lnx107 starts in MOUNTED state. AutoUpgrade requires
  # the database to be open in READ_ONLY or READ_ONLY_WITH_APPLY mode.
  OPEN_MODE=$(runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" \
    "SELECT OPEN_MODE FROM V\$DATABASE;" \
    2>/dev/null | grep -v "^$\|OPEN_MODE\|---" | sed 's/^[[:space:]]*//' | head -1 || echo "ERR")
  log "  Current open mode: ${OPEN_MODE}"
  case "${OPEN_MODE}" in
    MOUNTED)
      log "  Database MOUNTED -- opening READ ONLY and starting MRP..."
      runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" \
        "ALTER DATABASE OPEN READ ONLY;" \
        2>/dev/null && log "  Opened READ ONLY." || warn "OPEN READ ONLY non-zero."
      runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" \
        "ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;" \
        2>/dev/null && log "  MRP started." || warn "MRP start non-zero."
      sleep 20
      pass "Database opened READ ONLY WITH APPLY"
      ;;
    "READ ONLY WITH APPLY"|"READ ONLY")
      pass "Database already ${OPEN_MODE} -- no action needed"
      ;;
    *)
      warn "Unexpected open mode: '${OPEN_MODE}' -- AutoUpgrade may fail"
      ;;
  esac
fi

# ---------------------------------------------------------------------------
if should_run 4; then
  step "Step 3: Generate AutoUpgrade config"
  AU_LOG_DIR="${LOG_BASE}/${PRIMARY_HOST}/autoupgrade"
  mkdir -p "${AU_LOG_DIR}"
  chown "${ORACLE_USER}:${INSTALL_GROUP}" "${AU_LOG_DIR}"
  AU_CFG="${LOG_BASE}/${PRIMARY_HOST}/au_${PRIMARY_HOST}.cfg"
  cat > "${AU_CFG}" <<AUCFG
# AutoUpgrade config -- ${PRIMARY_HOST} (now standby) -- generated $(date)
# run_datapatch is not set: AutoUpgrade detects standby role and skips datapatch.
# datapatch runs on the PRIMARY after switchover via datapatch_peer.sh.
global.autoupg_log_dir=${AU_LOG_DIR}
global.restoration=no
upg1.source_home=${OLD_DB_HOME}
upg1.target_home=${NEW_DB_HOME}
upg1.sid=${PRIMARY_SID}
upg1.log_dir=${AU_LOG_DIR}
upg1.run_utlrp=yes
upg1.timezone_upg=no
AUCFG
  chown "${ORACLE_USER}:${INSTALL_GROUP}" "${AU_CFG}"
  pass "AutoUpgrade config: ${AU_CFG}"
fi

# ---------------------------------------------------------------------------
if should_run 5; then
  step "Step 3b: Ensure init/spfile accessible in old DB home dbs/"
  INIT_FILE="${OLD_DB_HOME}/dbs/init${PRIMARY_SID}.ora"
  SPFILE_FILE="${OLD_DB_HOME}/dbs/spfile${PRIMARY_SID}.ora"
  if [[ ! -f "${INIT_FILE}" && ! -f "${SPFILE_FILE}" ]]; then
    log "  No init/spfile in ${OLD_DB_HOME}/dbs/ -- creating pfile from ASM spfile..."
    runsql "${OLD_DB_HOME}" "${PRIMARY_SID}" "
CREATE PFILE='${OLD_DB_HOME}/dbs/init${PRIMARY_SID}.ora' FROM SPFILE;
" 2>/dev/null && pass "Created ${INIT_FILE} from ASM spfile" \
      || warn "Could not create pfile -- AutoUpgrade may fail with UPG-2002"
  else
    pass "init/spfile found in ${OLD_DB_HOME}/dbs/"
  fi
fi

# ---------------------------------------------------------------------------
if should_run 6; then
  step "Step 3c: Clear any stale AutoUpgrade recovery data"
  AU_CFG="${LOG_BASE}/${PRIMARY_HOST}/au_${PRIMARY_HOST}.cfg"
  log "  Clearing stale AutoUpgrade jobs..."
  runora "
    export ORACLE_HOME=${NEW_DB_HOME}
    export ORACLE_SID=${PRIMARY_SID}
    export ADR_BASE=${ADR_BASE}
    export PATH=\${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin
    \${ORACLE_HOME}/jdk/bin/java \
      -jar ${AUTOUPGRADE_JAR} \
      -config ${AU_CFG} -clear_recovery_data 2>/dev/null
  " && log "  Stale AU data cleared." || log "  No stale AU data found."
fi

# ---------------------------------------------------------------------------
if should_run 7; then
  step "Step 3d: Fix diag directory ownership (kfod ADR requirement)"
  # kfod fails to initialize ADR if /u01/app/oracle/diag is owned by grid.
  # Symptom: COM-115 DISK_SPACE_FOR_RECOVERY_AREA check fails.
  if [[ -d "${ADR_BASE}" ]]; then
    chown -R "${ORACLE_USER}:${INSTALL_GROUP}" "${ADR_BASE}"
    pass "diag ownership set to ${ORACLE_USER}:${INSTALL_GROUP}"
  else
    warn "${ADR_BASE} not found -- AutoUpgrade may fail COM-115"
  fi
fi

# ---------------------------------------------------------------------------
if should_run 8; then
  step "Step 4: AutoUpgrade analyze"
  AU_CFG="${LOG_BASE}/${PRIMARY_HOST}/au_${PRIMARY_HOST}.cfg"
  AU_LOG_DIR="${LOG_BASE}/${PRIMARY_HOST}/autoupgrade"
  runora "
    export ORACLE_HOME=${NEW_DB_HOME}
    export ORACLE_SID=${PRIMARY_SID}
    export ADR_BASE=${ADR_BASE}
    export PATH=\${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin
    \${ORACLE_HOME}/jdk/bin/java \
      -jar ${AUTOUPGRADE_JAR} \
      -config ${AU_CFG} -mode analyze -noconsole
  " && pass "AutoUpgrade analyze complete" \
    || { fail "AutoUpgrade analyze failed -- review ${AU_LOG_DIR}"; exit 1; }
fi

# ---------------------------------------------------------------------------
if should_run 9; then
  step "Step 5: AutoUpgrade deploy (DB home switch)"
  AU_CFG="${LOG_BASE}/${PRIMARY_HOST}/au_${PRIMARY_HOST}.cfg"
  AU_LOG_DIR="${LOG_BASE}/${PRIMARY_HOST}/autoupgrade"
  runora "
    export ORACLE_HOME=${NEW_DB_HOME}
    export ORACLE_SID=${PRIMARY_SID}
    export ADR_BASE=${ADR_BASE}
    export PATH=\${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin
    \${ORACLE_HOME}/jdk/bin/java \
      -jar ${AUTOUPGRADE_JAR} \
      -config ${AU_CFG} -mode deploy -noconsole
  " && pass "AutoUpgrade deploy complete" \
    || { fail "AutoUpgrade deploy failed -- review ${AU_LOG_DIR}"; exit 1; }
fi

# ---------------------------------------------------------------------------
if should_run 10; then
  step "Step 5b: Copy password file to new DB home"
  PW_SRC="${OLD_DB_HOME}/dbs/orapw${PRIMARY_SID}"
  PW_DST="${NEW_DB_HOME}/dbs/orapw${PRIMARY_SID}"
  if [[ -f "${PW_SRC}" ]]; then
    cp "${PW_SRC}" "${PW_DST}"
    chown "${ORACLE_USER}:${INSTALL_GROUP}" "${PW_DST}"
    chmod 640 "${PW_DST}"
    pass "Password file copied: ${PW_DST}"
  else
    warn "Password file not found at ${PW_SRC}"
  fi
fi

# ---------------------------------------------------------------------------
if should_run 11; then
  step "Step 6: Switch Grid Infrastructure home"
  run_gi_switch "${NEW_GRID_HOME}" "${GRID_RSP_PRIMARY}" "${GRID_USER}"
fi

# ---------------------------------------------------------------------------
if should_run 12; then
  step "Step 7: Verify patch levels"
  check_patches_in_home "${NEW_DB_HOME}"   "${ORACLE_USER}" "${DB_APPLY_RU_PATCH}" || true
  check_patches_in_home "${NEW_GRID_HOME}" "${GRID_USER}"   "${GI_APPLY_RU_PATCH}" || true
  log "  Note: DBA_REGISTRY_SQLPATCH skipped on standby (read-only)."
  pass "Patch level verification complete (now standby -- original primary)"
fi

# ---------------------------------------------------------------------------
if should_run 13; then
  step "Step 8: Start MRP"
  # AutoUpgrade starts the DB after home switch. Ensure it is OPEN READ ONLY
  # and MRP is running before returning.
  OPEN_MODE=$(runsql "${NEW_DB_HOME}" "${PRIMARY_SID}" \
    "SELECT OPEN_MODE FROM V\$DATABASE;" \
    2>/dev/null | grep -v "^$\|OPEN_MODE\|---" | sed 's/^[[:space:]]*//' | head -1 || echo "ERR")
  log "  Open mode after AutoUpgrade: ${OPEN_MODE}"
  if [[ "${OPEN_MODE}" == "MOUNTED" ]]; then
    runsql "${NEW_DB_HOME}" "${PRIMARY_SID}" \
      "ALTER DATABASE OPEN READ ONLY;" \
      2>/dev/null && log "  Opened READ ONLY." || warn "OPEN READ ONLY non-zero."
  fi

  MRP_PRE=$(runsql "${NEW_DB_HOME}" "${PRIMARY_SID}" "
SELECT COUNT(*) FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';
" 2>/dev/null | grep -E "^\s+[0-9]" | awk '{print $1}' || echo "0")
  if [[ "${MRP_PRE}" -ge 1 ]]; then
    log "  MRP already running -- skipping start."
  else
    runsql "${NEW_DB_HOME}" "${PRIMARY_SID}" "
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
" 2>/dev/null && log "  MRP start issued." || warn "MRP start non-zero."
  fi
  sleep 15
  MRP=$(runsql "${NEW_DB_HOME}" "${PRIMARY_SID}" "
SELECT PROCESS, STATUS, SEQUENCE# FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';
" 2>/dev/null || echo "ERR")
  echo "${MRP}" | while read -r l; do log "  ${l}"; done
  echo "${MRP}" | grep -qi "APPLYING_LOG\|WAIT_FOR_LOG" \
    && pass "MRP running on ${PRIMARY_HOST}" \
    || fail "MRP not running -- check alert log"
fi

print_summary "deploy_p_local"
log ""
log "NEXT: Run deploy_p_peer.sh ON ${STANDBY_HOST} (current primary)"
log "  bash deploy/deploy_p_peer.sh"
