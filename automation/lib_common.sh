#!/usr/bin/env bash
# =============================================================================
# lib_common.sh — Shared functions for OOP DG patch scripts
# Version 2 — fixes from trial run 2026-08-21
#
# Changes from v1:
#   - get_dg_lag: fixed grep to capture full "+00 00:00:00" (was truncating to "+00")
#   - Added require_dg_password: secure SYS password prompt (never stored on disk)
#   - Added rundgmgrl_auth: dgmgrl with sys/password@TNS for switchover/switchback
#   - Added run_gi_switch: automates gridSetup.sh -switchGridHome + root.sh sequence
# =============================================================================

: "${PATCH_STAGE_DIR:?lib_common.sh requires patch.conf to be sourced first}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${STEP_LOG:-/dev/null}"; }
warn()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" | tee -a "${STEP_LOG:-/dev/null}"; }
die()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] FATAL: $*" | tee -a "${STEP_LOG:-/dev/null}"; exit 1; }
step()   { echo | tee -a "${STEP_LOG:-/dev/null}"; \
           echo "[$(date '+%Y-%m-%d %H:%M:%S')] -- $* --" | tee -a "${STEP_LOG:-/dev/null}"; }
pass()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')]   OK  PASS: $*" | tee -a "${STEP_LOG:-/dev/null}"; }
fail()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')]   !! FAIL: $*" | tee -a "${STEP_LOG:-/dev/null}"; \
           FAILED=$(( ${FAILED:-0} + 1 )); }
section(){ echo | tee -a "${STEP_LOG:-/dev/null}"; \
           echo "========================================================" \
             | tee -a "${STEP_LOG:-/dev/null}"; \
           echo "  $*" | tee -a "${STEP_LOG:-/dev/null}"; \
           echo "========================================================" \
             | tee -a "${STEP_LOG:-/dev/null}"; }

# ---------------------------------------------------------------------------
# User wrappers
# ---------------------------------------------------------------------------
runora() { su - "${ORACLE_USER}" -c "$1"; }
rungrid(){ su - "${GRID_USER}"   -c "$1"; }

# ---------------------------------------------------------------------------
# runsql <oracle_home> <oracle_sid> <sql>
# ---------------------------------------------------------------------------
runsql() {
  local home="$1" sid="$2" sql="$3"
  su - "${ORACLE_USER}" -c "
    export ORACLE_HOME=${home}
    export ORACLE_SID=${sid}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    \${ORACLE_HOME}/bin/sqlplus -s / as sysdba <<'SQLEOF'
SET PAGESIZE 200 LINESIZE 200 FEEDBACK OFF HEADING ON TRIMOUT ON
${sql}
EXIT;
SQLEOF
"
}

# ---------------------------------------------------------------------------
# rundgmgrl <oracle_home> <command>
# OS authentication — use for read-only status checks only.
# For switchover/switchback use rundgmgrl_auth.
# ---------------------------------------------------------------------------
rundgmgrl() {
  local home="$1" cmd="$2"
  su - "${ORACLE_USER}" -c "
    export ORACLE_HOME=${home}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    ${home}/bin/dgmgrl -silent / \"${cmd}\" 2>&1
  " 2>/dev/null
}

# ---------------------------------------------------------------------------
# require_dg_password
# Ensures DG_SYS_PASSWORD is set. Prompts securely via read -s.
# Never stored in any file — lives in memory for the shell session only.
# Pre-export DG_SYS_PASSWORD before running a script to skip the prompt.
# ---------------------------------------------------------------------------
require_dg_password() {
  if [[ -z "${DG_SYS_PASSWORD:-}" ]]; then
    read -r -s -p "Enter SYS password for DG Broker switchover: " DG_SYS_PASSWORD
    echo
    export DG_SYS_PASSWORD
  fi
}

# ---------------------------------------------------------------------------
# rundgmgrl_auth <oracle_home> <tns_alias> <command>
# Authenticates via sys/password@TNS — required for switchover/switchback.
# DG Broker needs SYSDBA credentials to connect to the remote instance.
# Requires DG_SYS_PASSWORD to be set (call require_dg_password first).
# ---------------------------------------------------------------------------
rundgmgrl_auth() {
  local home="$1" tns="$2" cmd="$3"
  su - "${ORACLE_USER}" -c "
    export ORACLE_HOME=${home}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    ${home}/bin/dgmgrl -silent \"sys/${DG_SYS_PASSWORD}@${tns}\" \"${cmd}\" 2>&1
  " 2>/dev/null
}

# ---------------------------------------------------------------------------
# check_installer_rc <label> <rc> <GridSetupActions|InstallActions>
# gridSetup.sh and runInstaller exit codes: 0 = success, 6 = success with
# optional prerequisite warnings (e.g. [INS-13014]), anything else = failure.
# Returns 0 for 0 and 6, 1 otherwise (caller decides whether to exit).
# Use with:  set +e; <installer call>; RC=$?; set -e
# ---------------------------------------------------------------------------
check_installer_rc() {
  local label="$1" rc="$2" logdir="${3:-InstallActions}"
  local inv; inv=$(awk -F= '/^inventory_loc/{print $2}' /etc/oraInst.loc 2>/dev/null || true)
  inv="${inv:-/u01/app/oraInventory}"
  local lg; lg=$(ls -t "${inv}"/logs/${logdir}*/installActions*.log 2>/dev/null | head -1 || true)
  case "${rc}" in
    0) pass "${label} complete" ;;
    6) warn "${label} finished with warnings (exit code 6) -- continuing"
       log "  [INS-13014] optional prerequisite warnings are expected and harmless."
       log "  Install log: ${lg:-not found}"
       pass "${label} complete (with warnings)" ;;
    *) fail "${label} failed (exit code ${rc})"
       log "  Install log: ${lg:-not found}"
       return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# run_gi_switch <new_grid_home> <response_file> <grid_user>
# Automates gridSetup.sh -switchGridHome + root.sh sequence.
#
# gridSetup.sh -switchGridHome reconfigures CRS references then pauses
# waiting for root to run root.sh. This function:
#   1. Starts gridSetup.sh in background capturing output to a temp log
#   2. Polls the log for the "root.sh" prompt (up to 5 min)
#   3. Runs root.sh (stops old CRS stack, starts from new home)
#   4. Waits for gridSetup.sh to complete
#   5. Verifies ohasd.bin is running from the new home
#
# NOTE: Do NOT use opatchauto for OOP GI home switch. opatchauto applies
# patches in-place; gridSetup.sh -switchGridHome is the correct command
# when the new home was already patched via gridSetup.sh -applyRU during prep.
# ---------------------------------------------------------------------------
run_gi_switch() {
  local new_gh="$1" rsp="$2" grid_user="$3"
  local gs_log; gs_log=$(mktemp /tmp/gs_switch_XXXXXX.log)

  log "  Starting gridSetup.sh -switchGridHome (background)..."
  su - "${grid_user}" -c "
    export CV_ASSUME_DISTID=OEL7.8
    ${new_gh}/gridSetup.sh -switchGridHome -responseFile ${rsp} -silent
  " > "${gs_log}" 2>&1 &
  local gs_pid=$!
  log "  gridSetup.sh PID: ${gs_pid}"

  local elapsed=0
  while (( elapsed < 300 )); do
    if grep -q "root.sh" "${gs_log}" 2>/dev/null; then
      log "  root.sh prompt detected (${elapsed}s) -- proceeding..."
      break
    fi
    if ! kill -0 "${gs_pid}" 2>/dev/null; then
      log "  gridSetup.sh exited early -- running root.sh now"
      break
    fi
    sleep 5
    (( elapsed += 5 ))
  done
  if (( elapsed >= 300 )); then
    log "  Timeout waiting for root.sh prompt -- running root.sh anyway"
  fi

  log "  Executing ${new_gh}/root.sh ..."
  "${new_gh}/root.sh" 2>&1 | while IFS= read -r l; do log "  [root.sh] ${l}"; done
  local root_rc=${PIPESTATUS[0]}

  local gs_rc=0
  wait "${gs_pid}" 2>/dev/null || gs_rc=$?
  case "${gs_rc}" in
    0) log "  gridSetup.sh -switchGridHome exit code: 0" ;;
    6) log "  gridSetup.sh -switchGridHome exit code: 6 (success with warnings)" ;;
    *) warn "gridSetup.sh -switchGridHome exit code: ${gs_rc} -- see output below" ;;
  esac
  while IFS= read -r l; do log "  [gridSetup] ${l}"; done < "${gs_log}"
  rm -f "${gs_log}"

  # Verify new home is active by checking ohasd.bin process path
  local active_bin
  active_bin=$(ps -ef | grep "ohasd.bin" | grep -v grep | awk '{print $8}' || echo "")
  if [[ "${active_bin}" == "${new_gh}/bin/ohasd.bin" ]]; then
    pass "GI home switch confirmed: ohasd.bin running from ${new_gh}"
    return 0
  elif (( root_rc == 0 )); then
    pass "GI home switch complete (root.sh OK)"
    return 0
  else
    warn "GI switch may be incomplete -- verify: ps -ef | grep ohasd.bin"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# verify_node <expected_hostname>
# ---------------------------------------------------------------------------
verify_node() {
  local expected="$1"
  local actual; actual=$(hostname -s)
  [[ "${actual}" == "${expected}" ]] || \
    die "Wrong node. Expected: ${expected}  Actual: ${actual}. Aborting."
  log "Node: ${actual} OK"
}

# ---------------------------------------------------------------------------
# setup_log <script_name>
# ---------------------------------------------------------------------------
setup_log() {
  local name="$1"
  local logdir="${LOG_BASE}/$(hostname -s)"
  mkdir -p "${logdir}"
  chown "${ORACLE_USER}:${INSTALL_GROUP}" "${logdir}" 2>/dev/null || true
  chmod 775 "${logdir}"
  STEP_LOG="${logdir}/${name}.log"
  touch "${STEP_LOG}"
  chown "${ORACLE_USER}:${INSTALL_GROUP}" "${STEP_LOG}" 2>/dev/null || true
  chmod 664 "${STEP_LOG}"
  export STEP_LOG
  log "Log: ${STEP_LOG}"
}

# ---------------------------------------------------------------------------
# check_patches_in_home <home_path> <run_as_user> <patch_id...>
# ---------------------------------------------------------------------------
check_patches_in_home() {
  local home="$1" user="$2"; shift 2
  local patches=("$@")
  local output
  output=$(su - "${user}" -c "
    export ORACLE_HOME=${home}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    \${ORACLE_HOME}/OPatch/opatch lspatches 2>/dev/null
  " 2>/dev/null || echo "OPATCH_FAILED")

  if echo "${output}" | grep -q "OPATCH_FAILED"; then
    fail "opatch lspatches failed in ${home} (as ${user})"
    return 1
  fi

  local all_ok=0
  for pid in "${patches[@]}"; do
    if echo "${output}" | grep -q "${pid}"; then
      pass "Patch ${pid} present in ${home}"
    else
      fail "Patch ${pid} MISSING from ${home}"
      all_ok=1
    fi
  done
  return ${all_ok}
}

# ---------------------------------------------------------------------------
# get_dg_lag <oracle_home> <oracle_sid> <stat_name>
# Returns V$DATAGUARD_STATS value. Empty string if view has no rows (primary).
# FIX v2: grep for full "+00 00:00:00" pattern — previous version truncated
# to "+00" because awk '{print $1}' only captured the first space-delimited
# token, not the full timestamp value "0 00:00:00" which prints as three words.
# ---------------------------------------------------------------------------
get_dg_lag() {
  local home="$1" sid="$2" stat="$3"
  runsql "${home}" "${sid}" \
    "SELECT VALUE FROM V\$DATAGUARD_STATS WHERE NAME='${stat}';" \
    2>/dev/null \
    | grep -v "^$" | grep -v "VALUE\|---" \
    | sed 's/^[[:space:]]*//' | head -1 || echo ""
}

# ---------------------------------------------------------------------------
# print_summary <script_name>
# ---------------------------------------------------------------------------
print_summary() {
  local name="$1"
  local failed="${FAILED:-0}"
  echo
  echo "========================================================"
  if (( failed == 0 )); then
    echo "  RESULT: ALL CHECKS PASSED  [${name}]"
    echo "========================================================"
    return 0
  else
    echo "  RESULT: ${failed} CHECK(S) FAILED  [${name}]"
    echo "  Review: ${STEP_LOG}"
    echo "========================================================"
    return 1
  fi
}

# =============================================================================
# DRY-RUN SUPPORT
# Set DRY_RUN=true (via --dry-run flag) to print plan without executing.
# All variables are expanded to their resolved values from patch.conf.
# =============================================================================

DRY_RUN=${DRY_RUN:-false}

# ---------------------------------------------------------------------------
# parse_args
# Common argument parser. Call at the top of each script's arg section.
# Sets DRY_RUN=true and/or START_STEP=N based on command-line flags.
# ---------------------------------------------------------------------------
parse_args() {
  START_STEP=${START_STEP:-1}
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)    DRY_RUN=true;  export DRY_RUN;  shift ;;
      --from-step)  START_STEP="$2"; shift 2 ;;
      *)            echo "Unknown argument: $1"; exit 1 ;;
    esac
  done
}

should_run() { (( $1 >= START_STEP )); }

# ---------------------------------------------------------------------------
# dry_run_header <script_name>
# Print resolved config values when --dry-run is active.
# ---------------------------------------------------------------------------
dry_run_header() {
  local script="$1"
  echo ""
  echo "=================================================================="
  echo "  DRY-RUN: ${script}"
  echo "  No commands will be executed."
  echo "  All paths and values shown are fully resolved from patch.conf."
  echo "=================================================================="
  echo ""
  echo "  Resolved configuration:"
  printf "    %-30s = %s\n" "THIS_HOST (hostname)"      "$(hostname -s)"
  printf "    %-30s = %s\n" "PRIMARY_HOST"               "${PRIMARY_HOST}"
  printf "    %-30s = %s\n" "STANDBY_HOST"               "${STANDBY_HOST}"
  printf "    %-30s = %s\n" "PRIMARY_SID"                "${PRIMARY_SID}"
  printf "    %-30s = %s\n" "STANDBY_SID"                "${STANDBY_SID}"
  printf "    %-30s = %s\n" "PRIMARY_DB_UNIQUE_NAME"     "${PRIMARY_DB_UNIQUE_NAME}"
  printf "    %-30s = %s\n" "STANDBY_DB_UNIQUE_NAME"     "${STANDBY_DB_UNIQUE_NAME}"
  printf "    %-30s = %s\n" "OLD_PATCH_LEVEL"            "${OLD_PATCH_LEVEL}"
  printf "    %-30s = %s\n" "NEW_PATCH_LEVEL"            "${NEW_PATCH_LEVEL}"
  printf "    %-30s = %s\n" "OLD_GRID_HOME"              "${OLD_GRID_HOME}"
  printf "    %-30s = %s\n" "NEW_GRID_HOME"              "${NEW_GRID_HOME}"
  printf "    %-30s = %s\n" "OLD_DB_HOME"                "${OLD_DB_HOME}"
  printf "    %-30s = %s\n" "NEW_DB_HOME"                "${NEW_DB_HOME}"
  printf "    %-30s = %s\n" "ORACLE_BASE"                "${ORACLE_BASE}"
  printf "    %-30s = %s\n" "ADR_BASE"                   "${ADR_BASE}"
  printf "    %-30s = %s\n" "PATCH_STAGE_DIR"            "${PATCH_STAGE_DIR}"
  printf "    %-30s = %s\n" "PATCH_DIR"                  "${PATCH_DIR}"
  printf "    %-30s = %s\n" "AUTOUPGRADE_JAR"            "${AUTOUPGRADE_JAR}"
  printf "    %-30s = %s\n" "GRID_RSP_PRIMARY"           "${GRID_RSP_PRIMARY}"
  printf "    %-30s = %s\n" "GRID_RSP_STANDBY"           "${GRID_RSP_STANDBY}"
  printf "    %-30s = %s\n" "LOG_BASE"                   "${LOG_BASE}"
  printf "    %-30s = %s\n" "GI_APPLY_RU_PATCH"          "${GI_APPLY_RU_PATCH}"
  printf "    %-30s = %s\n" "DB_APPLY_RU_PATCH"          "${DB_APPLY_RU_PATCH}"
  printf "    %-30s = %s\n" "GI_APPLY_RU_PATH"           "${GI_APPLY_RU_PATH}"
  printf "    %-30s = %s\n" "DB_APPLY_RU_PATH"           "${DB_APPLY_RU_PATH}"
  printf "    %-30s = %s\n" "ORACLE_USER"                "${ORACLE_USER}"
  printf "    %-30s = %s\n" "GRID_USER"                  "${GRID_USER}"
  printf "    %-30s = %s\n" "INSTALL_GROUP"              "${INSTALL_GROUP}"
  echo ""
  echo "  Execution plan:"
  echo ""
}

# ---------------------------------------------------------------------------
# drstep <description>  — print a dry-run step header
# drcmd  <command>      — print a command that would be executed
# drnote <note>         — print an informational note
# ---------------------------------------------------------------------------
drstep() { echo "  Step: $*"; }
drcmd()  { echo "    \$ $*"; }
drnote() { echo "    # $*"; }
