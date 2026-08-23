# Oracle 19c Data Guard OOP Patch Automation

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

### Phase 0 — Setup (both nodes, run once per cycle)
```bash
bash setup/deploy_scripts.sh   # ON PRIMARY_HOST
bash setup/deploy_scripts.sh   # ON STANDBY_HOST
```
Both must print: `RESULT: ALL CHECKS PASSED`

### Phase 1 — Prep (both nodes in parallel, no downtime, ~90 min each)
```bash
# Start these simultaneously in separate terminals:
bash prep/prep_s_local.sh      # ON STANDBY_HOST  (background recommended)
bash prep/prep_p_local.sh      # ON PRIMARY_HOST   (background recommended)
```
Then, after both complete:
```bash
bash prep/prep_verify_peer.sh  # ON PRIMARY_HOST   (DG health check)
```

### Phase 2 — Switch Test (pre-downtime, optional but strongly recommended)
```bash
bash switch_test/switchtest_local.sh   # ON PRIMARY_HOST  (prompts for SYS password)
bash switch_test/switchtest_peer.sh    # ON STANDBY_HOST
```
This performs a test switchover + switchback with ~2 min outage.
Run this during a low-traffic window before the actual maintenance window.

### Phase 3 — Deploy (maintenance window — brief downtime during switchover)
```bash
# 1. Patch standby DB home (no production impact):
bash deploy/deploy_s_local.sh          # ON STANDBY_HOST

# 2. Verify standby patched and primary still healthy:
bash deploy/deploy_s_peer.sh           # ON PRIMARY_HOST

# 3. SWITCHOVER — production downtime starts here:
bash deploy/switchover_local.sh        # ON PRIMARY_HOST  (prompts for SYS password)

# 4. Patch old primary DB home (now standby, no impact):
bash deploy/deploy_p_local.sh          # ON PRIMARY_HOST

# 5. Verify redo flowing to old primary:
bash deploy/deploy_p_peer.sh           # ON STANDBY_HOST (current primary)

# 6. Apply data dictionary patches (15-30 min):
bash deploy/datapatch_peer.sh          # ON STANDBY_HOST (current primary)

# 7. Verify redo applied to old primary:
bash deploy/datapatch_local.sh         # ON PRIMARY_HOST

# 8. SWITCHBACK — production downtime ends here:
bash deploy/switchback_local.sh        # ON PRIMARY_HOST  (prompts for SYS password)
```

### Phase 4 — Validation
```bash
bash deploy/validate_local.sh          # ON PRIMARY_HOST
bash deploy/validate_peer.sh           # ON STANDBY_HOST
```

### Phase 5 — Post-Patch Hardening (both nodes, no downtime)
```bash
bash deploy/post_install_local.sh      # ON PRIMARY_HOST  (chopt, utlrp, registry)
bash deploy/post_install_local.sh      # ON STANDBY_HOST

bash deploy/security_local.sh         # ON PRIMARY_HOST  (FIPS, extproc)
bash deploy/security_local.sh         # ON STANDBY_HOST

bash deploy/cleanup_local.sh          # ON PRIMARY_HOST  (deinstall old homes, opt-in)
bash deploy/cleanup_local.sh          # ON STANDBY_HOST

nohup bash deploy/aide_local.sh > /dev/null 2>&1 &   # ON PRIMARY_HOST (~60 min)
nohup bash deploy/aide_local.sh > /dev/null 2>&1 &   # ON STANDBY_HOST (~60 min)
```

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
