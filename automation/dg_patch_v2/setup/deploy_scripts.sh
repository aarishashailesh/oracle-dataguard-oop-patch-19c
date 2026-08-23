#!/usr/bin/env bash
# =============================================================================
# setup/deploy_scripts.sh
# One-time setup: create log directories and verify stage layout on this node.
# Run as root on EACH NODE before starting the patch cycle.
#
# Usage: bash setup/deploy_scripts.sh
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
  dry_run_header "deploy_scripts.sh"
  drstep "Create log directory: ${LOG_BASE}/$(hostname -s)"
  drcmd  "mkdir -p ${LOG_BASE}/$(hostname -s)"
  drcmd  "chown ${ORACLE_USER}:${INSTALL_GROUP} ${LOG_BASE}/$(hostname -s)"
  echo ""
  drstep "Verify patch stage layout"
  drcmd  "test -d ${PATCH_STAGE_DIR}"
  drcmd  "test -d ${PATCH_DIR}"
  drcmd  "test -d ${BASE_DIR}"
  drcmd  "test -d ${OPATCH_DIR}"
  echo ""
  drstep "Verify required zip files"
  drcmd  "test -f ${BASE_DIR}/${GRID_BASE_ZIP}"
  drcmd  "test -f ${BASE_DIR}/${DB_BASE_ZIP}"
  drcmd  "test -f ${OPATCH_DIR}/${OPATCH_ZIP}"
  drcmd  "test -f ${PATCH_DIR}/${RU_COMBO_ZIP}"
  drcmd  "test -f ${AUTOUPGRADE_JAR}"
  echo ""
  drstep "Verify response files"
  drcmd  "test -f ${GRID_RSP_PRIMARY}"
  drcmd  "test -f ${GRID_RSP_STANDBY}"
  drcmd  "test -f ${DB_RSP_PRIMARY}"
  drcmd  "test -f ${DB_RSP_STANDBY}"
  echo ""
  drstep "Set script permissions"
  drcmd  "find ${PATCH_STAGE_DIR}/../automation -name '*.sh' -exec chmod +x {} +"
  echo ""
  drstep "Verify Oracle home paths"
  drcmd  "test -d ${OLD_GRID_HOME}"
  drcmd  "test -d ${OLD_DB_HOME}"
  drcmd  "test ! -d ${NEW_GRID_HOME}  # must not exist yet"
  drcmd  "test ! -d ${NEW_DB_HOME}    # must not exist yet"
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

THIS_HOST=$(hostname -s)
parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
setup_log "setup_deploy"

section "Setup: ${THIS_HOST}"

# ── Log directory ─────────────────────────────────────────────────────────────
step "Creating log directory: ${LOG_BASE}/${THIS_HOST}"
mkdir -p "${LOG_BASE}/${THIS_HOST}"
chown -R "${ORACLE_USER}:${INSTALL_GROUP}" "${LOG_BASE}"
chmod -R 775 "${LOG_BASE}"
pass "Log directory ready: ${LOG_BASE}/${THIS_HOST}"

# ── Stage directory structure ─────────────────────────────────────────────────
step "Verifying patch stage layout"
MISSING=0
for d in "${PATCH_STAGE_DIR}" "${PATCH_DIR}" "${BASE_DIR}" "${OPATCH_DIR}" \
          "${PATCH_STAGE_DIR}/rsp"; do
  if [[ -d "${d}" ]]; then
    pass "Directory exists: ${d}"
  else
    fail "Directory missing: ${d} — create and stage files before patching"
    (( MISSING++ )) || true
  fi
done

# ── Required zip files ────────────────────────────────────────────────────────
step "Verifying required zip files"
for f in \
  "${BASE_DIR}/${GRID_BASE_ZIP}" \
  "${BASE_DIR}/${DB_BASE_ZIP}" \
  "${OPATCH_DIR}/${OPATCH_ZIP}" \
  "${PATCH_DIR}/${RU_COMBO_ZIP}" \
  "${AUTOUPGRADE_JAR}"; do
  if [[ -f "${f}" ]]; then
    SZ=$(du -sh "${f}" | awk '{print $1}')
    pass "Found [${SZ}]: ${f}"
  else
    fail "Missing: ${f}"
    (( MISSING++ )) || true
  fi
done

# ── Response files ────────────────────────────────────────────────────────────
step "Verifying response files"
if [[ "${THIS_HOST}" == "${PRIMARY_HOST}" ]]; then
  RSP_GRID="${GRID_RSP_PRIMARY}"
  RSP_DB="${DB_RSP_PRIMARY}"
else
  RSP_GRID="${GRID_RSP_STANDBY}"
  RSP_DB="${DB_RSP_STANDBY}"
fi
for f in "${RSP_GRID}" "${RSP_DB}"; do
  [[ -f "${f}" ]] && pass "Found: ${f}" || { fail "Missing: ${f}"; (( MISSING++ )) || true; }
done

# ── Script permissions ────────────────────────────────────────────────────────
step "Setting script permissions"
find "${SCRIPT_DIR}/.." -name "*.sh" -exec chmod +x {} \;
pass "All .sh files set executable"

# ── Oracle homes ──────────────────────────────────────────────────────────────
step "Checking Oracle home paths"
[[ -d "${OLD_GRID_HOME}" ]] && pass "OLD_GRID_HOME exists: ${OLD_GRID_HOME}" \
  || fail "OLD_GRID_HOME missing: ${OLD_GRID_HOME}"
[[ -d "${OLD_DB_HOME}" ]]   && pass "OLD_DB_HOME exists: ${OLD_DB_HOME}" \
  || fail "OLD_DB_HOME missing: ${OLD_DB_HOME}"
[[ -d "${NEW_GRID_HOME}" ]] && warn "NEW_GRID_HOME already exists: ${NEW_GRID_HOME} (prep already run?)" \
  || pass "NEW_GRID_HOME not yet created (correct for pre-prep state)"
[[ -d "${NEW_DB_HOME}" ]]   && warn "NEW_DB_HOME already exists: ${NEW_DB_HOME} (prep already run?)" \
  || pass "NEW_DB_HOME not yet created (correct for pre-prep state)"

print_summary "setup/deploy_scripts.sh"
