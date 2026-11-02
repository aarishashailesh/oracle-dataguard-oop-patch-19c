#!/usr/bin/env bash
# =============================================================================
# deploy/cleanup_local.sh — Deinstall Old Homes (run on EACH node separately)
# Run as: root  ON: lnx107 AND lnx113 (independently, after validation)
#
# Changes from v1:
#   - Deinstall uses -checkonly to generate paramfile, then -silent -paramfile
#     for a clean deinstall with proper oraInventory cleanup. Falls back to
#     rm -rf if deinstall fails (same net result, stale inventory entries removed
#     via detachHome).
#   - Added runInstaller -silent -detachHome to remove stale inventory entries
#     for both old homes after directory removal.
#
# WARNING: IRREVERSIBLE. Only run after validate_local.sh + validate_peer.sh
# have both passed AND post_install_local.sh is confirmed on both nodes.
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
  dry_run_header "cleanup_local.sh"
  drstep "Safety checks"
  drcmd  "${NEW_GRID_HOME}/bin/crsctl query crs releasepatch | grep ${NEW_PATCH_LEVEL}"
  drcmd  "test -d ${NEW_GRID_HOME}"
  drcmd  "test -d ${NEW_DB_HOME}"
  echo ""
  drstep "Reset permissions on old homes"
  drcmd  "chmod -R 775 ${OLD_GRID_HOME}/"
  drcmd  "chmod -R 775 ${OLD_DB_HOME}/"
  echo ""
  drstep "Deinstall old Grid home: ${OLD_GRID_HOME}"
  drcmd  "su - ${GRID_USER} -c \"${OLD_GRID_HOME}/deinstall/deinstall -silent -checkonly -o <paramfile>\""
  drcmd  "su - ${GRID_USER} -c \"${OLD_GRID_HOME}/deinstall/deinstall -silent -paramfile <paramfile>\""
  echo ""
  drstep "Deinstall old DB home: ${OLD_DB_HOME}"
  drcmd  "su - ${ORACLE_USER} -c \"${OLD_DB_HOME}/deinstall/deinstall -silent -checkonly -o <paramfile>\""
  drcmd  "su - ${ORACLE_USER} -c \"${OLD_DB_HOME}/deinstall/deinstall -silent -paramfile <paramfile>\""
  echo ""
  drstep "Remove residual directories"
  drcmd  "rm -rf ${OLD_GRID_HOME%/*}  # removes /u01/app/${OLD_PATCH_LEVEL}"
  drcmd  "rm -rf ${OLD_DB_HOME}       # removes ${OLD_DB_HOME}"
  echo ""
  drstep "Clean oraInventory entries"
  drcmd  "${NEW_DB_HOME}/oui/bin/runInstaller -silent -detachHome -homeName <OLD_GRID_HOME_NAME> -invPtrLoc /etc/oraInst.loc"
  drcmd  "${NEW_DB_HOME}/oui/bin/runInstaller -silent -detachHome -homeName <OLD_DB_HOME_NAME>   -invPtrLoc /etc/oraInst.loc"
  drnote "Home names detected dynamically from inventory.xml at runtime"
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

THIS_HOST=$(hostname -s)
parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
setup_log "cleanup_local"
FAILED=0

section "OLD HOME CLEANUP: ${THIS_HOST} -- IRREVERSIBLE"
log "Old Grid home: ${OLD_GRID_HOME}"
log "Old DB home  : ${OLD_DB_HOME}"
log ""
log "Prerequisites:"
log "  OK validate_local.sh passed on ${PRIMARY_HOST}"
log "  OK validate_peer.sh passed on ${STANDBY_HOST}"
log "  OK post_install_local.sh passed on this node"

echo ""
read -r -p "  Type YES to proceed with deinstall on ${THIS_HOST}: " _confirm
if [[ "${_confirm}" != "YES" ]]; then
  log "Cleanup aborted by operator."
  exit 0
fi

step "Safety checks"
ACTIVE_GI=$("${NEW_GRID_HOME}/bin/crsctl" query crs releasepatch 2>/dev/null \
  | grep -c "${NEW_PATCH_LEVEL}" || echo "0")
(( ACTIVE_GI > 0 )) || { fail "New Grid home not confirmed active at ${NEW_PATCH_LEVEL}"; exit 1; }
pass "New Grid home active at ${NEW_PATCH_LEVEL}"
[[ -d "${NEW_GRID_HOME}" ]] && pass "New Grid home exists: ${NEW_GRID_HOME}" \
  || { fail "New Grid home missing: ${NEW_GRID_HOME}"; exit 1; }
[[ -d "${NEW_DB_HOME}" ]] && pass "New DB home exists: ${NEW_DB_HOME}" \
  || { fail "New DB home missing: ${NEW_DB_HOME}"; exit 1; }

step "Reset permissions on old homes"
if [[ -d "${OLD_GRID_HOME}" ]]; then
  chmod -R 775 "${OLD_GRID_HOME}/" 2>/dev/null || true
  chown -R "${GRID_USER}:${INSTALL_GROUP}" "${OLD_GRID_HOME}/" 2>/dev/null || true
  pass "Old Grid home permissions reset"
fi
if [[ -d "${OLD_DB_HOME}" ]]; then
  chmod -R 775 "${OLD_DB_HOME}/" 2>/dev/null || true
  chown -R "${ORACLE_USER}:${INSTALL_GROUP}" "${OLD_DB_HOME}/" 2>/dev/null || true
  pass "Old DB home permissions reset"
fi

# ---------------------------------------------------------------------------
step "Deinstall old Grid home: ${OLD_GRID_HOME}"
if [[ -d "${OLD_GRID_HOME}" ]]; then
  GRID_DEINSTALL_RSP=$(mktemp /tmp/grid_deinstall_XXXXXX.rsp)
  # Generate paramfile silently
  su - "${GRID_USER}" -c "
    export CV_ASSUME_DISTID=OEL7.8
    export ORACLE_HOME=${OLD_GRID_HOME}
    ${OLD_GRID_HOME}/deinstall/deinstall -silent -checkonly \
      -paramfile /dev/null -o ${GRID_DEINSTALL_RSP} 2>/dev/null
  " 2>/dev/null || true

  if [[ -s "${GRID_DEINSTALL_RSP}" ]]; then
    su - "${GRID_USER}" -c "
      export CV_ASSUME_DISTID=OEL7.8
      export ORACLE_HOME=${OLD_GRID_HOME}
      echo 'y' | ${OLD_GRID_HOME}/deinstall/deinstall \
        -silent -paramfile ${GRID_DEINSTALL_RSP} 2>&1
    " && pass "Old Grid home deinstalled cleanly" \
      || warn "Grid deinstall returned non-zero"
  else
    log "  Could not generate deinstall paramfile -- proceeding with directory removal"
  fi
  rm -f "${GRID_DEINSTALL_RSP}"
fi

# ---------------------------------------------------------------------------
step "Deinstall old DB home: ${OLD_DB_HOME}"
if [[ -d "${OLD_DB_HOME}" ]]; then
  DB_DEINSTALL_RSP=$(mktemp /tmp/db_deinstall_XXXXXX.rsp)
  su - "${ORACLE_USER}" -c "
    export CV_ASSUME_DISTID=OEL7.8
    export ORACLE_HOME=${OLD_DB_HOME}
    ${OLD_DB_HOME}/deinstall/deinstall -silent -checkonly \
      -paramfile /dev/null -o ${DB_DEINSTALL_RSP} 2>/dev/null
  " 2>/dev/null || true

  if [[ -s "${DB_DEINSTALL_RSP}" ]]; then
    su - "${ORACLE_USER}" -c "
      export CV_ASSUME_DISTID=OEL7.8
      export ORACLE_HOME=${OLD_DB_HOME}
      echo 'y' | ${OLD_DB_HOME}/deinstall/deinstall \
        -silent -paramfile ${DB_DEINSTALL_RSP} 2>&1
    " && pass "Old DB home deinstalled cleanly" \
      || warn "DB deinstall returned non-zero"
  else
    log "  Could not generate deinstall paramfile -- proceeding with directory removal"
  fi
  rm -f "${DB_DEINSTALL_RSP}"
fi

# ---------------------------------------------------------------------------
step "Remove residual directories"
OLD_GRID_PARENT=$(dirname "${OLD_GRID_HOME}")
if [[ -d "${OLD_GRID_PARENT}" && "${OLD_GRID_PARENT}" != "/" ]]; then
  SIZE=$(du -sh "${OLD_GRID_PARENT}" 2>/dev/null | awk '{print $1}' || echo "?")
  log "  Removing ${OLD_GRID_PARENT} (${SIZE})..."
  rm -rf "${OLD_GRID_PARENT}"
  pass "Old Grid version directory removed"
fi
if [[ -d "${OLD_DB_HOME}" ]]; then
  SIZE=$(du -sh "${OLD_DB_HOME}" 2>/dev/null | awk '{print $1}' || echo "?")
  log "  Removing ${OLD_DB_HOME} (${SIZE})..."
  rm -rf "${OLD_DB_HOME}"
  pass "Old DB home directory removed"
fi

# ---------------------------------------------------------------------------
step "Clean oraInventory entries for removed homes"
# Detect actual home names from inventory before detachHome.
# Home names vary by environment -- do not hardcode them.
INV_PTR="/etc/oraInst.loc"
INV_LOC="${ORA_INV_LOC}"
if [[ -z "${INV_LOC}" ]]; then
  INV_LOC=$(grep "inventory_loc" /etc/oraInst.loc 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo "")
fi
ORA_INV_XML="${INV_LOC}/ContentsXML/inventory.xml"
OUI="${NEW_DB_HOME}/oui/bin/runInstaller"

if [[ -x "${OUI}" && -f "${ORA_INV_XML}" ]]; then
  # Detect old Grid home name from inventory XML
  OLD_GRID_NAME=$(grep "LOC="${OLD_GRID_HOME}"" "${ORA_INV_XML}" 2>/dev/null     | grep -o 'NAME="[^"]*"' | head -1 | sed 's/NAME=//;s/"//g' || echo "")
  # Detect old DB home name from inventory XML
  OLD_DB_NAME=$(grep "LOC="${OLD_DB_HOME}"" "${ORA_INV_XML}" 2>/dev/null     | grep -o 'NAME="[^"]*"' | head -1 | sed 's/NAME=//;s/"//g' || echo "")

  for HOME_NAME in "${OLD_GRID_NAME}" "${OLD_DB_NAME}"; do
    [[ -z "${HOME_NAME}" ]] && continue
    "${OUI}" -silent -detachHome -homeName "${HOME_NAME}" \
      -invPtrLoc "${INV_PTR}" 2>/dev/null \
      && log "  Detached inventory entry: ${HOME_NAME}" \
      || log "  ${HOME_NAME}: detach returned non-zero (may already be removed)"
  done
  pass "oraInventory cleanup attempted"
else
  warn "runInstaller or inventory.xml not found -- inventory may have stale entries"
fi

# ---------------------------------------------------------------------------
step "Final verification"
[[ ! -d "${OLD_GRID_HOME}" ]] && pass "Old Grid home removed OK" \
  || fail "Old Grid home still present: ${OLD_GRID_HOME}"
[[ ! -d "${OLD_DB_HOME}" ]] && pass "Old DB home removed OK" \
  || fail "Old DB home still present: ${OLD_DB_HOME}"
[[ -d "${NEW_GRID_HOME}" ]] && pass "New Grid home present OK" \
  || fail "New Grid home missing: ${NEW_GRID_HOME}"
[[ -d "${NEW_DB_HOME}" ]] && pass "New DB home present OK" \
  || fail "New DB home missing: ${NEW_DB_HOME}"

log ""
log "oraInventory after cleanup:"
grep -o 'LOC="[^"]*"' /u01/app/oraInventory/ContentsXML/inventory.xml 2>/dev/null \
  | while read -r l; do log "  ${l}"; done || true

DF=$(df -BG /u01 | tail -1 | awk '{print $4}')
log "  /u01 available after cleanup: ${DF}"

print_summary "cleanup_local"
log ""
log "Cleanup complete on ${THIS_HOST}."
log "Run on the other node if not already done:"
log "  bash deploy/cleanup_local.sh"
