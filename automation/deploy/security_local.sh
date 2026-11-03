#!/usr/bin/env bash
# =============================================================================
# deploy/security_local.sh — Post-Patch Security Hardening (run on EACH node)
# Run as: root  ON: lnx107 AND lnx113
#
# Incorporates single-node phase6_security.sh:
#   F. Create fips.ora under new DB home ldap/admin (FIPS 140 enforcement)
#   G. Disable extproc by renaming the binary
#
# Run on BOTH nodes independently — security hardening is node-local.
# No outage, no peer interaction required.
#
# Usage:
#   bash deploy/security_local.sh
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
  dry_run_header "security_local.sh"
  drstep "Step F: Configure FIPS 140"
  drcmd  "echo 'SSLFIPS_140=TRUE' > ${NEW_DB_HOME}/ldap/admin/fips.ora"
  drcmd  "chown ${ORACLE_USER}:${INSTALL_GROUP} ${NEW_DB_HOME}/ldap/admin/fips.ora"
  drcmd  "chmod 640 ${NEW_DB_HOME}/ldap/admin/fips.ora"
  echo ""
  drstep "Step G: Disable extproc binary"
  drcmd  "mv ${NEW_DB_HOME}/bin/extproc ${NEW_DB_HOME}/bin/extproc.orig"
  drnote "Disables external procedure calls -- adjust if your environment uses extproc"
  echo "  Run WITHOUT --dry-run to execute."
  echo ""
  set -u
}

THIS_HOST=$(hostname -s)
parse_args "$@"
${DRY_RUN} && { print_dry_run_plan; exit 0; }
${DRY_RUN} && { print_dry_run_plan; exit 0; }
setup_log "security_local"
FAILED=0

section "SECURITY HARDENING: ${THIS_HOST}"
log "DB home: ${NEW_DB_HOME}"

# ── Step F: Create fips.ora (FIPS 140 enforcement) ───────────────────────────
step "Step F: Configure FIPS 140 — create fips.ora"
LDAP_ADMIN_DIR="${NEW_DB_HOME}/ldap/admin"
FIPS_FILE="${LDAP_ADMIN_DIR}/fips.ora"

if [[ ! -d "${LDAP_ADMIN_DIR}" ]]; then
  log "  Creating missing directory: ${LDAP_ADMIN_DIR}"
  mkdir -p "${LDAP_ADMIN_DIR}"
  chown "${ORACLE_USER}:${INSTALL_GROUP}" "${LDAP_ADMIN_DIR}"
  chmod 755 "${LDAP_ADMIN_DIR}"
fi

printf 'SSLFIPS_140=TRUE\n' > "${FIPS_FILE}"
chown "${ORACLE_USER}:${INSTALL_GROUP}" "${FIPS_FILE}"
chmod 640 "${FIPS_FILE}"
log "  fips.ora written:"
ls -l "${FIPS_FILE}"
cat "${FIPS_FILE}" | while read -r l; do log "  ${l}"; done
pass "fips.ora created: ${FIPS_FILE}"

# ── Step G: Disable extproc ───────────────────────────────────────────────────
step "Step G: Disable extproc binary"
EXTPROC_PATH="${NEW_DB_HOME}/bin/extproc"

if [[ -f "${EXTPROC_PATH}" ]]; then
  mv "${EXTPROC_PATH}" "${EXTPROC_PATH}.orig"
  log "  Renamed: extproc → extproc.orig"
  ls -l "${EXTPROC_PATH}.orig"
  pass "extproc disabled"
elif [[ -f "${EXTPROC_PATH}.orig" ]]; then
  log "  extproc already disabled (extproc.orig exists)"
  pass "extproc already disabled"
else
  warn "extproc not found at ${EXTPROC_PATH} — skipping"
fi

# ── Verification ──────────────────────────────────────────────────────────────
step "Verification"
[[ -f "${FIPS_FILE}" ]] && pass "fips.ora present (perms: $(stat -c%a ${FIPS_FILE}))" \
  || fail "fips.ora MISSING"
[[ ! -f "${EXTPROC_PATH}" ]] && pass "extproc disabled" \
  || fail "extproc still active at ${EXTPROC_PATH}"
[[ -f "${EXTPROC_PATH}.orig" ]] && log "  extproc.orig: present" || true

print_summary "security_local"
log ""
log "NEXT: Run aide_local.sh ON ${THIS_HOST} (long-running, use systemd-run)"
log "  systemd-run --unit=dgpatch-aide-local --remain-after-exit bash deploy/aide_local.sh"
log "  tail -f ${LOG_BASE}/${THIS_HOST}/aide_local.log"
