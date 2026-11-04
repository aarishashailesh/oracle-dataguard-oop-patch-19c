[README.md](https://github.com/user-attachments/files/34372350/README.md)
# Oracle 19c Data Guard OOP Patch Automation

Out-of-place (OOP) patching of Oracle 19c Grid Infrastructure and Database
in a two-node Data Guard environment using a standby-first, DG Broker switchover
strategy. Scripts run as root with internal su switching to oracle/grid users.
No passwordless SSH between nodes is required.

---

## Adapting to a New Environment

**Only patch.conf requires editing.** No values are hardcoded in any script.
All scripts source patch.conf at startup.# Oracle 19c Data Guard OOP Patch Automation

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

Keep the functions across logins (run once on each node, in the shell where you just defined them):
```bash
declare -f dgprocs dgrun dgstat dgclean > /etc/profile.d/dgpatch.sh
bash -n /etc/profile.d/dgpatch.sh && grep -c "find" /etc/profile.d/dgpatch.sh    # 1 means the fixed dgprocs
```
Do not generate this file from an older copy of this README: older versions contain a `dgprocs` that does not count processes in sub-cgroups and reports 0 for a unit that still owns the instance.
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

### Cleaning up after the patch cycle (both nodes, as root)
Do this last, after validation and post-patch hardening, and in this order. `dgclean` is one of the
functions in `/etc/profile.d/dgpatch.sh`, so remove that file only at the end.

1. Clear the finished units. `dgclean` stops only units that own no processes and keeps the rest.
   ```bash
   dgclean
   for u in $(systemctl list-units 'dgpatch-*' --all --state=failed --plain --no-legend | awk '{print $1}'); do
     systemctl reset-failed "$u"          # clears units left in the failed state
   done
   systemctl list-units 'dgpatch-*' --all --no-pager      # what is left
   ```
2. Leave any unit that `dgclean` reports as `kept <unit> (N processes still running in it)`. Deploy and switch
   steps start the Oracle instance inside the unit (for example `dgpatch-deploy-s-local` on the standby), and
   `systemctl stop` on such a unit kills the database. The unit disappears the next time the instance is
   restarted through CRS or the host reboots (transient units live in `/run`). A leftover unit is harmless.
3. Remove the shell functions and the profile file:
   ```bash
   rm -f /etc/profile.d/dgpatch.sh
   unset -f dgprocs dgrun dgstat dgclean          # only affects the current shell
   ```
4. Remove temporary files left by manual steps (the scripts remove their own):
   ```bash
   rm -rf /tmp/ddl_trg_create.sql /tmp/ddl_trg_create_logs /tmp/dgnew /tmp/patch.conf.keep /tmp/olap_off*
   ```
5. Home lab only: if you set up the hardening practice (see "Practicing on the home lab"), delete
   `/etc/systemd/logind.conf.d/99-lab-hardening.conf` and `/etc/profile.d/99-lab-tmout.sh`, then run
   `systemctl restart systemd-logind`.

Keep the logs under `LOG_BASE` (`/u01/patching/logs/logs<cycle>`). Keep `SYS.DB_DDL_ALERT_TRG` and
`SYS.DB_DDL_AUDIT_LOG`: they are meant to stay, and `post_install_local.sh` Step G leaves the trigger enabled.

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

Keep the functions across logins (run once on each node, in the shell where you just defined them):
```bash
declare -f dgprocs dgrun dgstat dgclean > /etc/profile.d/dgpatch.sh
bash -n /etc/profile.d/dgpatch.sh && grep -c "find" /etc/profile.d/dgpatch.sh    # 1 means the fixed dgprocs
```
Do not generate this file from an older copy of this README: older versions contain a `dgprocs` that does not count processes in sub-cgroups and reports 0 for a unit that still owns the instance.
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
