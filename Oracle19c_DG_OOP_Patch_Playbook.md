# Oracle 19c GI and DB OOP Patch — Office Production Playbook
## Patching 19.31 → 19.32 | Two-Node Data Guard | Non-CDB

---

> **This is a manual step-by-step playbook.**
> All paths, hostnames, SIDs, and patch numbers are pre-resolved from the
> office environment. No automation scripts required.

---


> **CRITICAL CORRECTIONS vs patch.conf — Apply Before Starting**
>
> | Item | patch.conf value | Correct value |
> |---|---|---|
> | `STANDBY_SID` | `CDBSTBY` | `maxprod` (confirmed from /etc/oratab on rsrcndbmax01mc) |
> | `OLD_DB_HOME` | double-slash + `19.0.0` | `/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931` |
> | `NEW_DB_HOME` | `19.0.0` | `/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932` |
> | `ORACLE_BASE` | `/u01/app/oracle` | `/u01/app/odaorabase/oracle` |
> | `ADR_BASE` | `/u01/app/oracle/diag` | `/u01/app/odaorabase/oracle/diag` |
> | `STANDBY_DB_UNIQUE_NAME` | `CDBSTBY` | Verify on standby: `SELECT DB_UNIQUE_NAME FROM V$DATABASE` |
>
> **Note on STANDBY_SID vs DB_UNIQUE_NAME:** Both nodes use ORACLE_SID=`maxprod`.
> The DB_UNIQUE_NAME is different (used by dgmgrl switchover commands).
> Run `SELECT DB_UNIQUE_NAME FROM V$DATABASE` on rsrcndbmax01mc to get the exact value
> before attempting switchover.

---

## Patch Conf Issues — Fix Before Starting

Two corrections identified in `office_patch.conf`:

| Item | Current Value | Correct Value |
|---|---|---|
| `OLD_DB_HOME` | `/u01/app//odaorahome/...` | `/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931` (remove double slash) |
| `STANDBY_SID` | `CDBSTBY` (lab value) | **maxprod** (confirmed from /etc/oratab) |
| `OLD_DB_HOME` | `/u01/app//odaorahome/.../19.0.0/...` | `/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931` |
| `ORACLE_BASE` | `/u01/app/oracle` | `/u01/app/odaorabase/oracle` |

Confirm the actual standby SID before proceeding:
```bash
# On rsrcndbmax01mc as root:
grep -v "^#" /etc/oratab | grep -v "^$"
su - oracle -c "env | grep ORACLE_SID"
```
Based on Global DB Name `maxprodm.rsrc.osd.mil`, standby SID is likely **maxprodm**.
This playbook uses **maxprodm** — adjust if different.

---

## Environment Reference

| Variable | Value |
|---|---|
| **Primary Host** | `rsrcndbmax01pn` |
| **Standby Host** | `rsrcndbmax01mc` |
| **Primary SID / DB_UNIQUE_NAME** | `maxprod` |
| **Standby SID / DB_UNIQUE_NAME** | SID=`maxprod` / DB_UNIQUE_NAME=*(confirm via V$DATABASE)* |
| **Primary Global DB Name** | `maxprodp.rsrc.osd.mil` |
| **Standby Global DB Name** | `maxprodm.rsrc.osd.mil` |
| **Old GI Home** | `/u01/app/19.31.0/grid` |
| **New GI Home** | `/u01/app/19.32.0/grid` |
| **Old DB Home** | `/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931` |
| **New DB Home** | `/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932` |
| **Oracle Base** | `/u01/app/odaorabase/oracle` |
| **ADR Base** | `/u01/app/odaorabase/oracle/diag` |
| **Patch Stage Dir** | `/opt/oracle/patches` |
| **Log Base** | `/u01/patching/logs` |
| **Autoupgrade JAR** | `/opt/oracle/patches/autoupgrade.jar` |
| **GI Response File (primary)** | `/opt/oracle/patches/rsrcndbmax01pn_grid_install.rsp` |
| **GI Response File (standby)** | `/opt/oracle/patches/rsrcndbmax01mc_grid_install.rsp` |
| **DB Response File (primary)** | `/opt/oracle/patches/rsrcndbmax01pn_db_install.rsp` |
| **DB Response File (standby)** | `/opt/oracle/patches/rsrcndbmax01mc_db_install.rsp` |
| **RU Combo Patch** | `p39618711_190000_Linux-x86-64.zip` |
| **GI Apply RU Patch (OCW)** | `39526364` |
| **DB Apply RU Patch** | `39472050` |
| **OJVM Patch** | `39222882` |
| **Datapump Bundle** | `39657094` |
| **OPatch Zip** | `p6880880_190000_Linux-x86-64.zip` |
| **Old Patch Level** | `19.31` |
| **New Patch Level** | `19.32` |
| **Grid User** | `grid` |
| **Oracle User** | `oracle` |
| **Install Group** | `oinstall` |
| **CV_ASSUME_DISTID** | `OEL7.8` |

---

## Stage Directory Layout Required on BOTH Nodes

Verify the following files exist at `/opt/oracle/patches/` on both
`rsrcndbmax01pn` and `rsrcndbmax01mc` before starting.

```
/opt/oracle/patches/
  base_releases/
    LINUX.X64_193000_grid_home.zip
    LINUX.X64_193000_db_home.zip
  opatch/
    p6880880_190000_Linux-x86-64.zip
  p39618711_190000_Linux-x86-64.zip      # RU combo
  p39657094_1932000DBRU_Generic.zip      # Datapump bundle
  autoupgrade.jar
  rsrcndbmax01pn_grid_install.rsp        # primary GI response file
  rsrcndbmax01pn_db_install.rsp          # primary DB response file
  rsrcndbmax01mc_grid_install.rsp        # standby GI response file
  rsrcndbmax01mc_db_install.rsp          # standby DB response file
```

---

## Prerequisites Checklist

Complete all of these before beginning Phase 1.

### 1. DG Broker Health — on rsrcndbmax01pn as oracle

```bash
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931
export ORACLE_SID=maxprod
$ORACLE_HOME/bin/dgmgrl /
```
Inside dgmgrl:
```
DGMGRL> SHOW CONFIGURATION;
```
Expected: `Configuration Status: SUCCESS`

```
DGMGRL> VALIDATE DATABASE 'maxprodm';
```
Expected: `Ready for Switchover: Yes`

```
DGMGRL> EXIT;
```

### 2. Verify Password Files Are In Sync

On `rsrcndbmax01pn` as root:
```bash
md5sum /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931/dbs/orapwmaxprod
```

On `rsrcndbmax01mc` as root:
```bash
md5sum /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931/dbs/orapwmaxprod
```

**Both md5sums must match.** If they differ, copy from primary:
```bash
# On rsrcndbmax01pn as root:
scp /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931/dbs/orapwmaxprod \
    root@rsrcndbmax01mc:/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931/dbs/orapwmaxprod
ssh root@rsrcndbmax01mc \
    "chown oracle:oinstall /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931/dbs/orapwmaxprod && \
     chmod 640 /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931/dbs/orapwmaxprod"
```

### 3. Verify Static Listener Service for DG Broker — on rsrcndbmax01mc as grid

```bash
su - grid
grep -A8 "SID_LIST" /u01/app/19.31.0/grid/network/admin/listener.ora
```
Must contain a static entry for the DG Broker service:
```
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = maxprodm_DGMGRL)
      (ORACLE_HOME = /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931)
      (SID_NAME = maxprodm)
    )
  )
```
If missing, add it and reload the listener:
```bash
# As grid on rsrcndbmax01mc:
srvctl stop listener
# Edit /u01/app/19.31.0/grid/network/admin/listener.ora and add above block
srvctl start listener
```

### 4. Verify StaticConnectIdentifier in DG Broker — on rsrcndbmax01pn as oracle

```bash
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931
export ORACLE_SID=maxprod
$ORACLE_HOME/bin/dgmgrl / "show database verbose maxprodm" | grep -i "staticconnect\|host\|port"
```
Must show `maxprodm_DGMGRL` service and correct hostname/port.

### 5. Verify Switchover Works (pre-test) — on rsrcndbmax01pn as oracle

```bash
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931
export ORACLE_SID=maxprod
$ORACLE_HOME/bin/dgmgrl sys/<SYS_PASSWORD>@maxprod
```
Inside dgmgrl:
```
DGMGRL> SWITCHOVER TO 'maxprodm';
```
Verify it succeeds (new primary: maxprodm). Then switchback:
```
DGMGRL> SWITCHOVER TO 'maxprod';
DGMGRL> SHOW CONFIGURATION;
DGMGRL> EXIT;
```

### 6. Disk Space — on BOTH nodes as root

```bash
df -BG /u01 /opt
```
Minimum **30 GB free** on both `/u01` and `/opt`.

### 7. Verify ADR Base Ownership — on BOTH nodes as root

```bash
ls -la /u01/app/oracle/ | grep diag
```
Must show `oracle:oinstall`. If `grid:oinstall`:
```bash
chown -R oracle:oinstall /u01/app/odaorabase/oracle/diag
```

---

## Phase 0: Setup Verification

Verify stage files and home paths on both nodes.

### rsrcndbmax01pn — as root

```bash
# Verify stage files exist:
ls -lh /opt/oracle/patches/base_releases/LINUX.X64_193000_grid_home.zip
ls -lh /opt/oracle/patches/base_releases/LINUX.X64_193000_db_home.zip
ls -lh /opt/oracle/patches/opatch/p6880880_190000_Linux-x86-64.zip
ls -lh /opt/oracle/patches/p39618711_190000_Linux-x86-64.zip
ls -lh /opt/oracle/patches/p39657094_1932000DBRU_Generic.zip
ls -lh /opt/oracle/patches/autoupgrade.jar
ls -lh /opt/oracle/patches/rsrcndbmax01pn_grid_install.rsp
ls -lh /opt/oracle/patches/rsrcndbmax01pn_db_install.rsp

# Verify current homes exist:
ls -d /u01/app/19.31.0/grid
ls -d /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931

# Verify new homes do NOT yet exist:
ls -d /u01/app/19.32.0/grid         # must show: No such file
ls -d /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932  # must show: No such file

# Create log directory:
mkdir -p /u01/patching/logs/rsrcndbmax01pn
chown oracle:oinstall /u01/patching/logs/rsrcndbmax01pn
```

### rsrcndbmax01mc — as root

```bash
# Verify stage files exist:
ls -lh /opt/oracle/patches/base_releases/LINUX.X64_193000_grid_home.zip
ls -lh /opt/oracle/patches/base_releases/LINUX.X64_193000_db_home.zip
ls -lh /opt/oracle/patches/opatch/p6880880_190000_Linux-x86-64.zip
ls -lh /opt/oracle/patches/p39618711_190000_Linux-x86-64.zip
ls -lh /opt/oracle/patches/p39657094_1932000DBRU_Generic.zip
ls -lh /opt/oracle/patches/autoupgrade.jar
ls -lh /opt/oracle/patches/rsrcndbmax01mc_grid_install.rsp
ls -lh /opt/oracle/patches/rsrcndbmax01mc_db_install.rsp

# Verify current homes exist:
ls -d /u01/app/19.31.0/grid
ls -d /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931

# Verify new homes do NOT yet exist:
ls -d /u01/app/19.32.0/grid
ls -d /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932

# Create log directory:
mkdir -p /u01/patching/logs/rsrcndbmax01mc
chown oracle:oinstall /u01/patching/logs/rsrcndbmax01mc
```

> **Take a VM/storage snapshot of both nodes here before proceeding.**

---

## Phase 1: Software Provisioning and Preparation
### No Downtime — Run Both Nodes in Parallel (~90 minutes each)

Start Phase 1 on **rsrcndbmax01mc first** in one terminal, then
immediately start on **rsrcndbmax01pn** in another terminal without waiting.

---

### 1.1 Extract RU Combo Patch — BOTH NODES as root

Run on each node independently:
```bash
cd /opt/oracle/patches

# Extract the RU combo zip:
unzip -q p39618711_190000_Linux-x86-64.zip

# Extract the Datapump standalone patch:
unzip -q p39657094_1932000DBRU_Generic.zip

# Fix ownership and permissions on extracted patch directories:
chown -R root:oinstall /opt/oracle/patches/39618711/
chown -R root:oinstall /opt/oracle/patches/39657094/
find /opt/oracle/patches/39618711 -type f -exec chmod o+r {} +
find /opt/oracle/patches/39618711 -type d -exec chmod o+rx {} +
find /opt/oracle/patches/39657094 -type f -exec chmod o+r {} +
```

Verify extraction:
```bash
ls /opt/oracle/patches/39618711/39467003/39526364/   # GI OCW patch
ls /opt/oracle/patches/39618711/39467003/39472050/   # DB RU patch
ls /opt/oracle/patches/39618711/39222882/            # OJVM patch
ls /opt/oracle/patches/39657094/                     # Datapump patch
```

---

### 1.2 Build New Grid Home — BOTH NODES

#### Step A: Create directory and extract base GI software — as root

```bash
mkdir -p /u01/app/19.32.0/grid
chown grid:oinstall /u01/app/19.32.0/grid

su - grid -c "unzip -q /opt/oracle/patches/base_releases/LINUX.X64_193000_grid_home.zip \
    -d /u01/app/19.32.0/grid/"
```

#### Step B: Upgrade OPatch in new GI home — as grid

```bash
su - grid -c "unzip -o -q /opt/oracle/patches/opatch/p6880880_190000_Linux-x86-64.zip \
    -d /u01/app/19.32.0/grid/"
su - grid -c "/u01/app/19.32.0/grid/OPatch/opatch version"
```
Expected: `OPatch Version: 12.2.0.1.xx`

#### Step C: Create CRS_SWONLY response file — as root

On **rsrcndbmax01pn**:
```bash
cp /opt/oracle/patches/rsrcndbmax01pn_grid_install.rsp \
   /tmp/grid_swonly_pn.rsp
sed -i "s|^ORACLE_HOME=.*|ORACLE_HOME=/u01/app/19.32.0/grid|" /tmp/grid_swonly_pn.rsp
sed -i "s|^oracle.install.option=.*|oracle.install.option=CRS_SWONLY|" /tmp/grid_swonly_pn.rsp
chown grid:oinstall /tmp/grid_swonly_pn.rsp
chmod 640 /tmp/grid_swonly_pn.rsp
```

On **rsrcndbmax01mc**:
```bash
cp /opt/oracle/patches/rsrcndbmax01mc_grid_install.rsp \
   /tmp/grid_swonly_mc.rsp
sed -i "s|^ORACLE_HOME=.*|ORACLE_HOME=/u01/app/19.32.0/grid|" /tmp/grid_swonly_mc.rsp
sed -i "s|^oracle.install.option=.*|oracle.install.option=CRS_SWONLY|" /tmp/grid_swonly_mc.rsp
chown grid:oinstall /tmp/grid_swonly_mc.rsp
chmod 640 /tmp/grid_swonly_mc.rsp
```

#### Step D: Apply GI RU to new home (software only, no root.sh) — as grid

On **rsrcndbmax01pn** (run in background — takes ~30 min):
```bash
nohup su - grid -c "
export CV_ASSUME_DISTID=OEL7.8
/u01/app/19.32.0/grid/gridSetup.sh \
  -applyRU /opt/oracle/patches/39618711/39467003/39526364 \
  -silent -skipPrereqs \
  -responseFile /tmp/grid_swonly_pn.rsp
" > /u01/patching/logs/rsrcndbmax01pn/gridsetup_prep.log 2>&1 &
echo "gridSetup PID: $!"
tail -f /u01/patching/logs/rsrcndbmax01pn/gridsetup_prep.log
```

On **rsrcndbmax01mc** (run in background — takes ~30 min):
```bash
nohup su - grid -c "
export CV_ASSUME_DISTID=OEL7.8
/u01/app/19.32.0/grid/gridSetup.sh \
  -applyRU /opt/oracle/patches/39618711/39467003/39526364 \
  -silent -skipPrereqs \
  -responseFile /tmp/grid_swonly_mc.rsp
" > /u01/patching/logs/rsrcndbmax01mc/gridsetup_prep.log 2>&1 &
echo "gridSetup PID: $!"
tail -f /u01/patching/logs/rsrcndbmax01mc/gridsetup_prep.log
```

Wait for the message: `Successfully Setup Software.`

> **Do NOT run root.sh at this stage.** root.sh runs during the deploy phase.

Verify GI home patches:
```bash
su - grid -c "export ORACLE_HOME=/u01/app/19.32.0/grid; \
    /u01/app/19.32.0/grid/OPatch/opatch lspatches"
```
Expected patches in new GI home: `39526364`, `39503034`, `39472050`, `39107855`, `39107825`

---

### 1.3 Build New DB Home — BOTH NODES

#### Step A: Create directory and extract base DB software — as root

```bash
mkdir -p /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
chown oracle:oinstall /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932

su - oracle -c "unzip -q \
    /opt/oracle/patches/base_releases/LINUX.X64_193000_db_home.zip \
    -d /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/"
```

#### Step B: Upgrade OPatch in new DB home — as oracle

```bash
su - oracle -c "unzip -o -q \
    /opt/oracle/patches/opatch/p6880880_190000_Linux-x86-64.zip \
    -d /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/"
su - oracle -c "/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/OPatch/opatch version"
```

#### Step C: Apply DB RU to new home — as oracle (takes ~30 min)

On **rsrcndbmax01pn**:
```bash
nohup su - oracle -c "
export CV_ASSUME_DISTID=OEL7.8
/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/runInstaller \
  -applyRU /opt/oracle/patches/39618711/39467003/39472050 \
  -applyOneOffs /opt/oracle/patches/39618711/39467003/39526364,\
/opt/oracle/patches/39618711/39222882,\
/opt/oracle/patches/39657094 \
  -silent -skipPrereqs \
  -responseFile /opt/oracle/patches/rsrcndbmax01pn_db_install.rsp
" > /u01/patching/logs/rsrcndbmax01pn/runinstaller_prep.log 2>&1 &
echo "runInstaller PID: $!"
tail -f /u01/patching/logs/rsrcndbmax01pn/runinstaller_prep.log
```

On **rsrcndbmax01mc**:
```bash
nohup su - oracle -c "
export CV_ASSUME_DISTID=OEL7.8
/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/runInstaller \
  -applyRU /opt/oracle/patches/39618711/39467003/39472050 \
  -applyOneOffs /opt/oracle/patches/39618711/39467003/39526364,\
/opt/oracle/patches/39618711/39222882,\
/opt/oracle/patches/39657094 \
  -silent -skipPrereqs \
  -responseFile /opt/oracle/patches/rsrcndbmax01mc_db_install.rsp
" > /u01/patching/logs/rsrcndbmax01mc/runinstaller_prep.log 2>&1 &
echo "runInstaller PID: $!"
tail -f /u01/patching/logs/rsrcndbmax01mc/runinstaller_prep.log
```

Wait for: `Successfully Setup Software.`

#### Step D: Run root.sh for new DB home — as root on BOTH nodes

```bash
/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/root.sh
```

Verify DB home patches:
```bash
su - oracle -c "export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932; \
    /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/OPatch/opatch lspatches"
```
Expected: `39472050`, `39222882`, `39657094`, `39526364`

---

### 1.4 Upgrade OPatch in Old Homes — BOTH NODES as root

```bash
# Old GI home:
su - grid -c "unzip -o -q \
    /opt/oracle/patches/opatch/p6880880_190000_Linux-x86-64.zip \
    -d /u01/app/19.31.0/grid/"
su - grid -c "/u01/app/19.31.0/grid/OPatch/opatch version"

# Old DB home:
su - oracle -c "unzip -o -q \
    /opt/oracle/patches/opatch/p6880880_190000_Linux-x86-64.zip \
    -d /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931/"
su - oracle -c "/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931/OPatch/opatch version"
```

---

### 1.5 Update listener.ora — BOTH NODES as root

Update the static DB home reference in listener.ora so it points to the new DB home.
This ensures the listener picks up the correct home path after the GI switch.

```bash
# Check current content:
grep "odaorahome" /u01/app/19.31.0/grid/network/admin/listener.ora

# Replace old DB home path with new DB home path:
sed -i 's|/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931|\
/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932|g' \
    /u01/app/19.31.0/grid/network/admin/listener.ora

# Also update in new GI home (will be active after GI switch):
cp /u01/app/19.31.0/grid/network/admin/listener.ora \
   /u01/app/19.32.0/grid/network/admin/listener.ora

# Verify:
grep "ORACLE_HOME\|SID_NAME" /u01/app/19.31.0/grid/network/admin/listener.ora
```

---

### 1.6 Verify DG Still Healthy After Prep — on rsrcndbmax01pn as oracle

```bash
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931
export ORACLE_SID=maxprod
$ORACLE_HOME/bin/dgmgrl /
```
Inside dgmgrl:
```
DGMGRL> SHOW CONFIGURATION;
```
Expected: `Configuration Status: SUCCESS`
```
DGMGRL> EXIT;
```

Check no archive gap:
```bash
$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT COUNT(*) "ARCHIVE_GAP" FROM V$ARCHIVE_GAP;
EXIT;
EOF
```
Expected: `0`

---

## Phase 2: Switch Test (Highly Recommended Before Maintenance Window)

This performs a test switchover and immediate switchback to validate
the DG Broker mechanism before the real maintenance window.
Results in approximately 1-2 minutes of downtime.

### 2.1 Pre-test DG Health — on rsrcndbmax01pn as oracle

```bash
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931
export ORACLE_SID=maxprod

$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT COUNT(*) "ARCHIVE_GAP" FROM V$ARCHIVE_GAP;
EXIT;
EOF
```

### 2.2 Test Switchover to Standby — on rsrcndbmax01pn as oracle

```bash
$ORACLE_HOME/bin/dgmgrl sys/<SYS_PASSWORD>@maxprod
```
Inside dgmgrl:
```
DGMGRL> SHOW CONFIGURATION;
DGMGRL> SWITCHOVER TO 'maxprodm';
```
Wait for: `Switchover succeeded, new primary is "maxprodm"`

Verify rsrcndbmax01pn is now standby:
```
DGMGRL> SHOW CONFIGURATION;
```
Expected: `maxprodm - Primary database` / `maxprod - Physical standby database`

### 2.3 Verify Standby MRP on rsrcndbmax01mc — as oracle

```bash
# On rsrcndbmax01mc:
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931
export ORACLE_SID=maxprod

$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V$DATABASE;
SELECT PROCESS, STATUS, SEQUENCE# FROM V$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';
EXIT;
EOF
```
Expected: `READ ONLY WITH APPLY` / `PHYSICAL STANDBY` / `MRP0 APPLYING_LOG`

### 2.4 Test Switchback to Primary — on rsrcndbmax01pn as oracle

```bash
# On rsrcndbmax01pn - dgmgrl is still connected to maxprodm as primary:
$ORACLE_HOME/bin/dgmgrl sys/<SYS_PASSWORD>@maxprod
```
Inside dgmgrl:
```
DGMGRL> SWITCHOVER TO 'maxprod';
```
Wait for: `Switchover succeeded, new primary is "maxprod"`

Verify original roles restored:
```
DGMGRL> SHOW CONFIGURATION;
DGMGRL> EXIT;
```
Expected: `maxprod - Primary database` / `Configuration Status: SUCCESS`

---

## Phase 3: Deploy — Maintenance Window

> **Maintenance window begins here.**
> Steps 3.1 through 3.3 (standby patching) have no production impact.
> Actual downtime starts at step 3.4 (switchover) and ends at step 3.8 (switchback).
> Estimated downtime: **3-8 minutes** (DG Broker switchover is fast).

---

### 3.1 Deploy AutoUpgrade on Standby DB Home — on rsrcndbmax01mc as root

#### Step A: Stop MRP — as oracle on rsrcndbmax01mc

```bash
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931
export ORACLE_SID=maxprod

$ORACLE_HOME/bin/sqlplus / as sysdba <<'EOF'
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
EXIT;
EOF
```

Verify MRP stopped:
```bash
$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT COUNT(*) "MRP_COUNT" FROM V$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';
EXIT;
EOF
```
Expected: `0`

#### Step B: Generate AutoUpgrade config file — as oracle on rsrcndbmax01mc

```bash
mkdir -p /u01/patching/logs/rsrcndbmax01mc/autoupgrade

cat > /opt/oracle/patches/au_mc.cfg <<'EOF'
global.autoupg_log_dir=/u01/patching/logs/rsrcndbmax01mc/autoupgrade
global.restoration=no
upg1.source_home=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931
upg1.target_home=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
upg1.sid=maxprod
upg1.log_dir=/u01/patching/logs/rsrcndbmax01mc/autoupgrade
upg1.run_utlrp=yes
upg1.timezone_upg=no
EOF

chown oracle:oinstall /opt/oracle/patches/au_mc.cfg
```

#### Step C: Fix ADR base ownership — as root on rsrcndbmax01mc

```bash
chown -R oracle:oinstall /u01/app/odaorabase/oracle/diag
```

#### Step D: AutoUpgrade analyze (pre-check) — as oracle on rsrcndbmax01mc

```bash
su - oracle -c "
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
export ADR_BASE=/u01/app/odaorabase/oracle/diag
\$ORACLE_HOME/jdk/bin/java -jar /opt/oracle/patches/autoupgrade.jar \
    -config /opt/oracle/patches/au_mc.cfg \
    -mode analyze -noconsole
"
```
Wait for: `Jobs finished: 1` / `Jobs failed: 0`

#### Step E: AutoUpgrade deploy (switches DB home) — as oracle on rsrcndbmax01mc

```bash
su - oracle -c "
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
export ADR_BASE=/u01/app/odaorabase/oracle/diag
\$ORACLE_HOME/jdk/bin/java -jar /opt/oracle/patches/autoupgrade.jar \
    -config /opt/oracle/patches/au_mc.cfg \
    -mode deploy -noconsole
"
```
Wait for: `Jobs finished: 1` / `Jobs failed: 0`

AutoUpgrade stops maxprodm, switches from `dbhome_1931` to `dbhome_1932`,
and restarts maxprodm in managed recovery mode.

#### Step F: Copy password file to new DB home — as root on rsrcndbmax01mc

```bash
cp /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931/dbs/orapwmaxprod \
   /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/dbs/orapwmaxprod

chown oracle:oinstall \
    /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/dbs/orapwmaxprod
chmod 640 \
    /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/dbs/orapwmaxprod
```

#### Step G: Switch GI home on rsrcndbmax01mc — requires two terminals

**Terminal 1 — start gridSetup.sh as grid (background):**
```bash
# On rsrcndbmax01mc as root:
su - grid -c "
export CV_ASSUME_DISTID=OEL7.8
/u01/app/19.32.0/grid/gridSetup.sh \
    -switchGridHome \
    -responseFile /opt/oracle/patches/rsrcndbmax01mc_grid_install.rsp \
    -silent
" &
GS_PID=$!
echo "gridSetup.sh PID: $GS_PID"
```

Wait until you see the message:
```
As a root user, execute the following script(s):
    1. /u01/app/19.32.0/grid/root.sh
```

**Terminal 2 — run root.sh as root:**
```bash
# On rsrcndbmax01mc as root:
/u01/app/19.32.0/grid/root.sh
```
Wait for: `CLSRSC-672: Post-patch steps for patching GI home successfully completed.`

Return to Terminal 1 and press **Enter** to complete gridSetup.sh.

Verify GI switch:
```bash
# On rsrcndbmax01mc as root:
ps -ef | grep ohasd.bin | grep -v grep
```
Expected: `/u01/app/19.32.0/grid/bin/ohasd.bin`

#### Step H: Verify standby running from new homes — as oracle on rsrcndbmax01mc

```bash
su - oracle -c "
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
\$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE;
SELECT PROCESS, STATUS, SEQUENCE# FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';
EXIT;
EOF
"
```
Expected: `READ ONLY WITH APPLY` / `PHYSICAL STANDBY` / `MRP0 APPLYING_LOG`

---

### 3.2 Pre-Switchover Verification — on rsrcndbmax01pn as oracle

```bash
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931
export ORACLE_SID=maxprod

# Check primary role:
$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V$DATABASE;
SELECT COUNT(*) "ARCHIVE_GAP" FROM V$ARCHIVE_GAP;
EXIT;
EOF

# Check DG Broker:
$ORACLE_HOME/bin/dgmgrl / "show configuration"
```
Expected: `READ WRITE` / `PRIMARY` / `Gap: 0` / `SUCCESS`

---

### 3.3 SWITCHOVER — Downtime Begins

> **Production applications will disconnect at this point.**
> Downtime ends when rsrcndbmax01mc opens as READ WRITE (new primary).

**On rsrcndbmax01pn as oracle:**
```bash
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931
export ORACLE_SID=maxprod

$ORACLE_HOME/bin/dgmgrl sys/<SYS_PASSWORD>@maxprod
```
Inside dgmgrl:
```
DGMGRL> SWITCHOVER TO 'maxprodm';
```
Wait for:
```
New primary database "maxprodm" is opening...
Oracle Clusterware is restarting database "maxprod" ...
Switchover succeeded, new primary is "maxprodm"
```

Verify rsrcndbmax01pn is now standby:
```bash
$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V$DATABASE;
EXIT;
EOF
```
Expected: `READ ONLY WITH APPLY` / `PHYSICAL STANDBY`

> **Production applications can now reconnect to rsrcndbmax01mc (new primary).**
> **Downtime ends here.**

---

### 3.4 Deploy AutoUpgrade on Old Primary DB Home — on rsrcndbmax01pn as root

rsrcndbmax01pn is now the physical standby running from `dbhome_1931`.

#### Step A: Stop MRP — as oracle on rsrcndbmax01pn

```bash
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931
export ORACLE_SID=maxprod

$ORACLE_HOME/bin/sqlplus / as sysdba <<'EOF'
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
EXIT;
EOF
```

#### Step B: Ensure standby is OPEN READ ONLY — as oracle on rsrcndbmax01pn

```bash
$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT OPEN_MODE FROM V$DATABASE;
EXIT;
EOF
```
If result is `MOUNTED`:
```bash
$ORACLE_HOME/bin/sqlplus / as sysdba <<'EOF'
ALTER DATABASE OPEN READ ONLY;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
EXIT;
EOF
```

#### Step C: Create pfile from ASM spfile — as oracle on rsrcndbmax01pn

```bash
$ORACLE_HOME/bin/sqlplus / as sysdba <<'EOF'
CREATE PFILE='/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931/dbs/initmaxprod.ora'
FROM SPFILE;
EXIT;
EOF
```

#### Step D: Fix ADR base ownership — as root on rsrcndbmax01pn

```bash
chown -R oracle:oinstall /u01/app/odaorabase/oracle/diag
```

#### Step E: Generate AutoUpgrade config — as oracle on rsrcndbmax01pn

```bash
mkdir -p /u01/patching/logs/rsrcndbmax01pn/autoupgrade

cat > /opt/oracle/patches/au_pn.cfg <<'EOF'
global.autoupg_log_dir=/u01/patching/logs/rsrcndbmax01pn/autoupgrade
global.restoration=no
upg1.source_home=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931
upg1.target_home=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
upg1.sid=maxprod
upg1.log_dir=/u01/patching/logs/rsrcndbmax01pn/autoupgrade
upg1.run_utlrp=yes
upg1.timezone_upg=no
EOF

chown oracle:oinstall /opt/oracle/patches/au_pn.cfg
```

#### Step F: Clear stale AutoUpgrade data — as oracle on rsrcndbmax01pn

```bash
su - oracle -c "
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
\$ORACLE_HOME/jdk/bin/java -jar /opt/oracle/patches/autoupgrade.jar \
    -config /opt/oracle/patches/au_pn.cfg \
    -clear_recovery_data
"
```

#### Step G: AutoUpgrade analyze — as oracle on rsrcndbmax01pn

```bash
su - oracle -c "
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
export ADR_BASE=/u01/app/odaorabase/oracle/diag
\$ORACLE_HOME/jdk/bin/java -jar /opt/oracle/patches/autoupgrade.jar \
    -config /opt/oracle/patches/au_pn.cfg \
    -mode analyze -noconsole
"
```
Wait for: `Jobs finished: 1` / `Jobs failed: 0`

#### Step H: AutoUpgrade deploy — as oracle on rsrcndbmax01pn

```bash
su - oracle -c "
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
export ADR_BASE=/u01/app/odaorabase/oracle/diag
\$ORACLE_HOME/jdk/bin/java -jar /opt/oracle/patches/autoupgrade.jar \
    -config /opt/oracle/patches/au_pn.cfg \
    -mode deploy -noconsole
"
```
Wait for: `Jobs finished: 1` / `Jobs failed: 0`

#### Step I: Copy password file to new DB home — as root on rsrcndbmax01pn

```bash
cp /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931/dbs/orapwmaxprod \
   /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/dbs/orapwmaxprod

chown oracle:oinstall \
    /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/dbs/orapwmaxprod
chmod 640 \
    /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/dbs/orapwmaxprod
```

#### Step J: Switch GI home on rsrcndbmax01pn — two terminals

**Terminal 1 — gridSetup.sh as grid (background):**
```bash
# On rsrcndbmax01pn as root:
su - grid -c "
export CV_ASSUME_DISTID=OEL7.8
/u01/app/19.32.0/grid/gridSetup.sh \
    -switchGridHome \
    -responseFile /opt/oracle/patches/rsrcndbmax01pn_grid_install.rsp \
    -silent
" &
GS_PID=$!
echo "gridSetup.sh PID: $GS_PID"
```

Wait for root.sh prompt, then **Terminal 2:**
```bash
# On rsrcndbmax01pn as root:
/u01/app/19.32.0/grid/root.sh
```
Wait for: `CLSRSC-672: Post-patch steps for patching GI home successfully completed.`

Press **Enter** in Terminal 1 to complete.

Verify:
```bash
ps -ef | grep ohasd.bin | grep -v grep
```
Expected: `/u01/app/19.32.0/grid/bin/ohasd.bin`

#### Step K: Verify rsrcndbmax01pn is standby from new homes — as oracle

```bash
su - oracle -c "
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
\$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE;
SELECT PROCESS, STATUS, SEQUENCE# FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';
EXIT;
EOF
"
```
Expected: `READ ONLY WITH APPLY` / `PHYSICAL STANDBY` / `MRP0 APPLYING_LOG`

---

### 3.5 Verify Redo Flow — on rsrcndbmax01mc as oracle

```bash
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod

# Issue archive log switch to verify transport:
$ORACLE_HOME/bin/sqlplus / as sysdba <<'EOF'
ALTER SYSTEM ARCHIVE LOG CURRENT;
EXIT;
EOF

# Check DG status:
$ORACLE_HOME/bin/dgmgrl /
```
Inside dgmgrl:
```
DGMGRL> SHOW CONFIGURATION;
DGMGRL> EXIT;
```
Expected: `Configuration Status: SUCCESS`

---

### 3.6 Datapatch — on rsrcndbmax01mc as oracle (current primary)

Datapatch applies SQL-level data dictionary changes.
Estimated time: **15-30 minutes**.

#### Step A: Reload xml inventory (prevents ORA-20001)

```bash
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod

$ORACLE_HOME/bin/sqlplus / as sysdba <<'EOF'
EXEC SYS.DBMS_QOPATCH.load_xml_inventory;
EXIT;
EOF
```

#### Step B: Run datapatch

```bash
su - oracle -c "
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
\$ORACLE_HOME/OPatch/datapatch -verbose
"
```
Wait for: `SQL Patching tool complete`

#### Step C: Verify datapatch success

```bash
su - oracle -c "
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
\$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT PATCH_ID, STATUS, SUBSTR(DESCRIPTION,1,55) DESCRIPTION
FROM   DBA_REGISTRY_SQLPATCH
ORDER BY ACTION_TIME DESC
FETCH FIRST 5 ROWS ONLY;
EXIT;
EOF
"
```
Expected latest action for each patch: `SUCCESS`

#### Step D: Recompile invalid objects

```bash
su - oracle -c "
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
\$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
@?/rdbms/admin/utlrp
SELECT COUNT(*) \"INVALID_OBJECTS\" FROM DBA_OBJECTS WHERE STATUS='INVALID';
EXIT;
EOF
"
```
Expected: `0` invalid objects

---

### 3.7 Verify Dictionary Changes Propagated to Standby — on rsrcndbmax01pn as oracle

```bash
su - oracle -c "
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
\$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT PROCESS, STATUS, SEQUENCE# FROM V\$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';
SELECT COUNT(*) \"ARCHIVE_GAP\" FROM V\$ARCHIVE_GAP;
EXIT;
EOF
"
```
Expected: `MRP0 APPLYING_LOG` / `Gap: 0`

---

### 3.8 SWITCHBACK — Restore Original Roles

> Ensure apply lag is zero before proceeding.

**On rsrcndbmax01pn as oracle:**
```bash
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod

# Verify lag is zero:
$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT NAME, VALUE FROM V$DATAGUARD_STATS WHERE NAME IN ('apply lag','transport lag');
EXIT;
EOF

# Switchback:
$ORACLE_HOME/bin/dgmgrl sys/<SYS_PASSWORD>@maxprod
```
Inside dgmgrl:
```
DGMGRL> SWITCHOVER TO 'maxprod';
```
Wait for: `Switchover succeeded, new primary is "maxprod"`

Verify:
```
DGMGRL> SHOW CONFIGURATION;
DGMGRL> EXIT;
```
Expected: `maxprod - Primary database` / `maxprodm - Physical standby database` / `SUCCESS`

---

## Phase 4: Post-Patch Validation

### 4.1 Primary Validation — on rsrcndbmax01pn as oracle

```bash
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
```

**Database role and version:**
```bash
$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V$DATABASE;
SELECT VERSION FROM V$INSTANCE;
EXIT;
EOF
```
Expected: `READ WRITE` / `PRIMARY`

**DB home OPatch:**
```bash
$ORACLE_HOME/OPatch/opatch lspatches
```
Expected: `39472050`, `39222882`, `39657094`, `39526364`

**Grid home OPatch:**
```bash
su - grid -c "/u01/app/19.32.0/grid/OPatch/opatch lspatches"
```

**CRS release patch level:**
```bash
su - grid -c "/u01/app/19.32.0/grid/bin/crsctl query crs releasepatch"
```
Expected: `release patch string is [19.32.0.0.0]`

**Sqlpatch registry:**
```bash
$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT PATCH_ID, STATUS, SUBSTR(DESCRIPTION,1,55) DESCRIPTION
FROM   DBA_REGISTRY_SQLPATCH
WHERE  PATCH_ID IN (39472050, 39222882, 39657094)
ORDER BY ACTION_TIME DESC;
EXIT;
EOF
```
Expected: `SUCCESS` for each patch (most recent action)

**Component registry:**
```bash
$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT COMP_NAME, VERSION, STATUS FROM DBA_REGISTRY ORDER BY COMP_NAME;
EXIT;
EOF
```
Expected: All `VALID` or `OPTION OFF`

**DG Broker:**
```bash
$ORACLE_HOME/bin/dgmgrl / "show configuration"
```
Expected: `Configuration Status: SUCCESS`

**Archive gap:**
```bash
$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT COUNT(*) "ARCHIVE_GAP" FROM V$ARCHIVE_GAP;
EXIT;
EOF
```
Expected: `0`

---

### 4.2 Standby Validation — on rsrcndbmax01mc as oracle

```bash
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
```

**Database role:**
```bash
$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT DB_UNIQUE_NAME, OPEN_MODE, DATABASE_ROLE FROM V$DATABASE;
EXIT;
EOF
```
Expected: `READ ONLY WITH APPLY` / `PHYSICAL STANDBY`

**MRP status:**
```bash
$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT PROCESS, STATUS, SEQUENCE# FROM V$MANAGED_STANDBY WHERE PROCESS LIKE 'MRP%';
EXIT;
EOF
```
Expected: `MRP0 APPLYING_LOG`

**Apply lag:**
```bash
$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT NAME, VALUE FROM V$DATAGUARD_STATS WHERE NAME='apply lag';
EXIT;
EOF
```
Expected: `+00 00:00:00`

**DB home OPatch:**
```bash
$ORACLE_HOME/OPatch/opatch lspatches
```

**Grid home OPatch:**
```bash
su - grid -c "/u01/app/19.32.0/grid/OPatch/opatch lspatches"
```

**CRS release patch level:**
```bash
su - grid -c "/u01/app/19.32.0/grid/bin/crsctl query crs releasepatch"
```

---

## Phase 5: Post-Patch Hardening

### 5.1 Disable Unused DB Options (chopt) — on rsrcndbmax01pn as oracle

> This is for Non-CDB only. The binary is relinked — restart required.
> Run this on **each node independently** (binary changes do not propagate via redo).

**On rsrcndbmax01pn first (primary restart causes brief outage):**
```bash
su - oracle -c "/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/bin/chopt disable olap"
su - oracle -c "/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/bin/chopt disable rat"
su - oracle -c "/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/bin/chopt disable partitioning"
```

Restart database:
```bash
su - grid -c "/u01/app/19.32.0/grid/bin/srvctl stop database -d maxprod -o immediate"
su - grid -c "/u01/app/19.32.0/grid/bin/srvctl start database -d maxprod"
```

Verify options disabled:
```bash
su - oracle -c "
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
\$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
SELECT PARAMETER, VALUE FROM V\$OPTION
WHERE PARAMETER IN ('Partitioning','OLAP','Real Application Testing');
EXIT;
EOF
"
```
Expected: all `FALSE`

Run utlrp:
```bash
su - oracle -c "
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
\$ORACLE_HOME/bin/sqlplus -s / as sysdba <<'EOF'
@?/rdbms/admin/utlrp
SELECT COUNT(*) \"INVALID\" FROM DBA_OBJECTS WHERE STATUS='INVALID';
EXIT;
EOF
"
```
Expected: `0` invalid objects

**On rsrcndbmax01mc (standby — bounce MRP instead of full restart):**
```bash
su - oracle -c "/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/bin/chopt disable olap"
su - oracle -c "/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/bin/chopt disable rat"
su - oracle -c "/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/bin/chopt disable partitioning"
```

Restart MRP:
```bash
su - oracle -c "
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
\$ORACLE_HOME/bin/sqlplus / as sysdba <<'EOF'
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
EXIT;
EOF
"
```

---

### 5.2 Configure FIPS 140 — BOTH NODES as oracle

```bash
echo 'SSLFIPS_140=TRUE' > \
    /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/ldap/admin/fips.ora

chown oracle:oinstall \
    /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/ldap/admin/fips.ora
chmod 640 \
    /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/ldap/admin/fips.ora
```

---

### 5.3 Disable extproc Binary — BOTH NODES as root

```bash
mv /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/bin/extproc \
   /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/bin/extproc.orig

# Verify:
ls -la /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932/bin/extproc*
```

---

### 5.4 Deinstall Old Homes — BOTH NODES (after 24hr stability period)

> Run after confirming stability. This is irreversible. Take a snapshot first.

#### On rsrcndbmax01pn as root:

```bash
# Reset permissions first:
chmod -R 775 /u01/app/19.31.0/grid/
chmod -R 775 /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931/
chown -R grid:oinstall /u01/app/19.31.0/grid/
chown -R oracle:oinstall /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931/

# Deinstall old GI home:
export CV_ASSUME_DISTID=OEL7.8
/u01/app/19.31.0/grid/deinstall/deinstall -silent

# Deinstall old DB home:
export CV_ASSUME_DISTID=OEL7.8
/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931/deinstall/deinstall -silent

# Remove residual directories if deinstall did not clean them:
rm -rf /u01/app/19.31.0
rm -rf /u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1931
```

Repeat same steps on **rsrcndbmax01mc**.

---

### 5.5 AIDE Integrity Database Reset — BOTH NODES as root

Run this last on each node. Takes 30-60 minutes per node. Run in parallel.

```bash
# Check if existing AIDE database exists:
ls -la /var/lib/aide/aide.db.gz

# If exists — update mode:
aide --update
mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz

# If no existing database — init mode:
aide --init
mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
```

---

## Final Verification — DG Broker Show Configuration

**On rsrcndbmax01pn as oracle:**
```bash
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
$ORACLE_HOME/bin/dgmgrl /
```
Inside dgmgrl:
```
DGMGRL> SHOW CONFIGURATION;
```
Expected final state:
```
Configuration - <DGConfig name>
  Protection Mode: MaxAvailability
  Members:
  maxprod  - Primary database
    maxprodm - Physical standby database
Configuration Status:
SUCCESS
```
```
DGMGRL> EXIT;
```

---

## Rollback Procedure

If any step fails during the maintenance window and a rollback is needed:

### Option A: Roll back via Proxmox snapshot (lab) or storage snapshot (office)

Restore both nodes to the pre-deploy snapshot. This is the cleanest option.

### Option B: Switchback via DG Broker if switchover already completed

If switchover completed but deployment failed on rsrcndbmax01pn:

```bash
# On rsrcndbmax01mc as oracle (current primary):
su - oracle
export ORACLE_HOME=/u01/app/odaorahome/oracle/product/19.0.0.0/dbhome_1932
export ORACLE_SID=maxprod
$ORACLE_HOME/bin/dgmgrl sys/<SYS_PASSWORD>@maxprodm
```
Inside dgmgrl:
```
DGMGRL> SWITCHOVER TO 'maxprod';
```
This restores rsrcndbmax01pn as primary running from `dbhome_1931` (old home, unchanged).

---

*Playbook version: 19.31 → 19.32 | Environment: rsrcndbmax01pn / rsrcndbmax01mc*
*Generated: 2026-08-23*
