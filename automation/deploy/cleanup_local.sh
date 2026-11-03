#!/usr/bin/env bash
# =============================================================================
# deploy/cleanup_local.sh — Deinstall Old Homes (run on EACH node separately)
# Run as: root  ON: lnx107 AND lnx113 (independently, after validation)
#
# Method (v3): each old home is detached from the Oracle inventory with
#   <new home>/oui/bin/runInstaller -silent -detachHome ORACLE_HOME=<old home>
# run as the owner of that home, and only then are the old directories removed.
# deinstall is not used. If a detach fails, nothing is deleted.
# Interactive: asks you to type YES (start it with: dgrun -t deploy/cleanup_local.sh).
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
  drstep "Detach old homes from the Oracle inventory (nothing is deleted if a detach fails)"
  drcmd  "su - ${ORACLE_USER} -c \"${NEW_DB_HOME}/oui/bin/runInstaller -silent -detachHome ORACLE_HOME=${OLD_DB_HOME}\""
  drcmd  "su - ${GRID_USER} -c \"${NEW_GRID_HOME}/oui/bin/runInstaller -silent -detachHome ORACLE_HOME=${OLD_GRID_HOME}\""
  drnote "Homes already detached (or marked REMOVED in inventory.xml) are skipped"
  echo ""
  drstep "Remove residual directories"
  drcmd  "rm -rf ${OLD_GRID_HOME%/*}  # parent of the old Grid home"
  drcmd  "rm -rf ${OLD_DB_HOME}"
  echo ""
  drstep "Final verification (new homes present, old homes gone, inventory listing)"
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
read -r -p "  Type YES to proceed with the cleanup (detach and remove old homes) on ${THIS_HOST}: " _confirm
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

# ---------------------------------------------------------------------------
# Inventory helpers
INV_LOC="${ORA_INV_LOC:-}"
if [[ -z "${INV_LOC}" ]]; then
  INV_LOC=$(awk -F= '/^inventory_loc/{print $2}' /etc/oraInst.loc 2>/dev/null | tr -d ' ' || true)
fi
INV_LOC="${INV_LOC:-/u01/app/oraInventory}"
INV_XML="${INV_LOC}/ContentsXML/inventory.xml"

# True if the home path is registered in the inventory and not marked REMOVED.
home_in_inventory() {
  grep -F "LOC=\"${1%/}\"" "${INV_XML}" 2>/dev/null | grep -qv 'REMOVED="T"'
}

# detach_home <os_user> <runInstaller path> <old home>
# Runs as the home owner with a clean environment.
detach_home() {
  local user="$1" oui="$2" old="${3%/}"
  if ! home_in_inventory "${old}"; then
    log "  ${old} is not registered in the inventory (already detached) -- skipped"
    return 0
  fi
  [[ -x "${oui}" ]] || { log "  ${oui} not found or not executable"; return 1; }
  log "  ${oui} -silent -detachHome ORACLE_HOME=${old}  (as ${user})"
  su - "${user}" -c "unset ORACLE_HOME ORACLE_SID LD_LIBRARY_PATH; export CV_ASSUME_DISTID=${CV_ASSUME_DISTID:-OEL7.8}; ${oui} -silent -detachHome ORACLE_HOME=${old}" \
    || { log "  detachHome returned non-zero for ${old}"; return 1; }
  if home_in_inventory "${old}"; then
    log "  ${old} is still registered in ${INV_XML} after detachHome"
    return 1
  fi
  log "  Detached from inventory: ${old}"
}

# safe_rm <directory>: refuses anything too broad or containing a new home.
safe_rm() {
  local d="${1%/}"
  case "${d}" in ""|"/"|"/u01"|"/u01/app") log "  refusing to remove '${d}'"; return 1 ;; esac
  case "${NEW_GRID_HOME%/}/" in "${d}/"*) log "  ${d} contains the new Grid home -- not removing"; return 1 ;; esac
  case "${NEW_DB_HOME%/}/"   in "${d}/"*) log "  ${d} contains the new DB home -- not removing";   return 1 ;; esac
  if [[ -d "${d}" ]]; then
    local sz; sz=$(du -sh "${d}" 2>/dev/null | awk '{print $1}' || echo "?")
    log "  Removing ${d} (${sz})..."
    rm -rf "${d}"
  fi
}

# ---------------------------------------------------------------------------
step "Detach old DB home from the inventory: ${OLD_DB_HOME}"
detach_home "${ORACLE_USER}" "${NEW_DB_HOME}/oui/bin/runInstaller" "${OLD_DB_HOME}" \
  && pass "Old DB home detached (or already detached)" \
  || { fail "Could not detach ${OLD_DB_HOME} -- nothing was deleted. Fix and re-run."; exit 1; }

step "Detach old Grid home from the inventory: ${OLD_GRID_HOME}"
detach_home "${GRID_USER}" "${NEW_GRID_HOME}/oui/bin/runInstaller" "${OLD_GRID_HOME}" \
  && pass "Old Grid home detached (or already detached)" \
  || { fail "Could not detach ${OLD_GRID_HOME} -- nothing was deleted. Fix and re-run."; exit 1; }

# ---------------------------------------------------------------------------
step "Remove residual directories"
safe_rm "$(dirname "${OLD_GRID_HOME}")" && pass "Old Grid version directory removed" \
  || { fail "Old Grid directory not removed"; exit 1; }
safe_rm "${OLD_DB_HOME}" && pass "Old DB home directory removed" \
  || { fail "Old DB home directory not removed"; exit 1; }

step "Final verification"
[[ ! -d "${OLD_GRID_HOME}" ]] && pass "Old Grid home removed OK" \
  || fail "Old Grid home still present: ${OLD_GRID_HOME}"
[[ ! -d "${OLD_DB_HOME}" ]] && pass "Old DB home removed OK" \
  || fail "Old DB home still present: ${OLD_DB_HOME}"
[[ -d "${NEW_GRID_HOME}" ]] && pass "New Grid home present OK" \
  || fail "New Grid home missing: ${NEW_GRID_HOME}"
[[ -d "${NEW_DB_HOME}" ]] && pass "New DB home present OK" \
  || fail "New DB home missing: ${NEW_DB_HOME}"

home_in_inventory "${OLD_GRID_HOME}" && fail "Old Grid home still registered in the inventory" \
  || pass "Old Grid home not registered in the inventory"
home_in_inventory "${OLD_DB_HOME}" && fail "Old DB home still registered in the inventory" \
  || pass "Old DB home not registered in the inventory"

log ""
log "Active homes in the inventory (REMOVED homes hidden):"
{ grep -i "HOME NAME" "${INV_XML}" 2>/dev/null | grep -v 'REMOVED="T"' || true; } \
  | while read -r l; do log "  ${l}"; done

DF=$(df -BG /u01 | tail -1 | awk '{print $4}')
log "  /u01 available after cleanup: ${DF}"

print_summary "cleanup_local"
log ""
log "Cleanup complete on ${THIS_HOST}."
log "Run on the other node if not already done:"
log "  bash deploy/cleanup_local.sh"
