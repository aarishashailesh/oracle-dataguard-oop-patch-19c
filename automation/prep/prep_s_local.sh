#!/usr/bin/env bash
# =============================================================================
# prep/prep_s_local.sh — PRE-DOWNTIME: Build New Homes on Standby (lnx113)
# Run as: root  ON: lnx113
# Outage: NONE — standby continues applying redo throughout
#
# BACKGROUND-SAFE: runs entirely on lnx113, no peer interaction.
# systemd-run --unit=dgpatch-prep-s-local --remain-after-exit --working-directory=<automation dir> bash prep/prep_s_local.sh
# tail -f /u01/app/oracle/patch_logs/lnx113/prep_s_local.log
#
# What this script does:
#   1.  Verify disk space and staging files
#   2.  Extract and patch new Grid home (gridSetup.sh CRS_SWONLY -applyRU)
#   3.  Extract and patch new DB home (runInstaller INSTALL_DB_SWONLY -applyRU)
#   4.  Upgrade OPatch in old Grid and DB homes (needed for opatchauto later)
#   5.  Update listener.ora if SID_LIST_LISTENER references OLD_DB_HOME
#   6.  Verify patch levels in new homes
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
  dry_run_header "prep_s_local.sh"

  drstep "Step 1: Pre-flight checks"
  drcmd  "df -BG ${PATCH_STAGE_DIR%/*} | awk '{print \$4}' | tail -1  # need >=30 GB free"
  drcmd  "test -f ${BASE_DIR}/${GRID_BASE_ZIP}"
  drcmd  "test -f ${BASE_DIR}/${DB_BASE_ZIP}"
  drcmd  "test -f ${OPATCH_DIR}/${OPATCH_ZIP}"
  drcmd  "test -f ${PATCH_DIR}/${RU_COMBO_ZIP}"

  echo ""
  drstep "Step 2: Extract RU combo patch ${RU_COMBO_PATCH}"
  drcmd  "unzip -q ${PATCH_DIR}/${RU_COMBO_ZIP} -d ${PATCH_DIR}/"
  drcmd  "chown -R root:${INSTALL_GROUP} ${RU_PATCH_DIR}/"
  drcmd  "find ${RU_PATCH_DIR} -type f -exec chmod o+r {} +"

  echo ""
  drstep "Step 3: Build and patch new Grid home (${OLD_PATCH_LEVEL} -> ${NEW_PATCH_LEVEL})"
  drcmd  "su - ${GRID_USER} -c \"mkdir -p ${NEW_GRID_HOME}\""
  drcmd  "su - ${GRID_USER} -c \"unzip -q ${BASE_DIR}/${GRID_BASE_ZIP} -d ${NEW_GRID_HOME}/\""
  drcmd  "su - ${GRID_USER} -c \"unzip -o -q ${OPATCH_DIR}/${OPATCH_ZIP} -d ${NEW_GRID_HOME}/\"  # upgrade OPatch"
  drcmd  "su - ${GRID_USER} -c \"${NEW_GRID_HOME}/gridSetup.sh -applyRU ${GI_APPLY_RU_PATH} -silent -skipPrereqs -responseFile /tmp/grid_swonly_<runtime>.rsp\""
  drnote "Source response file: ${GRID_RSP_STANDBY}"
  drnote "Script creates a sed-copy with oracle.install.option=CRS_SWONLY at runtime"
  drnote "root.sh NOT run during prep -- only during deploy (gridSetup.sh -switchGridHome)"

  echo ""
  drstep "Step 4: Build and patch new DB home (${OLD_PATCH_LEVEL} -> ${NEW_PATCH_LEVEL})"
  drcmd  "su - ${ORACLE_USER} -c \"mkdir -p ${NEW_DB_HOME}\""
  drcmd  "su - ${ORACLE_USER} -c \"unzip -q ${BASE_DIR}/${DB_BASE_ZIP} -d ${NEW_DB_HOME}/\""
  drcmd  "su - ${ORACLE_USER} -c \"unzip -o -q ${OPATCH_DIR}/${OPATCH_ZIP} -d ${NEW_DB_HOME}/\"  # upgrade OPatch"
  drcmd  "su - ${ORACLE_USER} -c \"${NEW_DB_HOME}/runInstaller -applyRU ${DB_APPLY_RU_PATH} -silent -skipPrereqs -responseFile ${DB_RSP_STANDBY}\""
  drcmd  "${NEW_DB_HOME}/root.sh  # run as root (registers new DB home in oraInventory)"

  echo ""
  drstep "Step 5: Upgrade OPatch in OLD homes"
  drcmd  "su - ${GRID_USER}   -c \"unzip -o -q ${OPATCH_DIR}/${OPATCH_ZIP} -d ${OLD_GRID_HOME}/\""
  drcmd  "su - ${ORACLE_USER} -c \"unzip -o -q ${OPATCH_DIR}/${OPATCH_ZIP} -d ${OLD_DB_HOME}/\""

  echo ""
  drstep "Step 6: Update listener.ora -- old DB home -> new DB home"
  drcmd  "sed -i 's|${OLD_DB_HOME}|${NEW_DB_HOME}|g' ${OLD_GRID_HOME}/network/admin/listener.ora"
  drnote "Ensures static listener entries reference the new home after GI switch"

  echo ""
  drstep "Step 7: Verify patch levels in new homes"
  drcmd  "su - ${GRID_USER}   -c \"${NEW_GRID_HOME}/OPatch/opatch lspatches\"  # expect patch ${GI_APPLY_RU_PATCH}"
  drcmd  "su - ${ORACLE_USER} -c \"${NEW_DB_HOME}/OPatch/opatch lspatches\"    # expect patch ${DB_APPLY_RU_PATCH}"

  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}
parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
verify_node "${STANDBY_HOST}"
setup_log "prep_s_local"
FAILED=0

section "PREP: Build New Homes on ${STANDBY_HOST} (${OLD_PATCH_LEVEL} → ${NEW_PATCH_LEVEL})"
log "New Grid home : ${NEW_GRID_HOME}"
log "New DB home   : ${NEW_DB_HOME}"
log "Stage dir     : ${PATCH_DIR}"

# ── Step 1: Pre-flight ────────────────────────────────────────────────────────
step "Step 1: Pre-flight checks"
AVAIL_GB=$(df -BG /u01 | awk 'NR==2 {gsub("G","",$4); print $4}')
log "  /u01 available: ${AVAIL_GB} GB (need ≥30 GB for both new homes)"
(( AVAIL_GB >= 30 )) && pass "Disk space OK" || { fail "Insufficient disk space"; exit 1; }

for f in "${BASE_DIR}/${GRID_BASE_ZIP}" \
          "${BASE_DIR}/${DB_BASE_ZIP}" \
          "${OPATCH_DIR}/${OPATCH_ZIP}" \
          "${PATCH_DIR}/${RU_COMBO_ZIP}"; do
  [[ -f "${f}" ]] && pass "Found: $(basename "${f}")" \
    || { fail "Missing: ${f}"; exit 1; }
done

# Extract RU combo if not already done
if [[ ! -d "${RU_PATCH_DIR}" ]]; then
  step "Extracting RU combo patch ${RU_COMBO_PATCH}..."
  unzip -q -o "${PATCH_DIR}/${RU_COMBO_ZIP}" -d "${PATCH_DIR}/"
  pass "RU combo extracted: ${RU_PATCH_DIR}"
else
  pass "RU combo already extracted: ${RU_PATCH_DIR}"
fi

# Extract standalone DB patch if needed
if [[ ! -d "${PATCH_DIR}/${DB_RU_STANDALONE_PATCH}" ]]; then
  log "  Extracting standalone DB patch ${DB_RU_STANDALONE_PATCH}..."
  unzip -q -o "${PATCH_DIR}/${DB_RU_STANDALONE_ZIP}" -d "${PATCH_DIR}/"
fi

for p in "${GI_APPLY_RU_PATH}" "${DB_APPLY_RU_PATH}"; do
  [[ -d "${p}" ]] && pass "Patch dir: ${p}" \
    || { fail "Patch dir missing: ${p}"; exit 1; }
done

# Fix permissions on all patch directories — zips extracted on a different
# system or by a different UID leave files owned by a numeric UID that grid
# and oracle cannot read. This is applied every run (idempotent).
step "Fix patch directory ownership and permissions"
chown -R root:"${INSTALL_GROUP}" "${PATCH_DIR}/"
find "${PATCH_DIR}" -type f -exec chmod o+r  {} +
find "${PATCH_DIR}" -type d -exec chmod o+rx {} +
# Executables inside patch bin dirs must stay executable
find "${PATCH_DIR}" -type f -name "*.bin" -exec chmod 755 {} +
find "${PATCH_DIR}" -type f -name "*.sh"  -exec chmod 755 {} +
pass "Patch directory permissions fixed (owner: root:${INSTALL_GROUP}, world-readable)"
log "  Spot check:"
ls -la "${GI_APPLY_RU_PATH}/files/bin/ocrcheck.bin" 2>/dev/null   | while read -r l; do log "    ${l}"; done || true

# ── Step 2: Build new Grid home ───────────────────────────────────────────────
step "Step 2: Build and patch new Grid home"
log "  Extracting base Grid 19.3 → ${NEW_GRID_HOME}"
mkdir -p "${NEW_GRID_HOME}"
chown -R "${GRID_USER}:${INSTALL_GROUP}" "$(dirname "${NEW_GRID_HOME}")"
unzip -q -o "${BASE_DIR}/${GRID_BASE_ZIP}" -d "${NEW_GRID_HOME}/"
chown -R "${GRID_USER}:${INSTALL_GROUP}" "${NEW_GRID_HOME}"

log "  Upgrading OPatch in new Grid home..."
rm -rf "${NEW_GRID_HOME}/OPatch"
unzip -q -o "${OPATCH_DIR}/${OPATCH_ZIP}" -d "${NEW_GRID_HOME}/"
chown -R "${GRID_USER}:${INSTALL_GROUP}" "${NEW_GRID_HOME}/OPatch"

GRID_RSP_TMP="/tmp/grid_rsp_stby_$$.rsp"
[[ -f "${GRID_RSP_STANDBY}" ]] || die "Grid response file missing: ${GRID_RSP_STANDBY}"
cp "${GRID_RSP_STANDBY}" "${GRID_RSP_TMP}"
sed -i "s|^ORACLE_HOME=.*|ORACLE_HOME=${NEW_GRID_HOME}|" "${GRID_RSP_TMP}"
sed -i "s|^oracle.install.option=.*|oracle.install.option=CRS_SWONLY|" "${GRID_RSP_TMP}"
chown "${GRID_USER}:${INSTALL_GROUP}" "${GRID_RSP_TMP}"
chmod 640 "${GRID_RSP_TMP}"
log "  Response file: ${GRID_RSP_STANDBY} (ORACLE_HOME updated to ${NEW_GRID_HOME})"

log "  Running gridSetup.sh CRS_SWONLY -applyRU ${GI_APPLY_RU_PATCH}..."
set +e
rungrid "
  export ORACLE_HOME=${NEW_GRID_HOME}
  export CV_ASSUME_DISTID=${CV_ASSUME_DISTID}
  export PATH=\${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin
  \${ORACLE_HOME}/gridSetup.sh \
    -silent -ignorePrereqFailure -waitforcompletion \
    -applyRU ${GI_APPLY_RU_PATH} \
    -applyOneOffs ${GI_ONEOFF_PATHS} \
    -responseFile ${GRID_RSP_TMP} \
    oracle.install.option=CRS_SWONLY
"
GS_RC=$?
set -e
check_installer_rc "gridSetup.sh CRS_SWONLY" "${GS_RC}" GridSetupActions || exit 1
rm -f "${GRID_RSP_TMP}"

# ── Step 3: Build new DB home ─────────────────────────────────────────────────
step "Step 3: Build and patch new DB home"
log "  Extracting base Oracle DB 19.3 → ${NEW_DB_HOME}"
mkdir -p "${NEW_DB_HOME}"
chown -R "${ORACLE_USER}:${INSTALL_GROUP}" "${NEW_DB_HOME}"
unzip -q -o "${BASE_DIR}/${DB_BASE_ZIP}" -d "${NEW_DB_HOME}/"
chown -R "${ORACLE_USER}:${INSTALL_GROUP}" "${NEW_DB_HOME}"

log "  Upgrading OPatch in new DB home..."
rm -rf "${NEW_DB_HOME}/OPatch"
unzip -q -o "${OPATCH_DIR}/${OPATCH_ZIP}" -d "${NEW_DB_HOME}/"
chown -R "${ORACLE_USER}:${INSTALL_GROUP}" "${NEW_DB_HOME}/OPatch"

DB_RSP_TMP="/tmp/db_rsp_stby_$$.rsp"
[[ -f "${DB_RSP_STANDBY}" ]] || die "DB response file missing: ${DB_RSP_STANDBY}"
cp "${DB_RSP_STANDBY}" "${DB_RSP_TMP}"
sed -i "s|^ORACLE_HOME=.*|ORACLE_HOME=${NEW_DB_HOME}|" "${DB_RSP_TMP}"

log "  Running runInstaller INSTALL_DB_SWONLY -applyRU ${DB_APPLY_RU_PATCH}..."
set +e
runora "
  export ORACLE_HOME=${NEW_DB_HOME}
  export CV_ASSUME_DISTID=${CV_ASSUME_DISTID}
  export PATH=\${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin
  \${ORACLE_HOME}/runInstaller \
    -silent -ignorePrereqFailure -waitforcompletion \
    -applyRU ${DB_APPLY_RU_PATH} \
    -applyOneOffs ${DB_ONEOFF_PATHS_FULL} \
    -responseFile ${DB_RSP_TMP} \
    ORACLE_HOME=${NEW_DB_HOME}
"
RI_RC=$?
set -e
check_installer_rc "runInstaller INSTALL_DB_SWONLY" "${RI_RC}" InstallActions || exit 1
rm -f "${DB_RSP_TMP}"

# ── Step 4: Upgrade OPatch in OLD homes (needed for opatchauto at deploy time)
step "Step 4: Upgrade OPatch in old Grid and DB homes"
BAK="bak.$(date +%Y%m%d_%H%M%S)"

mv "${OLD_GRID_HOME}/OPatch" "${OLD_GRID_HOME}/OPatch.${BAK}"
unzip -q -o "${OPATCH_DIR}/${OPATCH_ZIP}" -d "${OLD_GRID_HOME}/"
chown -R "${GRID_USER}:${INSTALL_GROUP}" "${OLD_GRID_HOME}/OPatch"
GI_OP_VER=$(rungrid "
  export ORACLE_HOME=${OLD_GRID_HOME}
  \${ORACLE_HOME}/OPatch/opatch version 2>/dev/null | grep 'OPatch Version'
" 2>/dev/null | awk '{print $NF}')
pass "Old Grid OPatch upgraded: ${GI_OP_VER}"

mv "${OLD_DB_HOME}/OPatch" "${OLD_DB_HOME}/OPatch.${BAK}"
unzip -q -o "${OPATCH_DIR}/${OPATCH_ZIP}" -d "${OLD_DB_HOME}/"
chown -R "${ORACLE_USER}:${INSTALL_GROUP}" "${OLD_DB_HOME}/OPatch"
DB_OP_VER=$(runora "
  export ORACLE_HOME=${OLD_DB_HOME}
  \${ORACLE_HOME}/OPatch/opatch version 2>/dev/null | grep 'OPatch Version'
" 2>/dev/null | awk '{print $NF}')
pass "Old DB OPatch upgraded: ${DB_OP_VER}"

# ── Step 5: Fix listener.ora if it has static SID_LIST_LISTENER ───────────────
step "Step 5: Update listener.ora with new DB home path"
LISTENER_ORA="${OLD_GRID_HOME}/network/admin/listener.ora"
if [[ -f "${LISTENER_ORA}" ]]; then
  if grep -q "${OLD_DB_HOME}" "${LISTENER_ORA}" 2>/dev/null; then
    cp "${LISTENER_ORA}" "${LISTENER_ORA}.bak.$(date +%Y%m%d_%H%M%S)"
    sed -i "s|${OLD_DB_HOME}|${NEW_DB_HOME}|g" "${LISTENER_ORA}"
    pass "listener.ora updated: ${OLD_DB_HOME} → ${NEW_DB_HOME}"
    grep "ORACLE_HOME" "${LISTENER_ORA}" | while read -r l; do log "  ${l}"; done
  else
    pass "listener.ora: no static ORACLE_HOME reference (dynamic registration — correct)"
  fi
else
  warn "listener.ora not found at ${LISTENER_ORA}"
fi

# ── Step 6: Stage AutoUpgrade JAR ─────────────────────────────────────────────
step "Step 6: Stage AutoUpgrade JAR"
if [[ -f "${AUTOUPGRADE_JAR}" ]]; then
  cp "${AUTOUPGRADE_JAR}" "${NEW_DB_HOME}/rdbms/admin/autoupgrade.jar"
  AU_VER=$(runora "
    ${NEW_DB_HOME}/jdk/bin/java \
      -jar ${NEW_DB_HOME}/rdbms/admin/autoupgrade.jar -version 2>/dev/null | head -1
  " 2>/dev/null || echo "unknown")
  pass "AutoUpgrade JAR staged: ${AU_VER}"
else
  warn "autoupgrade.jar not found at ${AUTOUPGRADE_JAR}"
fi

# ── Step 7: Verify new homes ──────────────────────────────────────────────────
step "Step 7: Verify patch levels in new homes"
check_patches_in_home "${NEW_GRID_HOME}" "${GRID_USER}" \
  "${GI_APPLY_RU_PATCH}" || true
check_patches_in_home "${NEW_DB_HOME}" "${ORACLE_USER}" \
  "${DB_APPLY_RU_PATCH}" || true

log ""
log "New Grid home patches:"
rungrid "
  export ORACLE_HOME=${NEW_GRID_HOME}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  \${ORACLE_HOME}/OPatch/opatch lspatches 2>/dev/null | head -10
" | while read -r l; do log "  ${l}"; done || true

log "New DB home patches:"
runora "
  export ORACLE_HOME=${NEW_DB_HOME}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  \${ORACLE_HOME}/OPatch/opatch lspatches 2>/dev/null | head -10
" | while read -r l; do log "  ${l}"; done || true

print_summary "prep_s_local"
