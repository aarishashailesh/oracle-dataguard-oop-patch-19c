[README.md](https://github.com/user-attachments/files/34351097/README.md)
[README.md](https://github.com/user-attachments/files/34350969/README.md)
[README.md](https://github.com/user-attachments/files/34301954/README.md)
# Oracle 19c Data Guard OOP Patch Automation

Out-of-place (OOP) patching of Oracle 19c Grid Infrastructure and Database
in a two-node Data Guard environment using a standby-first, DG Broker switchover
strategy. Scripts run as root with internal su switching to oracle/grid users.# Oracle 19c Data Guard OOP Patch Automation

Out-of-place (OOP) patching of Oracle 19c Grid Infrastructure and Database
in a two-node Data Guard environment using a standby-first, DG Broker switchover
strategy. Scripts run as root with internal su switching to oracle/grid users.
No passwordless SSH between nodes is required.

---

## Adapting to a New Environment

**Only patch.conf requires editing.** No values are hardcoded in any script.
All scripts source patch.conf at startup.

### Section 1 — Patch Identity (edit every patch cycle)

```bash
NEW_PATCH_LEVEL="19.32"       # target RU level
OLD_PATCH_LEVEL="19.3"        # current installed level

RU_COMBO_PATCH="39618711"     # outer combo zip patch number
GI_RU_PATCH="39467003"        # GI bundle directory inside combo
GI_APPLY_RU_PATCH="39526364"  # OCW sub-patch shown in opatch lspatches
GI_ONEOFF_PATCHES="..."       # comma-separated patches inside GI_RU_PATCH
DB_APPLY_RU_PATCH="39472050"  # DB RU sub-patch shown in opatch lspatches
DB_ONEOFF_PATCHES="..."       # comma-separated patches inside GI_RU_PATCH
DB_RU_STANDALONE_PATCH="..."  # standalone DB patch (e.g. Datapump bundle)
DB_RU_STANDALONE_ZIP="..."    # filename of standalone DB patch zip
RU_COMBO_TOPLEVEL_PATCHES="..." # patches at combo root level (e.g. OJVM)
OPATCH_PATCH="6880880"        # OPatch patch number (rarely changes)
```

**How to find these values for a new RU:**
1. Download the RU combo zip from MOS. Extract it.
2. The outer directory name is `RU_COMBO_PATCH`.
3. Inside the combo, find the GI bundle directory: `RU_COMBO_PATCH/GI_RU_PATCH/`.
4. Inside the GI bundle, the OCW patch is `GI_APPLY_RU_PATCH`. Other directories are `GI_ONEOFF_PATCHES`.
5. The DB RU patch inside the GI bundle is `DB_APPLY_RU_PATCH`.
6. Patches at the combo root level (not inside the GI bundle) are `RU_COMBO_TOPLEVEL_PATCHES` (e.g. OJVM).
7. Check My Oracle Support for any standalone DB patches required for the RU (e.g. Datapump bundle).

### Section 2 — Node Identity (edit for each environment)

```bash
PRIMARY_HOST="lnx107"               # hostname -s of primary node
PRIMARY_IP="192.168.1.107"         # primary IP address (reference only)
PRIMARY_DB_UNIQUE_NAME="CDBPRIM"   # DB_UNIQUE_NAME (from v$database)
PRIMARY_SID="CDBPRIM"              # ORACLE_SID of primary instance

STANDBY_HOST="lnx113"              # hostname -s of standby node
STANDBY_IP="192.168.1.113"        # standby IP address (reference only)
STANDBY_DB_UNIQUE_NAME="CDBSTBY"  # DB_UNIQUE_NAME (from v$database)
STANDBY_SID="CDBSTBY"             # ORACLE_SID of standby instance
```

### Section 3 — Home Paths (edit for each environment and each patch cycle)

```bash
OLD_GRID_HOME="/u01/app/19.0.0/grid"
NEW_GRID_HOME="/u01/app/19.32.0/grid"

OLD_DB_HOME="/u01/app/oracle/product/19.0.0/dbhome_1"
NEW_DB_HOME="/u01/app/oracle/product/19.0.0/dbhome_1932"
```

**Naming conventions:**
- Grid home path: `<GRID_BASE>/<version>/grid` e.g. `/u01/app/19.32.0/grid`
- DB home path: `<ORACLE_BASE>/product/<oracle_version>/<home_name>` e.g. `dbhome_1932`

To find current active home paths:
```bash
su - grid   -c "env | grep ORACLE_HOME"   # current Grid home
su - oracle -c "env | grep ORACLE_HOME"   # current DB home
srvctl config database -d <DB_UNIQUE_NAME> | grep "Oracle home"
```

### Section 4 — Oracle Base and ADR (edit for each environment)

```bash
ORACLE_BASE="/u01/app/oracle"   # Oracle software owner base directory
GRID_BASE="/u01/app/grid"      # Grid Infrastructure base directory
ADR_BASE="${ORACLE_BASE}/diag" # Automatic Diagnostic Repository base
```

`ADR_BASE` must be owned by `oracle:oinstall`. If it is owned by `grid`,
AutoUpgrade analyze fails with COM-115 (kfod ADR initialization error).
The deploy scripts fix this automatically, but verify before running:
```bash
ls -la /u01/app/oracle/ | grep diag
```

### Section 5 — Patch Staging (edit for each environment)

```bash
PATCH_STAGE_DIR="/u01/patching/stage"
PATCH_DIR="${PATCH_STAGE_DIR}/1932"        # versioned subdirectory
```

The `PATCH_DIR` subdirectory name is typically the RU level (e.g. `1932` for 19.32).
Update it to match where you stage the new RU zip files.

### Section 8 — OS and Install Settings (edit for each environment)

```bash
CV_ASSUME_DISTID="OEL7.8"   # Use OEL7.8 for Oracle Linux 8 (required by installer)
GRID_USER="grid"              # OS user owning Grid Infrastructure
ORACLE_USER="oracle"          # OS user owning Oracle Database
INSTALL_GROUP="oinstall"      # Primary group (must include both grid and oracle)
```

---

## Stage Directory Layout

The following files must be present on **both nodes** at identical paths
before running `setup/deploy_scripts.sh`:

```
/u01/patching/stage/               (PATCH_STAGE_DIR)
  base_releases/                   (BASE_DIR)
    LINUX.X64_193000_grid_home.zip
    LINUX.X64_193000_db_home.zip
  1932/                            (PATCH_DIR -- name matches RU level)
    p39618711_190000_Linux-x86-64.zip    (RU combo zip)
    p39657094_1932000DBRU_Generic.zip    (standalone DB patch)
    autoupgrade.jar                       (latest from MOS 2485457.1)
    opatch/
      p6880880_190000_Linux-x86-64.zip   (OPatch zip)
  rsp/
    <primary_host>_grid_install.rsp      (primary node GI response file)
    <primary_host>_db_install.rsp        (primary node DB response file)
    <standby_host>_grid_install.rsp      (standby node GI response file)
    <standby_host>_db_install.rsp        (standby node DB response file)
```

**Response files** must be the original install response files from when
Grid Infrastructure and Oracle Database were first installed on each node.
They must have `oracle.install.option` set to the original install option
(e.g. `CRS_CONFIG` for GI). The prep scripts derive a `CRS_SWONLY` copy
at runtime via sed — do not pre-modify the response files.

To obtain response files if the originals are unavailable:
```bash
# Regenerate from an existing installation:
$GRID_HOME/gridSetup.sh -silent -recordConfigInfo -responseFile /tmp/grid_record.rsp
$ORACLE_HOME/runInstaller -silent -recordConfigInfo -responseFile /tmp/db_record.rsp
```

---

## Prerequisites Before Running

Verify all of these before `setup/deploy_scripts.sh`:

### 1. DG Broker health
```bash
su - oracle -c "dgmgrl / 'show configuration'"
# Must show: Configuration Status: SUCCESS
```

### 2. Switchover works via dgmgrl
```bash
su - oracle -c "dgmgrl sys/<password>@<PRIMARY_DB_UNIQUE_NAME> 'validate database <STANDBY_DB_UNIQUE_NAME>'"
# Ready for Switchover: Yes
```

### 3. Password files are in sync on both nodes
DG Broker requires matching SYS passwords to connect to the remote instance
during switchover. Verify:
```bash
# md5sums must match:
md5sum $OLD_DB_HOME/dbs/orapw<PRIMARY_SID>    # on primary
md5sum $OLD_DB_HOME/dbs/orapw<STANDBY_SID>   # on standby
```
If they differ, copy the primary password file to the standby:
```bash
scp $OLD_DB_HOME/dbs/orapw<PRIMARY_SID> \
    root@<STANDBY_HOST>:$OLD_DB_HOME/dbs/orapw<STANDBY_SID>
ssh root@<STANDBY_HOST> "chown oracle:oinstall \
    $OLD_DB_HOME/dbs/orapw<STANDBY_SID> && chmod 640 \
    $OLD_DB_HOME/dbs/orapw<STANDBY_SID>"
```
After any `ALTER USER SYS IDENTIFIED BY` on the primary, repeat the copy.

### 4. Static listener service for DG Broker on standby
The standby listener.ora must have a static SID entry for the Broker's
connect identifier. Check:
```bash
grep -i "DGMGRL\|SID_LIST" $OLD_GRID_HOME/network/admin/listener.ora
# on standby node
```
Required entry format:
```
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = <STANDBY_DB_UNIQUE_NAME>_DGMGRL)
      (ORACLE_HOME = <OLD_DB_HOME>)
      (SID_NAME = <STANDBY_SID>)
    )
  )
```

### 5. StaticConnectIdentifier for DG Broker
```bash
dgmgrl / "show database verbose <STANDBY_DB_UNIQUE_NAME>" | grep StaticConnect
# Must point to standby VIP:1521 with correct SERVICE_NAME
```

### 6. SYSDG grant
```bash
# On primary, as sysdba:
GRANT SYSDG TO SYS;  -- updates password file automatically
```

### 7. Disk space
Minimum 30 GB free on /u01 (or wherever homes are installed) on each node:
```bash
df -BG /u01
```

---

## Execution Sequence

Every step below is started with `dgrun` (defined in the next section) so that it survives hardened
session settings (`KillUserProcesses=yes`, 600 s idle logout, `TMOUT=600`). Run each step on the host
shown, as root, from the automation directory. Wait for `Result=success` (see "Watching a step")
before starting the next step. Scripts that prompt (SYS password, or YES in the cleanup) use `dgrun -t` (interactive).

### Running steps with systemd-run (hardened hosts)

`nohup` and `&` die with the login session on these hosts, because logind kills the whole session scope.
`systemd-run` starts the script as a transient system service owned by PID 1, outside your session, so
logout and idle timeouts cannot kill it. Tested on a hardened host: a service running
`su - oracle -c 'sleep 700'` finished with `rc=0` after the PuTTY session was killed at 600 s.
`enable-linger` is not needed (it only applies to `systemd-run --user`).

Define this once per login on each node (root):
```bash
cd /u01/patching/automation          # directory that holds patch.conf, lib_common.sh, prep/, deploy/ ...
dgprocs() {   # usage: dgprocs <unit name without .service>   processes still running in the unit (sub-cgroups included)
  local u="$1.service" d n=0 t
  for d in "/sys/fs/cgroup/systemd/system.slice/${u}" "/sys/fs/cgroup/system.slice/${u}"; do
    if [[ -d "$d" ]]; then n=$(find "$d" -name cgroup.procs -exec cat {} + 2>/dev/null | wc -l); break; fi
  done
  t=$(systemctl show -p TasksCurrent "${u}" 2>/dev/null | cut -d= -f2)      # also trust systemd's own task count
  if [[ "$t" =~ ^[0-9]+$ ]] && (( ${#t} < 10 )) && (( t > n )); then n=$t; fi
  echo "${n}"
}
dgrun() {
  # usage: dgrun [-t] <script path relative to this dir> [script args, e.g. --dry-run or --from-step 6]
  local tty=0; [[ "$1" == "-t" ]] && { tty=1; shift; }
  local script="$1"; shift
  local unit="dgpatch-$(basename "${script}" .sh | tr _ -)"
  if systemctl is-active --quiet "${unit}" && (( $(dgprocs "${unit}") > 0 )); then
    # Steps that start Oracle (deploy, switchover) leave the instance inside the unit. Never stop such a unit.
    unit="${unit}-$(date +%H%M%S)"
    echo "Previous unit still owns running processes; using new unit name ${unit}"
  else
    systemctl stop "${unit}" 2>/dev/null || true             # clear a finished unit of the same name
    systemctl reset-failed "${unit}" 2>/dev/null || true
  fi
  if (( tty )); then                                          # interactive (password prompt)
    if systemd-run --help 2>&1 | grep -q -- '--pty'; then    # systemd 235 or newer
      systemd-run --pty --unit="${unit}" -p KillMode=process --remain-after-exit bash "$(pwd)/${script}" "$@"
    else                                                      # older systemd (e.g. OL7): foreground scope
      systemd-run --scope --unit="${unit}" bash "$(pwd)/${script}" "$@"
    fi
  else                                                        # background service
    systemd-run --unit="${unit}" -p KillMode=process --remain-after-exit bash "$(pwd)/${script}" "$@"
  fi
}
dgstat() {    # usage: dgstat <script name without path, e.g. prep_s_local>
  local unit="dgpatch-$(echo "$1" | tr _ -)"
  systemctl show "${unit}" -p ActiveState -p Result -p ExecMainStatus
  echo "ProcessesInUnit=$(dgprocs "${unit}")"
}
dgclean() {   # stop finished dgpatch units, but keep any unit that still owns running processes
  local u n
  for u in $(systemctl list-units 'dgpatch-*' --all --plain --no-legend | awk '{print $1}'); do
    n=$(dgprocs "${u%.service}")
    if (( n == 0 )); then systemctl stop "${u}" && echo "stopped ${u}"; else echo "kept ${u} (${n} processes still running in it)"; fi
  done
}
```
- Plain `dgrun` runs in the background and returns at once. Use it for every step that does not ask a question.
- `dgrun -t` uses `systemd-run --pty` (or `systemd-run --scope` on systemd older than 235): the script still
  runs outside your session scope, but it is attached to your terminal so you can type the SYS password. Use it only for `switchtest_local.sh`, `switchover_local.sh`,
  `switchback_local.sh` (SYS password) and `cleanup_local.sh` (asks you to type YES). If your terminal drops, a `--pty` job is hung up, so keep it attended and
  short (a few minutes each).
- Old systemd (for example OL7, v219) has no `--working-directory` and no `--pty`. `dgrun` does not use
  `--working-directory` (the scripts find their own directory), and it falls back to `--scope` for `-t`.
  Check with `systemctl --version | head -1`.
- Do not pass the SYS password with `--setenv` or `-p Environment=`. Anyone can read unit environments with
  `systemctl show`, and the scripts promise never to expose the password.

### Do not `systemctl stop` a unit that still owns processes
Steps that start or restart Oracle (`deploy_*`, `switchover_*`, `switchback_*`) leave the instance and its
background processes in the unit's cgroup, even after the script has exited. `systemctl status` then shows
`Tasks:` and `Memory:` for an `active (exited)` unit. Stopping that unit kills the database.
`dgrun` therefore starts units with `-p KillMode=process` (a stop signals only the already finished main
process) and, when the previous unit still owns processes, starts the new run under a time-stamped unit name
instead of stopping it. Use `dgclean` to clear finished units, `dgprocs <unit>` to see how many processes a
unit owns, and never `systemctl stop 'dgpatch-*'` on a host where a deploy or switch step has run.

### Watching a step (safe to repeat after a reconnect)
```bash
tail -n 50 /u01/patching/logs/logs1933/$(hostname -s)/<script name>.log    # LOG_BASE in patch.conf
systemctl status dgpatch-<unit> --no-pager                                 # running, or exited
dgstat <script name>                                                       # Result=success ExecMainStatus=0 when done
journalctl -u dgpatch-<unit> --no-pager | tail -n 50                       # anything printed to the console
dgclean                                                                    # clear finished units (keeps any that still own processes)
```
`Result=exit-code` with a non-zero `ExecMainStatus` means the step failed: read the script log first.
Do not sit in a foreground `tail -f` for more than 10 minutes, because `TMOUT` will log you out
(the step keeps running).

### Phase 0 - Setup (both nodes, once per cycle)
```bash
bash setup/deploy_scripts.sh           # ON PRIMARY_HOST, then ON STANDBY_HOST (short; foreground is fine)
```
Both must print: `RESULT: ALL CHECKS PASSED`

### Phase 1 - Prep (both nodes in parallel, no downtime, about 90 min each)
```bash
dgrun prep/prep_s_local.sh             # ON STANDBY_HOST   unit dgpatch-prep-s-local
dgrun prep/prep_p_local.sh             # ON PRIMARY_HOST   unit dgpatch-prep-p-local
dgrun prep/prep_verify_peer.sh         # ON PRIMARY_HOST   after both prep units show Result=success
```
`gridSetup.sh` and `runInstaller` exit code 6 (success with optional prerequisite warnings, INS-13014) is
accepted. Any other non-zero code stops the script.

### Phase 2 - Switch test (optional, strongly recommended, about 2 min outage)
```bash
dgrun -t switch_test/switchtest_local.sh     # ON PRIMARY_HOST  (prompts for the SYS password)
dgrun switch_test/switchtest_peer.sh         # ON STANDBY_HOST
```

### Phase 3 - Deploy (maintenance window)
```bash
# 1. Patch the standby home (no production impact):
dgrun deploy/deploy_s_local.sh               # ON STANDBY_HOST   unit dgpatch-deploy-s-local
# 2. Verify standby patched and primary healthy. When all checks pass it also DISABLES
#    SYS.DB_DDL_ALERT_TRG on the primary (db/cdb/pdb); it replicates to the standby via redo:
dgrun deploy/deploy_s_peer.sh                # ON PRIMARY_HOST
# 3. SWITCHOVER (production downtime starts):
dgrun -t deploy/switchover_local.sh          # ON PRIMARY_HOST   (prompts for the SYS password)
dgrun deploy/switchover_peer.sh              # ON STANDBY_HOST   only if the broker path failed
# 4. Patch the old primary home (now standby):
dgrun deploy/deploy_p_local.sh               # ON PRIMARY_HOST   unit dgpatch-deploy-p-local
# 5. Verify redo flows to the old primary:
dgrun deploy/deploy_p_peer.sh                # ON STANDBY_HOST   (current primary)
# 6. Data dictionary patches (15-30 min):
dgrun deploy/datapatch_peer.sh               # ON STANDBY_HOST   (current primary)
# 7. Verify redo applied on the old primary:
dgrun deploy/datapatch_local.sh              # ON PRIMARY_HOST
# 8. SWITCHBACK (production downtime ends):
dgrun -t deploy/switchback_local.sh          # ON PRIMARY_HOST   (prompts for the SYS password)
dgrun deploy/switchback_peer.sh              # ON STANDBY_HOST   only if the broker path failed
```

### Phase 4 - Validation
```bash
dgrun deploy/validate_local.sh               # ON PRIMARY_HOST
dgrun deploy/validate_peer.sh                # ON STANDBY_HOST
```

### Phase 5 - Post-patch hardening (both nodes, no downtime)
```bash
dgrun deploy/post_install_local.sh           # ON PRIMARY_HOST, then ON STANDBY_HOST   (chopt, utlrp, registry; primary also
                                             #   ENABLES SYS.DB_DDL_ALERT_TRG again in Step G)
dgrun deploy/security_local.sh               # ON PRIMARY_HOST, then ON STANDBY_HOST   (FIPS, extproc)
dgrun -t deploy/cleanup_local.sh             # ON PRIMARY_HOST, then ON STANDBY_HOST   (asks YES; detach + remove old homes, opt-in)
dgrun deploy/aide_local.sh                   # ON PRIMARY_HOST, then ON STANDBY_HOST   (about 60 min)
```

### Using the runbook (`dg_patch_runbook.sh`)
The runbook prints the exact `systemd-run` command for the background steps (prep and AIDE) and
for peer steps. It still runs some local steps in the foreground (for example phases 10, 18 and 21). On a
hardened host, run any long step yourself with `dgrun` and continue the runbook with `--from-phase <n+1>`.

### Dry run any step
```bash
dgrun deploy/deploy_s_local.sh --dry-run     # prints the plan, changes nothing
```

### Practicing on the home lab
The lab has no hardening, so recreate it first (as root, on each lab node):
```bash
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nKillUserProcesses=yes\nStopIdleSessionSec=600\n' > /etc/systemd/logind.conf.d/99-lab-hardening.conf
printf 'readonly TMOUT=600\nexport TMOUT\n' > /etc/profile.d/99-lab-tmout.sh
systemctl restart systemd-logind          # or reboot; log in again so TMOUT applies
```
`StopIdleSessionSec` needs systemd 252 or newer and is ignored on older releases. `KillUserProcesses=yes`
plus `TMOUT=600` reproduces the behavior.

Then compare the two methods in a fresh login:
```bash
nohup sleep 1500 > /dev/null 2>&1 &                      # dies at the idle logout
systemd-run --unit=survivor --remain-after-exit sleep 1500
# wait for the idle logout at 10 minutes, log in again as root, then:
pgrep -a sleep ; systemctl status survivor --no-pager    # nohup sleep gone, survivor still running
systemctl stop survivor
```
Suggested practice order on the lab (one node pair, standby first): `dgrun ... --dry-run` for a few scripts,
then `dgrun prep/prep_s_local.sh` and `dgrun prep/prep_p_local.sh` while you let your session idle out and
reconnect, then `dgrun -t switch_test/switchtest_local.sh` to practice the interactive form.
Remove the lab hardening afterwards: delete the two files above and restart `systemd-logind`.

---

## Resuming After a Failure

`deploy_s_local.sh` and `deploy_p_local.sh` support `--from-step N`:
```bash
bash deploy/deploy_p_local.sh --from-step 11   # resume at GI switch (Step 11)
bash deploy/deploy_s_local.sh --from-step 6    # resume at GI switch (Step 6)
```
Step numbers are listed in each script's header comment.

---

## SYS Password Handling

The scripts prompt for the SYS password once per session via `read -s`.
The password is stored in memory only as `DG_SYS_PASSWORD` and never
written to disk or logged. It is required for DG Broker switchover and
switchback because the Broker must authenticate to the remote instance
using the password file (`dgmgrl /` OS authentication is insufficient
for cross-instance connections).

To avoid being prompted (e.g. in automated pipelines):
```bash
export DG_SYS_PASSWORD="your_password"
bash deploy/switchover_local.sh   # skips prompt
```

---

## Key Design Decisions

### GI Home Switch
The prep phase builds and patches new homes using `gridSetup.sh -applyRU`.
The deploy phase switches the active GI home using `gridSetup.sh -switchGridHome`,
which reconfigures CRS to start from the new home. `root.sh` then restarts
CRS from the new home. **Do not use opatchauto** for this — opatchauto applies
patches in-place and is not the correct tool for switching pre-patched OOP homes.

The `run_gi_switch` function in `lib_common.sh` automates the entire sequence:
it starts `gridSetup.sh` in the background, polls for the root.sh prompt,
runs root.sh, and verifies ohasd.bin is running from the new home.

### datapatch
datapatch runs directly on the current primary after switchover.
Before running datapatch, `DBMS_QOPATCH.load_xml_inventory` reloads the
xml inventory in the database, preventing `ORA-20001` stale inventory errors
that occur after an OOP home switch.

### chopt (post_install_local.sh)
chopt must be run on **each node's binary independently**. Binary changes
do not propagate via redo. For Non-CDB environments, disabling partitioning
(`chopt disable partitioning`) is safe. For CDB environments, do not disable
partitioning — the CDB dictionary uses partitioned objects internally.

### ADR_BASE Ownership
`/u01/app/oracle/diag` (or wherever `ADR_BASE` points) must be owned by
`oracle:oinstall`, not `grid:oinstall`. If owned by grid, kfod fails to
initialize ADR and AutoUpgrade analyze fails with COM-115. The deploy scripts
fix this automatically in Step 3d.

---

## v3 Changes

0. **SYS.DB_DDL_ALERT_TRG.** `deploy_s_peer.sh` (on the primary, before the switchover, only when all its checks pass) disables the trigger in the non-CDB, or in the CDB root and every READ WRITE PDB. The DDL replicates to the standby through redo. `post_install_local.sh` Step G enables it again on the primary after patching (it refuses if the node is not PRIMARY). Containers without the trigger are skipped, PDBs that are not READ WRITE are reported. The helper is `ddl_trigger` in `lib_common.sh`.
0b. **`cleanup_local.sh`:** `deinstall` is gone. Each old home is detached with `runInstaller -silent -detachHome ORACLE_HOME=<old home>` (from the new home, as the owner of the old home), and only if both detaches succeed are the old directories removed. The previous version looked up home names with a broken quote, so inventory entries were never detached. The script asks for YES, so start it with `dgrun -t`.

0b2. **`ddl_trigger` (in `lib_common.sh`) uses `catcon.pl` on a CDB** instead of a PL/SQL loop with `ALTER SESSION SET CONTAINER`, which failed on the lab CDB. It runs the statement in CDB$ROOT and every open PDB (PDB$SEED excluded), lists PDBs that are not READ WRITE, and fails if the catcon logs contain ORA- or SP2- errors. A non-CDB still uses plain sqlplus. The same change is in the single-instance Phase 3 and Phase 4.
0c. **OLAP mismatch (`Database option APS/XOQ mismatch`) in AutoUpgrade analyze.** After `chopt disable olap`, `post_install_local.sh` ran `XOQ_VALIDATE` and `APS_VALIDATE` only in CDB$ROOT, so the root showed `OPTION OFF` while PDB$SEED and the PDBs still showed `VALID`, and the next cycle's analyze failed with pending plug-in violations. Step D now runs both procedures in every container with `catcon.pl` (CDB only) and warns if `pdb_plug_in_violations` still lists `Database option` rows (close and reopen the PDBs to refresh them). Manual fix, per container: `exec sys.xoq_validate` and `exec sys.aps_validate`. PDB$SEED needs `catcon.pl -c 'PDB$SEED'`.
0d. **`chopt disable partitioning` is skipped on a CDB** (it is for non-CDB only). Detected from `v$database.cdb`.
0e. **`dgrun` no longer stops a unit that still owns processes.** Deploy and switch steps leave the Oracle instance inside the unit's cgroup, and `systemctl stop` on that unit kills the database. Units now start with `-p KillMode=process`; `dgrun` uses a new unit name if the old one still owns processes; `dgclean` and `dgprocs` are new. To abort a step that is still running: `systemctl kill --kill-who=all dgpatch-<unit>`.

1. `prep_s_local.sh`, `prep_p_local.sh`: `gridSetup.sh` and `runInstaller` exit code 6 (success with optional prerequisite warnings) is accepted via the new `check_installer_rc` helper in `lib_common.sh`. Previously `&& pass || fail` treated 6 as a failure and stopped the prep.
2. `lib_common.sh`: `run_gi_switch` logs the `gridSetup.sh -switchGridHome` exit code (0 and 6 are success).
3. All `nohup ... &` instructions in script headers, log messages and the runbook are replaced by `systemd-run`. Steps are started with `dgrun`, steps that prompt for the SYS password with `dgrun -t`.

## v2 Changes from v1 (from trial run 2026-08-21)

1. `lib_common.sh`: `get_dg_lag` fixed to return full `+00 00:00:00` (was truncating to `+00`)
2. `lib_common.sh`: added `require_dg_password`, `rundgmgrl_auth`, `run_gi_switch`
3. `deploy_s_local.sh`, `deploy_p_local.sh`: replaced opatchauto with `run_gi_switch`; added `--from-step N`; removed stray fragment after password file copy
4. `deploy_p_local.sh`: Step 2b opens standby READ ONLY if MOUNTED; Step 3d fixes ADR ownership
5. `switchtest_local.sh`, `switchover_local.sh`, `switchback_local.sh`: `-n` guard on lag check; `rundgmgrl_auth` for switchover/switchback; 30s delay before archive log switch
6. `validate_local.sh`: DG Broker grep fixed for multi-line output; `FAIL` -> `fail`
7. `datapatch_peer.sh`: removed AutoUpgrade wrapper (`run_datapatch` not supported in patch mode); added `DBMS_QOPATCH.load_xml_inventory` reload step
8. `cleanup_local.sh`: dynamic inventory home name detection; improved deinstall sequence
9. `prep_p_local.sh`, `prep_s_local.sh`: removed `GI_RU_PATCH` (bundle dir ID) from `opatch lspatches` verification; only `GI_APPLY_RU_PATCH` (sub-patch ID) is checked
10. `patch.conf`: all environment-specific values in clearly labelled sections; no hardcoded values in any script

No passwordless SSH between nodes is required.

---

## Adapting to a New Environment
# Oracle 19c OOP Patch Automation Framework
## Single Node CRS - single OS owner (`oracle` only, no `grid` user)

Tested layout: lnx103.home.aarisha.com, 19.3 to 19.33, Grid and database both owned by `oracle`.

---

## Environment this version targets

| Item | Value |
|---|---|
| OS user owning Grid Infrastructure and the database | `oracle` (there is no `grid` user) |
| Primary group | `oinstall` |
| ASM groups (OSDBA / OSOPER / OSASM) | all `dba` (take the real values from your original Grid response file) |
| Grid environment | defined in `/home/oracle/.bashrc` (`ORACLE_HOME`, `ORACLE_SID=+ASM1`, `LD_LIBRARY_PATH`) |
| Database environment | `. oraenv` |
| Grid base (`GRID_BASE`) | `/u01/app/oracle` |
| Database base (`ORACLE_BASE`) | `/u01/app/odaorabase/oracle` |

The orchestrator is started as **root**. Phases that need the software owner switch to `oracle`
internally. Nothing in this framework refers to a `grid` OS account.

---

## Directory Layout

```
/u01/patching/automation/            <- SCRIPTS_DIR (must be readable by oracle, never under /root)
|-- patch.conf                       <- EDIT THIS FOR EACH PATCH CYCLE
|-- patch_orchestrator.sh            <- Master orchestrator (run as root)
|-- phase1_grid_prep.sh              <- Build + patch new Grid home      (runs as oracle)
|-- phase2_db_prep.sh                <- Build + patch new DB home        (runs as oracle)
|-- phase3_switch.sh                 <- Home switch + AutoUpgrade deploy (root, su - oracle)
|-- phase4_post_install.sh           <- Post-patch validation + utlrp    (root, su - oracle)
|-- phase5_cleanup.sh                <- Deinstall old homes              (manual)
|-- phase6_security.sh               <- FIPS file + extproc disable      (manual)
|-- phase7_aide.sh                   <- AIDE baseline reset              (manual)
`-- README.md                        <- This file

/u01/patching/logs/logs_1933/        <- LOG_DIR, one directory per patch cycle
|-- phaseN_*.log
`-- .phase_status/phaseN.done        <- success markers that enforce phase order

/opt/oracle/patches/                 <- PATCH_LOC (staging)
|-- p6880880_190000_Linux-x86-64.zip <- Latest OPatch
|-- p<RU_COMBO>_190000_Linux-x86-64.zip   <- RU combo (Phase 1 extracts it here)
|-- p<DB_STANDALONE>_*.zip           <- Standalone DB patch (Phase 2 extracts it here)
|-- autoupgrade.jar                  <- Latest AutoUpgrade
|-- orcl_auto_patch.cfg              <- AutoUpgrade config (source/target homes, SID)
|-- grid_install.rsp                 <- Grid response file template
`-- db_install.rsp                   <- DB response file template

/u01/shared/software/db/base_releases/   <- BASE_SW_DIR: LINUX.X64_193000_grid_home.zip, LINUX.X64_193000_db_home.zip
```

Extracted patch directories (`<RU_COMBO>/...`, `<DB_STANDALONE>/`) appear under `/opt/oracle/patches`
only after Phase 1 and Phase 2 run. They are not expected beforehand.

---

## For Each New Patch Cycle

**Only edit `patch.conf`.** Update:

### Patch identity (always update)
| Variable | Description |
|---|---|
| `NEW_PATCH_LEVEL` / `OLD_PATCH_LEVEL` | Labels used in logs (for example `19.33` / `19.3`) |
| `RU_COMBO_PATCH` | Outer RU combo patch number |
| `GI_RU_PATCH` | GI RU bundle directory inside the combo (contains `bundle.xml`) |
| `GI_APPLY_RU_PATCH` | `gridSetup.sh -applyRU` sub-patch (OCW) |
| `GI_ONEOFF_PATCHES` | `gridSetup.sh -applyOneOffs`, comma-separated IDs |
| `DB_APPLY_RU_PATCH` | `runInstaller -applyRU` sub-patch (DB RU) |
| `DB_ONEOFF_PATCHES` | `runInstaller -applyOneOffs`, comma-separated IDs |
| `RU_COMBO_TOPLEVEL_PATCHES` | Patches at the top level of the combo (for example OJVM) |
| `DB_RU_STANDALONE_PATCH` / `DB_RU_STANDALONE_ZIP` | Standalone DB patch number and zip name |

### Home paths (explicit, never derived from the patch level)
| Variable | Example |
|---|---|
| `OLD_GRID_HOME` | `/u01/app/19.0.0.0/oracle` |
| `NEW_GRID_HOME` | `/u01/app/19.33.0.0/oracle` |
| `OLD_DB_HOME` | `/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1930` |
| `NEW_DB_HOME` | `/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1933` |

> **No trailing slash on any home path.** Phases 1 and 3 run `sed s|OLD|NEW|` over helper scripts and
> profile files, and Phase 3 compares `NEW_GRID_HOME` with `crs_home` in `/etc/oracle/olr.loc`.
> A trailing `/` makes both of those miss.

### Users, groups and bases (set once per host)
```bash
GRID_USER="oracle"          # same account as ORACLE_USER
ORACLE_USER="oracle"
INSTALL_GROUP="oinstall"
GI_OSDBA_GROUP="dba"        # use the values in the ORIGINAL grid response file
GI_OSOPER_GROUP="dba"
GI_OSASM_GROUP="dba"
GRID_BASE="/u01/app/oracle"                  # Grid ORACLE_BASE (from .bashrc / grid rsp)
ORACLE_BASE="/u01/app/odaorabase/oracle"     # database base (what oraenv reports)
DB_NAME="maxstage"                           # CRS database name (srvctl config database)
```
Verify the groups with:
`grep -i "osdba\|osoper\|osasm" /opt/oracle/patches/grid_install.rsp`

### Response files
| Variable | Value |
|---|---|
| `GRID_RSP` | `/opt/oracle/patches/grid_install.rsp` |
| `DB_RSP` | `/opt/oracle/patches/db_install.rsp` |

These are templates only. Each run works on a temporary copy, so the originals are never modified.

- Phase 1 rewrites `ORACLE_HOME`, forces `oracle.install.option=CRS_SWONLY` and sets `clusterNodes` to the short hostname.
- Phase 2 rewrites only `ORACLE_HOME` in the DB response file. `ORACLE_BASE` is taken from the file as is.
- Phase 3 rewrites OSDBA / OSOPER / OSASM from `patch.conf` and forces `CRS_SWONLY`. It keeps `clusterNodes` from the template, so the template must read `<short-host>:<short-host>-vip.<domain>`, for example `lnx103:lnx103-vip.home.aarisha.com`.
- Plain-text ASM passwords are not needed for a software-only run. Remove them from the staged template.

---

## Running the Orchestrator (as root)

### Validate configuration first
```bash
./patch_orchestrator.sh --phase 1 --dry-run
```
A dry run checks `patch.conf`, `PATCH_LOC` and script readability by `oracle`. It does not
check that the patch zips exist.

### Phase by phase (recommended while testing)
```bash
./patch_orchestrator.sh --phase 1    # Grid home prep (online)
./patch_orchestrator.sh --phase 2    # DB home prep + AutoUpgrade analyze (online)
./patch_orchestrator.sh --phase 3    # Switch (OUTAGE)
./patch_orchestrator.sh --phase 4    # Post-patch validation
```

### Full run, phases 1-4
```bash
chmod 755 /u01/patching/automation/*.sh
nohup /u01/patching/automation/patch_orchestrator.sh > /dev/null 2>&1 &
tail -f /u01/patching/logs/logs_1933/master_patch.log
```

### Hardened hosts: run every phase with `systemd-run`
Where logind kills the session (`KillUserProcesses=yes`, idle session stop after 600 s, `TMOUT=600`),
`nohup` and `&` die with your login session. Start each phase as a transient systemd service instead.
It is owned by PID 1, outside your session, so logout and idle timeouts cannot kill it. No phase
script prompts for input, so no tty is needed. Tested: a service running `su - oracle -c 'sleep 700'`
finished with `rc=0` after the PuTTY session was killed at 600 s.

Use one unit name per phase. Run these as root:

| Phase | Start command |
|---|---|
| 1 Grid home prep | `systemd-run --unit=oppatch-p1 --remain-after-exit /u01/patching/automation/patch_orchestrator.sh --phase 1` |
| 2 DB home prep | `systemd-run --unit=oppatch-p2 --remain-after-exit /u01/patching/automation/patch_orchestrator.sh --phase 2` |
| 3 Switch (OUTAGE) | `systemd-run --unit=oppatch-p3 --remain-after-exit /u01/patching/automation/patch_orchestrator.sh --phase 3` |
| 4 Post-patch validation | `systemd-run --unit=oppatch-p4 --remain-after-exit /u01/patching/automation/patch_orchestrator.sh --phase 4` |
| 5 Cleanup | `systemd-run --unit=oppatch-p5 --remain-after-exit /u01/patching/automation/patch_orchestrator.sh --phase 5` |
| 6 FIPS + extproc | `systemd-run --unit=oppatch-p6 --remain-after-exit /u01/patching/automation/patch_orchestrator.sh --phase 6` |
| 7 AIDE reset | `systemd-run --unit=oppatch-p7 --remain-after-exit /u01/patching/automation/patch_orchestrator.sh --phase 7` |

Optional shortcut for the current shell, so each phase is `oppatch 1`, `oppatch 2`, and so on:
```bash
oppatch() {   # usage: oppatch <phase> [extra orchestrator args, e.g. --dry-run]
  local n="$1"; shift
  systemctl stop "oppatch-p${n}" 2>/dev/null || true   # clear a finished unit of the same name
  systemd-run --unit="oppatch-p${n}" --remain-after-exit \
    /u01/patching/automation/patch_orchestrator.sh --phase "${n}" "$@"
}
```

Watch a phase (these are all safe to run again after a reconnect):
```bash
tail -n 50 /u01/patching/logs/logs_1933/master_patch.log          # progress (use tail -f for short stretches)
systemctl status oppatch-p1 --no-pager                            # running, or exited
systemctl show oppatch-p1 -p ActiveState -p Result -p ExecMainStatus
# finished OK: ActiveState=active (exited) Result=success ExecMainStatus=0
# failed:      Result=exit-code and a non-zero ExecMainStatus; read the phase log in LOG_DIR
journalctl -u oppatch-p1 --no-pager | tail -n 50                  # anything the script printed
systemctl stop oppatch-p1                                         # clear the unit when you are done
```
Notes:
- The orchestrator already writes `master_patch.log` and a log per phase, so the journal is a backup.
- Do not sit in a foreground `tail -f` or `sleep` for more than 10 minutes. `TMOUT` will log you out
  (the phase keeps running).
- Start the next phase only after `Result=success`. The `.phase_status` markers enforce the order anyway.
- To run several phases in one service, for example 1 and 2: `--from-phase 1` with no `--phase`, but
  keep Phase 3 (the outage) as its own unit so you decide when it starts.
- `enable-linger` is not needed. It is for `systemd-run --user`, not for system units.

### Practicing `systemd-run` on the home lab
The lab has none of the office hardening, so recreate it, then compare `nohup` with `systemd-run`.
```bash
# as root on the lab host
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nKillUserProcesses=yes\nStopIdleSessionSec=600\n' > /etc/systemd/logind.conf.d/99-lab-hardening.conf
printf 'readonly TMOUT=600\nexport TMOUT\n' > /etc/profile.d/99-lab-tmout.sh
systemctl restart systemd-logind        # or reboot; then log in again so TMOUT applies
```
`StopIdleSessionSec` needs systemd 252 or newer and is ignored on older releases. `KillUserProcesses=yes`
plus `TMOUT=600` is enough to reproduce the behavior.

Test in a fresh login:
```bash
nohup sleep 1500 > /dev/null 2>&1 &                    # dies when the session ends
systemd-run --unit=survivor --remain-after-exit sleep 1500
# wait for the idle logout at 10 minutes, log in again as root, then:
pgrep -a sleep ; systemctl status survivor --no-pager  # nohup sleep gone, survivor still running
systemctl stop survivor
```
Then do a real dry run (`oppatch 1 --dry-run`) and a full Phase 1 on the lab, reconnecting midway.
Remove the lab hardening afterwards: delete the two files above and restart `systemd-logind`.

### Other options
```bash
./patch_orchestrator.sh --from-phase 2     # resume after fixing a failure
./patch_orchestrator.sh --cleanup          # also run phase 5
./patch_orchestrator.sh --full             # phases 1-7
./patch_orchestrator.sh --reset-status     # clear markers after a snapshot restore
```

---

## Phase Summary

| Phase | Script | Runs as | Window | Description |
|---|---|---|---|---|
| 1 | phase1_grid_prep.sh | oracle | Online | Extract base Grid, OPatch, RU combo; `gridSetup.sh -applyRU/-applyOneOffs` (CRS_SWONLY) |
| 2 | phase2_db_prep.sh | oracle | Online | Extract base DB, OPatch, standalone patch; `runInstaller -applyRU/-applyOneOffs`; AutoUpgrade analyze |
| 3 | phase3_switch.sh | root, then `su - oracle` | **OUTAGE** | Step 0a disables `SYS.DB_DDL_ALERT_TRG` (db/cdb/pdb), then stop listener, `gridSetup.sh -switchGridHome`, `root.sh`, AutoUpgrade deploy (DB home switch + datapatch), profile updates, registration check |
| 4 | phase4_post_install.sh | root, then `su - oracle` | Online | `utlrp`, registry validation, Step F enables `SYS.DB_DDL_ALERT_TRG` again |
| 5 | phase5_cleanup.sh | root | Manual | Detach old Grid and DB homes from the inventory (`runInstaller -detachHome`), then remove the old directories (only runs with `--cleanup`, `--full` or `--phase 5`) |
| 6 | phase6_security.sh | root | Manual | FIPS file, disable `extproc` |
| 7 | phase7_aide.sh | root | Manual | Reset AIDE baseline (must run last) |

Phase order is enforced by markers in `.phase_status`. Phase 7 runs last so the AIDE baseline matches
the final filesystem state after the old homes are gone.

---

## Single OS owner: how the scripts handle it

1. **Login-shell environment.** `su - oracle` sources `.bashrc`, which exports a Grid `ORACLE_HOME`,
   `ORACLE_SID=+ASM1` and `LD_LIBRARY_PATH=$ORACLE_HOME/grid/lib`. Every `su -` and `sudo -i` call therefore starts with
   `unset LD_LIBRARY_PATH`, and the installer calls set their own `ORACLE_HOME`.
2. **Installers.** Run `gridSetup.sh` and `runInstaller` with `ORACLE_HOME`, `ORACLE_SID` and `LD_LIBRARY_PATH` unset, otherwise the
   installer picks up the running Grid environment.
3. **Listener.** Stopped with `srvctl stop listener -l LISTENER` from the old Grid home. `lsnrctl` is not used. A listener that is already down is tolerated on re-run.
4. **Response file permissions.** The Phase 3 temporary response file is created by root and then handed to `oracle` with mode 600, because `gridSetup.sh` runs as `oracle`. Passwords are never written to the log.
5. **`/etc/oratab`.** Maintained by the CRS agent (`# line added by Agent`). The scripts do not edit it. Phase 3 ends with a read-only check of the CRS database home, `oratab` and `crs_home` in `/etc/oracle/olr.loc`.
6. **Profiles.** Phase 3 updates `ORACLE_HOME` paths in the `oracle` profile files with `sed`. Home paths must be exact, with no trailing slash.
7. **Database name.** `phase5_cleanup.sh` uses `ora.${DB_NAME}.db`, not a hardcoded name.
8. **`runInstaller` exit code 6** (success with optional prerequisite warnings) is accepted. If the new DB home is already built, Phase 2 resumes at Step 8. Force a step with `PHASE2_FROM_STEP=<n>`.

---

## SYS.DB_DDL_ALERT_TRG

On a CDB the trigger statement is run with `catcon.pl` in CDB$ROOT and every open PDB (PDB$SEED excluded). The trigger is local to each container, so it must exist in each one; create it in every container the same way before the first cycle.

- **Phase 3, Step 0a** (before the listener is stopped and before AutoUpgrade): `alter trigger SYS.DB_DDL_ALERT_TRG disable` in a non-CDB, or in the CDB root and every READ WRITE PDB. The database must be open. If it cannot be disabled, Phase 3 stops before anything is shut down.
- **Phase 4, Step F:** the same statement with `enable`. If that fails, Phase 4 stops (no success marker), so Phase 5 cannot run until the trigger is enabled.
- The database and instance names come from `DB_NAME` and `srvctl status database`. Containers without the trigger are skipped; PDBs that are not READ WRITE are reported in the log.

## Phase 5 cleanup: detachHome, not deinstall

Phase 5 detaches each old home from the inventory, as the owner of that home, from the new home:
```bash
<NEW_DB_HOME>/oui/bin/runInstaller -silent -detachHome ORACLE_HOME=<OLD_DB_HOME>       # as oracle
<NEW_GRID_HOME>/oui/bin/runInstaller -silent -detachHome ORACLE_HOME=<OLD_GRID_HOME>   # as GRID_USER
```
Only after both succeed are the old directories removed. A home that is already detached or marked `REMOVED="T"` is skipped, so the phase can be re-run. To check by hand: `grep -i "HOME NAME" /u01/app/oraInventory/ContentsXML/inventory.xml`.

## Known Issues and Notes

- **Not Data Guard aware.** The scripts patch the host they run on. For a primary and standby pair, run Phases 1 and 2 on both hosts, then do the switch on the standby first and the primary second, and decide how redo apply, the broker and `datapatch` (primary only) are handled before using Phase 3 on a standby.
- `gridSetup.sh` and `runInstaller` exit code 6 means success with optional prerequisite warnings. Phases 1, 2 and 3 accept it.

- `gridSetup.sh -switchGridHome` is used for the Grid home switch on this clustered (CRS) install. It cannot be re-run once CRS is already running from the new home (`INS-45102`). Phase 3 detects that case and skips to the AutoUpgrade deploy step.
- `srvctl modify database -o` must run with `ORACLE_HOME` set to the old home. Phase 3 handles this.
- `opatch lspatches` on a new home can return errors before the switch. Use the `.patch_storage` listing for pre-switch checks.
- Do not shut the database down before Phase 3 Step 7. AutoUpgrade deploy needs it running to connect to the source home.
- `chopt` options apply to non-CDB databases only. Skip them for CDBs.
- `CV_ASSUME_DISTID=OEL7.8` is exported from `patch.conf`. Without it, `dbca`, `gridSetup.sh` and `deinstall` can fail with `INS-08101` or a `NullPointerException`.
- A stale `PDB_PLUG_IN_VIOLATIONS` row can block the AutoUpgrade analyze step. Closing and reopening the PDB refreshes it.

---

## Troubleshooting quick reference

| Symptom | Likely cause | Action |
|---|---|---|
| `INS-10105 ... (Permission denied)` in Phase 3 | Temp response file owned by root | Use the current `phase3_switch.sh` (chowns the file to `oracle`) |
| `.bashrc` still shows the old Grid home after Phase 3 | Trailing `/` on `OLD_GRID_HOME` | Remove the slash in `patch.conf` and fix the profile by hand |
| `bash: unset: ... not a valid identifier` in Phase 5 | Old `deinstall` block where `unset LD_LIBRARY_PATH` was continued into the `CV_ASSUME_DISTID=... ORACLE_HOME=...` lines | Use this Phase 5 (no deinstall). Detach the homes by hand if the inventory still lists them |
| `INS-41885` on `switchGridHome` | Group values wrong or passed on the command line | Set `GI_OS*_GROUP` to match the original Grid response file |
| `CLSRSC-901` in `root.sh` | Old home path left in `root.sh` or `rootmacro.sh` | Phase 3 Step 3 corrects it, re-run the phase |
| `gridSetup.sh` or `runInstaller` exit code 6 | Optional prerequisite warnings | Accepted by Phases 1, 2 and 3 |
| `INS-08101` / `NullPointerException` | `CV_ASSUME_DISTID` not set | Set it in `patch.conf` |
| `TNS-01190` from `lsnrctl stop` | Listener is CRS-managed | Use `srvctl stop listener` |
| `kfod` Error 49802 in AutoUpgrade analyze | ADR directory owned by wrong user | `chown -R oracle:oinstall $ORACLE_BASE/diag` |
| AutoUpgrade analyze: `Database option APS/XOQ mismatch` | `XOQ_VALIDATE`/`APS_VALIDATE` not run in every container after `chopt disable olap` | Phase 4 Step D now does this with `catcon.pl`; by hand: run both procedures in each PDB and PDB$SEED, then close/reopen the PDBs |
| "Phase N has not completed" | Missing success marker | Run earlier phases, or `--reset-status` after a snapshot restore |

**Only patch.conf requires editing.** No values are hardcoded in any script.
All scripts source patch.conf at startup.

### Section 1 — Patch Identity (edit every patch cycle)

```bash
NEW_PATCH_LEVEL="19.32"       # target RU level
OLD_PATCH_LEVEL="19.3"        # current installed level

RU_COMBO_PATCH="39618711"     # outer combo zip patch number
GI_RU_PATCH="39467003"        # GI bundle directory inside combo
GI_APPLY_RU_PATCH="39526364"  # OCW sub-patch shown in opatch lspatches
GI_ONEOFF_PATCHES="..."       # comma-separated patches inside GI_RU_PATCH
DB_APPLY_RU_PATCH="39472050"  # DB RU sub-patch shown in opatch lspatches
DB_ONEOFF_PATCHES="..."       # comma-separated patches inside GI_RU_PATCH
DB_RU_STANDALONE_PATCH="..."  # standalone DB patch (e.g. Datapump bundle)
DB_RU_STANDALONE_ZIP="..."    # filename of standalone DB patch zip
RU_COMBO_TOPLEVEL_PATCHES="..." # patches at combo root level (e.g. OJVM)
OPATCH_PATCH="6880880"        # OPatch patch number (rarely changes)
```

**How to find these values for a new RU:**
1. Download the RU combo zip from MOS. Extract it.
2. The outer directory name is `RU_COMBO_PATCH`.
3. Inside the combo, find the GI bundle directory: `RU_COMBO_PATCH/GI_RU_PATCH/`.
4. Inside the GI bundle, the OCW patch is `GI_APPLY_RU_PATCH`. Other directories are `GI_ONEOFF_PATCHES`.
5. The DB RU patch inside the GI bundle is `DB_APPLY_RU_PATCH`.
6. Patches at the combo root level (not inside the GI bundle) are `RU_COMBO_TOPLEVEL_PATCHES` (e.g. OJVM).
7. Check My Oracle Support for any standalone DB patches required for the RU (e.g. Datapump bundle).

### Section 2 — Node Identity (edit for each environment)

```bash
PRIMARY_HOST="lnx107"               # hostname -s of primary node
PRIMARY_IP="192.168.1.107"         # primary IP address (reference only)
PRIMARY_DB_UNIQUE_NAME="CDBPRIM"   # DB_UNIQUE_NAME (from v$database)
PRIMARY_SID="CDBPRIM"              # ORACLE_SID of primary instance

STANDBY_HOST="lnx113"              # hostname -s of standby node
STANDBY_IP="192.168.1.113"        # standby IP address (reference only)
STANDBY_DB_UNIQUE_NAME="CDBSTBY"  # DB_UNIQUE_NAME (from v$database)
STANDBY_SID="CDBSTBY"             # ORACLE_SID of standby instance
```

### Section 3 — Home Paths (edit for each environment and each patch cycle)

```bash
OLD_GRID_HOME="/u01/app/19.0.0/grid"
NEW_GRID_HOME="/u01/app/19.32.0/grid"

OLD_DB_HOME="/u01/app/oracle/product/19.0.0/dbhome_1"
NEW_DB_HOME="/u01/app/oracle/product/19.0.0/dbhome_1932"
```

**Naming conventions:**
- Grid home path: `<GRID_BASE>/<version>/grid` e.g. `/u01/app/19.32.0/grid`
- DB home path: `<ORACLE_BASE>/product/<oracle_version>/<home_name>` e.g. `dbhome_1932`

To find current active home paths:
```bash
su - grid   -c "env | grep ORACLE_HOME"   # current Grid home
su - oracle -c "env | grep ORACLE_HOME"   # current DB home
srvctl config database -d <DB_UNIQUE_NAME> | grep "Oracle home"
```

### Section 4 — Oracle Base and ADR (edit for each environment)

```bash
ORACLE_BASE="/u01/app/oracle"   # Oracle software owner base directory
GRID_BASE="/u01/app/grid"      # Grid Infrastructure base directory
ADR_BASE="${ORACLE_BASE}/diag" # Automatic Diagnostic Repository base
```

`ADR_BASE` must be owned by `oracle:oinstall`. If it is owned by `grid`,
AutoUpgrade analyze fails with COM-115 (kfod ADR initialization error).
The deploy scripts fix this automatically, but verify before running:
```bash
ls -la /u01/app/oracle/ | grep diag
```

### Section 5 — Patch Staging (edit for each environment)

```bash
PATCH_STAGE_DIR="/u01/patching/stage"
PATCH_DIR="${PATCH_STAGE_DIR}/1932"        # versioned subdirectory
```

The `PATCH_DIR` subdirectory name is typically the RU level (e.g. `1932` for 19.32).
Update it to match where you stage the new RU zip files.

### Section 8 — OS and Install Settings (edit for each environment)

```bash
CV_ASSUME_DISTID="OEL7.8"   # Use OEL7.8 for Oracle Linux 8 (required by installer)
GRID_USER="grid"              # OS user owning Grid Infrastructure
ORACLE_USER="oracle"          # OS user owning Oracle Database
INSTALL_GROUP="oinstall"      # Primary group (must include both grid and oracle)
```

---

## Stage Directory Layout

The following files must be present on **both nodes** at identical paths
before running `setup/deploy_scripts.sh`:

```
/u01/patching/stage/               (PATCH_STAGE_DIR)
  base_releases/                   (BASE_DIR)
    LINUX.X64_193000_grid_home.zip
    LINUX.X64_193000_db_home.zip
  1932/                            (PATCH_DIR -- name matches RU level)
    p39618711_190000_Linux-x86-64.zip    (RU combo zip)
    p39657094_1932000DBRU_Generic.zip    (standalone DB patch)
    autoupgrade.jar                       (latest from MOS 2485457.1)
    opatch/
      p6880880_190000_Linux-x86-64.zip   (OPatch zip)
  rsp/
    <primary_host>_grid_install.rsp      (primary node GI response file)
    <primary_host>_db_install.rsp        (primary node DB response file)
    <standby_host>_grid_install.rsp      (standby node GI response file)
    <standby_host>_db_install.rsp        (standby node DB response file)
```

**Response files** must be the original install response files from when
Grid Infrastructure and Oracle Database were first installed on each node.
They must have `oracle.install.option` set to the original install option
(e.g. `CRS_CONFIG` for GI). The prep scripts derive a `CRS_SWONLY` copy
at runtime via sed — do not pre-modify the response files.

To obtain response files if the originals are unavailable:
```bash
# Regenerate from an existing installation:
$GRID_HOME/gridSetup.sh -silent -recordConfigInfo -responseFile /tmp/grid_record.rsp
$ORACLE_HOME/runInstaller -silent -recordConfigInfo -responseFile /tmp/db_record.rsp
```

---

## Prerequisites Before Running

Verify all of these before `setup/deploy_scripts.sh`:

### 1. DG Broker health
```bash
su - oracle -c "dgmgrl / 'show configuration'"
# Must show: Configuration Status: SUCCESS
```

### 2. Switchover works via dgmgrl
```bash
su - oracle -c "dgmgrl sys/<password>@<PRIMARY_DB_UNIQUE_NAME> 'validate database <STANDBY_DB_UNIQUE_NAME>'"
# Ready for Switchover: Yes
```

### 3. Password files are in sync on both nodes
DG Broker requires matching SYS passwords to connect to the remote instance
during switchover. Verify:
```bash
# md5sums must match:
md5sum $OLD_DB_HOME/dbs/orapw<PRIMARY_SID>    # on primary
md5sum $OLD_DB_HOME/dbs/orapw<STANDBY_SID>   # on standby
```
If they differ, copy the primary password file to the standby:
```bash
scp $OLD_DB_HOME/dbs/orapw<PRIMARY_SID> \
    root@<STANDBY_HOST>:$OLD_DB_HOME/dbs/orapw<STANDBY_SID>
ssh root@<STANDBY_HOST> "chown oracle:oinstall \
    $OLD_DB_HOME/dbs/orapw<STANDBY_SID> && chmod 640 \
    $OLD_DB_HOME/dbs/orapw<STANDBY_SID>"
```
After any `ALTER USER SYS IDENTIFIED BY` on the primary, repeat the copy.

### 4. Static listener service for DG Broker on standby
The standby listener.ora must have a static SID entry for the Broker's
connect identifier. Check:
```bash
grep -i "DGMGRL\|SID_LIST" $OLD_GRID_HOME/network/admin/listener.ora
# on standby node
```
Required entry format:
```
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = <STANDBY_DB_UNIQUE_NAME>_DGMGRL)
      (ORACLE_HOME = <OLD_DB_HOME>)
      (SID_NAME = <STANDBY_SID>)
    )
  )
```

### 5. StaticConnectIdentifier for DG Broker
```bash
dgmgrl / "show database verbose <STANDBY_DB_UNIQUE_NAME>" | grep StaticConnect
# Must point to standby VIP:1521 with correct SERVICE_NAME
```

### 6. SYSDG grant
```bash
# On primary, as sysdba:
GRANT SYSDG TO SYS;  -- updates password file automatically
```

### 7. Disk space
Minimum 30 GB free on /u01 (or wherever homes are installed) on each node:
```bash
df -BG /u01
```

---

## Execution Sequence

Every step below is started with `dgrun` (defined in the next section) so that it survives hardened
session settings (`KillUserProcesses=yes`, 600 s idle logout, `TMOUT=600`). Run each step on the host
shown, as root, from the automation directory. Wait for `Result=success` (see "Watching a step")
before starting the next step. Scripts that prompt (SYS password, or YES in the cleanup) use `dgrun -t` (interactive).

### Running steps with systemd-run (hardened hosts)

`nohup` and `&` die with the login session on these hosts, because logind kills the whole session scope.
`systemd-run` starts the script as a transient system service owned by PID 1, outside your session, so
logout and idle timeouts cannot kill it. Tested on a hardened host: a service running
`su - oracle -c 'sleep 700'` finished with `rc=0` after the PuTTY session was killed at 600 s.
`enable-linger` is not needed (it only applies to `systemd-run --user`).

Define this once per login on each node (root):
```bash
cd /u01/patching/automation          # directory that holds patch.conf, lib_common.sh, prep/, deploy/ ...
dgrun() {
  # usage: dgrun [-t] <script path relative to this dir> [script args, e.g. --dry-run or --from-step 6]
  local tty=0; [[ "$1" == "-t" ]] && { tty=1; shift; }
  local script="$1"; shift
  local unit="dgpatch-$(basename "${script}" .sh | tr _ -)"
  systemctl stop "${unit}" 2>/dev/null || true               # clear a finished unit of the same name
  systemctl reset-failed "${unit}" 2>/dev/null || true
  if (( tty )); then                                          # interactive (password prompt)
    if systemd-run --help 2>&1 | grep -q -- '--pty'; then    # systemd 235 or newer
      systemd-run --pty --unit="${unit}" --remain-after-exit bash "$(pwd)/${script}" "$@"
    else                                                      # older systemd (e.g. OL7): foreground scope
      systemd-run --scope --unit="${unit}" bash "$(pwd)/${script}" "$@"
    fi
  else                                                        # background service
    systemd-run --unit="${unit}" --remain-after-exit bash "$(pwd)/${script}" "$@"
  fi
}
dgstat() {    # usage: dgstat <script name without path, e.g. prep_s_local>
  local unit="dgpatch-$(echo "$1" | tr _ -)"
  systemctl show "${unit}" -p ActiveState -p Result -p ExecMainStatus
}
```
- Plain `dgrun` runs in the background and returns at once. Use it for every step that does not ask a question.
- `dgrun -t` uses `systemd-run --pty` (or `systemd-run --scope` on systemd older than 235): the script still
  runs outside your session scope, but it is attached to your terminal so you can type the SYS password. Use it only for `switchtest_local.sh`, `switchover_local.sh`,
  `switchback_local.sh` (SYS password) and `cleanup_local.sh` (asks you to type YES). If your terminal drops, a `--pty` job is hung up, so keep it attended and
  short (a few minutes each).
- Old systemd (for example OL7, v219) has no `--working-directory` and no `--pty`. `dgrun` does not use
  `--working-directory` (the scripts find their own directory), and it falls back to `--scope` for `-t`.
  Check with `systemctl --version | head -1`.
- Do not pass the SYS password with `--setenv` or `-p Environment=`. Anyone can read unit environments with
  `systemctl show`, and the scripts promise never to expose the password.

### Watching a step (safe to repeat after a reconnect)
```bash
tail -n 50 /u01/patching/logs/logs1933/$(hostname -s)/<script name>.log    # LOG_BASE in patch.conf
systemctl status dgpatch-<unit> --no-pager                                 # running, or exited
dgstat <script name>                                                       # Result=success ExecMainStatus=0 when done
journalctl -u dgpatch-<unit> --no-pager | tail -n 50                       # anything printed to the console
systemctl stop dgpatch-<unit>                                              # clear the unit afterwards
```
`Result=exit-code` with a non-zero `ExecMainStatus` means the step failed: read the script log first.
Do not sit in a foreground `tail -f` for more than 10 minutes, because `TMOUT` will log you out
(the step keeps running).

### Phase 0 - Setup (both nodes, once per cycle)
```bash
bash setup/deploy_scripts.sh           # ON PRIMARY_HOST, then ON STANDBY_HOST (short; foreground is fine)
```
Both must print: `RESULT: ALL CHECKS PASSED`

### Phase 1 - Prep (both nodes in parallel, no downtime, about 90 min each)
```bash
dgrun prep/prep_s_local.sh             # ON STANDBY_HOST   unit dgpatch-prep-s-local
dgrun prep/prep_p_local.sh             # ON PRIMARY_HOST   unit dgpatch-prep-p-local
dgrun prep/prep_verify_peer.sh         # ON PRIMARY_HOST   after both prep units show Result=success
```
`gridSetup.sh` and `runInstaller` exit code 6 (success with optional prerequisite warnings, INS-13014) is
accepted. Any other non-zero code stops the script.

### Phase 2 - Switch test (optional, strongly recommended, about 2 min outage)
```bash
dgrun -t switch_test/switchtest_local.sh     # ON PRIMARY_HOST  (prompts for the SYS password)
dgrun switch_test/switchtest_peer.sh         # ON STANDBY_HOST
```

### Phase 3 - Deploy (maintenance window)
```bash
# 1. Patch the standby home (no production impact):
dgrun deploy/deploy_s_local.sh               # ON STANDBY_HOST   unit dgpatch-deploy-s-local
# 2. Verify standby patched and primary healthy. When all checks pass it also DISABLES
#    SYS.DB_DDL_ALERT_TRG on the primary (db/cdb/pdb); it replicates to the standby via redo:
dgrun deploy/deploy_s_peer.sh                # ON PRIMARY_HOST
# 3. SWITCHOVER (production downtime starts):
dgrun -t deploy/switchover_local.sh          # ON PRIMARY_HOST   (prompts for the SYS password)
dgrun deploy/switchover_peer.sh              # ON STANDBY_HOST   only if the broker path failed
# 4. Patch the old primary home (now standby):
dgrun deploy/deploy_p_local.sh               # ON PRIMARY_HOST   unit dgpatch-deploy-p-local
# 5. Verify redo flows to the old primary:
dgrun deploy/deploy_p_peer.sh                # ON STANDBY_HOST   (current primary)
# 6. Data dictionary patches (15-30 min):
dgrun deploy/datapatch_peer.sh               # ON STANDBY_HOST   (current primary)
# 7. Verify redo applied on the old primary:
dgrun deploy/datapatch_local.sh              # ON PRIMARY_HOST
# 8. SWITCHBACK (production downtime ends):
dgrun -t deploy/switchback_local.sh          # ON PRIMARY_HOST   (prompts for the SYS password)
dgrun deploy/switchback_peer.sh              # ON STANDBY_HOST   only if the broker path failed
```

### Phase 4 - Validation
```bash
dgrun deploy/validate_local.sh               # ON PRIMARY_HOST
dgrun deploy/validate_peer.sh                # ON STANDBY_HOST
```

### Phase 5 - Post-patch hardening (both nodes, no downtime)
```bash
dgrun deploy/post_install_local.sh           # ON PRIMARY_HOST, then ON STANDBY_HOST   (chopt, utlrp, registry; primary also
                                             #   ENABLES SYS.DB_DDL_ALERT_TRG again in Step G)
dgrun deploy/security_local.sh               # ON PRIMARY_HOST, then ON STANDBY_HOST   (FIPS, extproc)
dgrun -t deploy/cleanup_local.sh             # ON PRIMARY_HOST, then ON STANDBY_HOST   (asks YES; detach + remove old homes, opt-in)
dgrun deploy/aide_local.sh                   # ON PRIMARY_HOST, then ON STANDBY_HOST   (about 60 min)
```

### Using the runbook (`dg_patch_runbook.sh`)
The runbook prints the exact `systemd-run` command for the background steps (prep and AIDE) and
for peer steps. It still runs some local steps in the foreground (for example phases 10, 18 and 21). On a
hardened host, run any long step yourself with `dgrun` and continue the runbook with `--from-phase <n+1>`.

### Dry run any step
```bash
dgrun deploy/deploy_s_local.sh --dry-run     # prints the plan, changes nothing
```

### Practicing on the home lab
The lab has no hardening, so recreate it first (as root, on each lab node):
```bash
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nKillUserProcesses=yes\nStopIdleSessionSec=600\n' > /etc/systemd/logind.conf.d/99-lab-hardening.conf
printf 'readonly TMOUT=600\nexport TMOUT\n' > /etc/profile.d/99-lab-tmout.sh
systemctl restart systemd-logind          # or reboot; log in again so TMOUT applies
```
`StopIdleSessionSec` needs systemd 252 or newer and is ignored on older releases. `KillUserProcesses=yes`
plus `TMOUT=600` reproduces the behavior.

Then compare the two methods in a fresh login:
```bash
nohup sleep 1500 > /dev/null 2>&1 &                      # dies at the idle logout
systemd-run --unit=survivor --remain-after-exit sleep 1500
# wait for the idle logout at 10 minutes, log in again as root, then:
pgrep -a sleep ; systemctl status survivor --no-pager    # nohup sleep gone, survivor still running
systemctl stop survivor
```
Suggested practice order on the lab (one node pair, standby first): `dgrun ... --dry-run` for a few scripts,
then `dgrun prep/prep_s_local.sh` and `dgrun prep/prep_p_local.sh` while you let your session idle out and
reconnect, then `dgrun -t switch_test/switchtest_local.sh` to practice the interactive form.
Remove the lab hardening afterwards: delete the two files above and restart `systemd-logind`.

---

## Resuming After a Failure

`deploy_s_local.sh` and `deploy_p_local.sh` support `--from-step N`:
```bash
bash deploy/deploy_p_local.sh --from-step 11   # resume at GI switch (Step 11)
bash deploy/deploy_s_local.sh --from-step 6    # resume at GI switch (Step 6)
```
Step numbers are listed in each script's header comment.

---

## SYS Password Handling

The scripts prompt for the SYS password once per session via `read -s`.
The password is stored in memory only as `DG_SYS_PASSWORD` and never
written to disk or logged. It is required for DG Broker switchover and
switchback because the Broker must authenticate to the remote instance
using the password file (`dgmgrl /` OS authentication is insufficient
for cross-instance connections).

To avoid being prompted (e.g. in automated pipelines):
```bash
export DG_SYS_PASSWORD="your_password"
bash deploy/switchover_local.sh   # skips prompt
```

---

## Key Design Decisions

### GI Home Switch
The prep phase builds and patches new homes using `gridSetup.sh -applyRU`.
The deploy phase switches the active GI home using `gridSetup.sh -switchGridHome`,
which reconfigures CRS to start from the new home. `root.sh` then restarts
CRS from the new home. **Do not use opatchauto** for this — opatchauto applies
patches in-place and is not the correct tool for switching pre-patched OOP homes.

The `run_gi_switch` function in `lib_common.sh` automates the entire sequence:
it starts `gridSetup.sh` in the background, polls for the root.sh prompt,
runs root.sh, and verifies ohasd.bin is running from the new home.

### datapatch
datapatch runs directly on the current primary after switchover.
Before running datapatch, `DBMS_QOPATCH.load_xml_inventory` reloads the
xml inventory in the database, preventing `ORA-20001` stale inventory errors
that occur after an OOP home switch.

### chopt (post_install_local.sh)
chopt must be run on **each node's binary independently**. Binary changes
do not propagate via redo. For Non-CDB environments, disabling partitioning
(`chopt disable partitioning`) is safe. For CDB environments, do not disable
partitioning — the CDB dictionary uses partitioned objects internally.

### ADR_BASE Ownership
`/u01/app/oracle/diag` (or wherever `ADR_BASE` points) must be owned by
`oracle:oinstall`, not `grid:oinstall`. If owned by grid, kfod fails to
initialize ADR and AutoUpgrade analyze fails with COM-115. The deploy scripts
fix this automatically in Step 3d.

---

## v3 Changes

0. **SYS.DB_DDL_ALERT_TRG.** `deploy_s_peer.sh` (on the primary, before the switchover, only when all its checks pass) disables the trigger in the non-CDB, or in the CDB root and every READ WRITE PDB. The DDL replicates to the standby through redo. `post_install_local.sh` Step G enables it again on the primary after patching (it refuses if the node is not PRIMARY). Containers without the trigger are skipped, PDBs that are not READ WRITE are reported. The helper is `ddl_trigger` in `lib_common.sh`.
0b. **`cleanup_local.sh`:** `deinstall` is gone. Each old home is detached with `runInstaller -silent -detachHome ORACLE_HOME=<old home>` (from the new home, as the owner of the old home), and only if both detaches succeed are the old directories removed. The previous version looked up home names with a broken quote, so inventory entries were never detached. The script asks for YES, so start it with `dgrun -t`.

1. `prep_s_local.sh`, `prep_p_local.sh`: `gridSetup.sh` and `runInstaller` exit code 6 (success with optional prerequisite warnings) is accepted via the new `check_installer_rc` helper in `lib_common.sh`. Previously `&& pass || fail` treated 6 as a failure and stopped the prep.
2. `lib_common.sh`: `run_gi_switch` logs the `gridSetup.sh -switchGridHome` exit code (0 and 6 are success).
3. All `nohup ... &` instructions in script headers, log messages and the runbook are replaced by `systemd-run`. Steps are started with `dgrun`, steps that prompt for the SYS password with `dgrun -t`.

## v2 Changes from v1 (from trial run 2026-08-21)

1. `lib_common.sh`: `get_dg_lag` fixed to return full `+00 00:00:00` (was truncating to `+00`)
2. `lib_common.sh`: added `require_dg_password`, `rundgmgrl_auth`, `run_gi_switch`
3. `deploy_s_local.sh`, `deploy_p_local.sh`: replaced opatchauto with `run_gi_switch`; added `--from-step N`; removed stray fragment after password file copy
4. `deploy_p_local.sh`: Step 2b opens standby READ ONLY if MOUNTED; Step 3d fixes ADR ownership
5. `switchtest_local.sh`, `switchover_local.sh`, `switchback_local.sh`: `-n` guard on lag check; `rundgmgrl_auth` for switchover/switchback; 30s delay before archive log switch
6. `validate_local.sh`: DG Broker grep fixed for multi-line output; `FAIL` -> `fail`
7. `datapatch_peer.sh`: removed AutoUpgrade wrapper (`run_datapatch` not supported in patch mode); added `DBMS_QOPATCH.load_xml_inventory` reload step
8. `cleanup_local.sh`: dynamic inventory home name detection; improved deinstall sequence
9. `prep_p_local.sh`, `prep_s_local.sh`: removed `GI_RU_PATCH` (bundle dir ID) from `opatch lspatches` verification; only `GI_APPLY_RU_PATCH` (sub-patch ID) is checked
10. `patch.conf`: all environment-specific values in clearly labelled sections; no hardcoded values in any script
