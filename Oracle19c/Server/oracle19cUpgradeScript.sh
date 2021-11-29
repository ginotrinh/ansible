#!/bin/bash

# GLOBAL variables
oraBase=/oracle12c 
ora12c=$oraBase/OraHome1 
ora19c=$oraBase/OraHome19c
oraUpgradeLogs=$oraBase/dbpatch/logs/oracle_database19c_upgrade.log 


# FUNCTIONS
# Functions support for upgrade
function init()
{
	echo -n > $oraUpgradeLogs
}

function oracleENVconfig()
{
	local oper=$1 
	
	export ORACLE_BASE=$oraBase  
	if [ "${oper}" == "19c" ]
	then 
		export ORACLE_HOME=$ora19c
		PATH=$(echo :$PATH: | sed -e 's%:/oracle12c/OraHome1/bin:%:%g' -e 's/^://' -e 's/:$//')
	elif [ "${oper}" == "12c" ]
	then  
		export ORACLE_HOME=$ora12c
		PATH=$(echo :$PATH: | sed -e 's%:/oracle12c/OraHome19c/bin:%:%g' -e 's/^://' -e 's/:$//')
	fi
	
	export LD_LIBRARY_PATH=:$ORACLE_HOME/lib
	export PERLHOME=$ORACLE_HOME/perl
	export ORACLE_HOME_LISTNER=$ORACLE_HOME
	export PATH=$ORACLE_HOME/bin:$ORACLE_HOME/OPatch:/usr/local/sbin:/sbin:/bin:/usr/sbin:/usr/bin:/root/bin
}

function logs()
{
	local msg=$1 
	
	echo "${msg}"
	echo "${msg}" >> $oraUpgradeLogs
}

function restartDB()
{
	local oper=$1 
	if [ "$oper" == "1" ]; then 
		sqlplus -S / as sysdba >> $oraUpgradeLogs <<EOF
shutdown immediate;
startup;
exit;
EOF
	elif [ "$oper" == "2" ]; then 
		sqlplus -S / as sysdba >> $oraUpgradeLogs <<EOF
shutdown immediate; 
startup upgrade;
exit;
EOF
	fi

}

function checkDatabaseMode()
{
	# Steps 5 & 7 are using this function
	_checkDBMode=$(sqlplus -S / as sysdba <<EOF
set heading off;
select name, open_mode, cdb, version, status from v\$database,v\$instance;
exit;
EOF
)
	checkDBMode=$(echo $_checkDBMode | awk '{ print $(NF) }')
	if [ $checkDBMode == "OPEN" ]; then 
		echo "OPEN"
	elif [ $checkDBMode == "MIGRATE" ]; then 
		echo "OPEN MIGRATE"
	fi
}

# Functions for oracle 19c database upgrade 
function step1()
{
	declare -a MSG=(
		"--Step 1: Setup oracle 19c server environment--"
	)
	
	logs "${MSG[0]}"
	
	mkdir -p $ora19c
	unzip -o $oraBase/dbpatch/upgrade/setup/LINUX.X64_193000_db_home.zip -d $ora19c/ >> $oraUpgradeLogs
	unzip -o $oraBase/dbpatch/upgrade/setup/preupgrade_19_cbuild_10_lf.zip -d /$ora19c/rdbms/admin/ >> $oraUpgradeLogs
	chown -R oracle:dba $ora19c
	
	logs " "
}

function step2()
{
	declare -a MSG=(
		"--Step 2: Install oracle 19c database software--"
	)
	
	logs "${MSG[0]}"
	
	oracleENVconfig "19c"
	
	cd $ORACLE_HOME
	./runInstaller -ignorePrereq -waitforcompletion -silent  \
	-responseFile ${ORACLE_HOME}/install/response/db_install.rsp               \
	oracle.install.option=INSTALL_DB_SWONLY                                    \
	ORACLE_HOSTNAME=proddb.localdomain                                         \
	UNIX_GROUP_NAME=oinstall                                                   \
	INVENTORY_LOCATION=/home/oracle/oraInventory/                              \
	SELECTED_LANGUAGES=en                                                      \
	ORACLE_HOME=${ORACLE_HOME}                                                 \
	ORACLE_BASE=${ORACLE_BASE}                                                 \
	oracle.install.db.InstallEdition=EE                                        \
	oracle.install.db.OSDBA_GROUP=dba                                          \
	oracle.install.db.OSBACKUPDBA_GROUP=dba                                    \
	oracle.install.db.OSDGDBA_GROUP=dba                                        \
	oracle.install.db.OSKMDBA_GROUP=dba                                        \
	oracle.install.db.OSRACDBA_GROUP=dba                                       \
	SECURITY_UPDATES_VIA_MYORACLESUPPORT=false                                 \
	DECLINE_SECURITY_UPDATES=true >> $oraUpgradeLogs

	$ora19c/root.sh >> $oraUpgradeLogs
	
	logs " "
}

function step3()
{
	declare -a MSG=(
		"--Step 3: Make a clone of some files from oracle12c to oracle19c--"
		"Path containing spfile of oracle12c: "
	)
	
	logs "${MSG[0]}"
	
	oracleENVconfig "12c"

	_spfilePath=$(sqlplus -S / as sysdba <<EOF
show parameter spfile
exit;
EOF
)
	spfilePath=$(dirname $(echo $_spfilePath | awk '{ print $(NF-1) }'))
	logs "${MSG[1]} ${spfilePath}"

	cp $spfilePath/spfileORCL.ora $ora19c/dbs/
	cp $spfilePath/orapwORCL $ora19c/dbs/
	
	logs " "
}

function step4()
{
	declare -a MSG=(
		"--Step 4: Check and fix issues before upgrading the oracle 19c--"
		"Number of invalid objects: "
		"File preupgrade.jar exists, OK"
	)
	
	logs "${MSG[0]}"
	
	_numberOfInvalidObjects=$(sqlplus -S / as sysdba <<EOF
select count(*) from dba_objects where status='INVALID';
exit;
EOF
)
	numberOfInvalidObjects=$(echo $_numberOfInvalidObjects | awk '{ print $(NF) }')
	logs "${MSG[1]} $numberOfInvalidObjects";

	ls -l $ora19c/rdbms/admin | grep "preupgrade.jar" >/dev/null
	if [ $? -eq 0 ]; then 
		logs "${MSG[2]}";
	fi

	oracleENVconfig "12c"

	$ora19c/jdk/bin/java -jar $ora19c/rdbms/admin/preupgrade.jar TERMINAL TEXT >> $oraUpgradeLogs
	
	sqlplus / as sysdba >> $oraUpgradeLogs << EOF
@$ORACLE_HOME/rdbms/admin/utlrp.sql
@$oraBase/cfgtoollogs/ORCL/preupgrade/preupgrade_fixups.sql
exit;
EOF

	sqlplus / as sysdba >> $oraUpgradeLogs << EOF
shutdown immediate;
exit;
EOF

	lsnrctl stop >> $oraUpgradeLogs
	
	logs " "
}

function step5()
{
	declare -a MSG=(
		"--Step 5: Start listener and database of the oracle 19c database with upgrade option--"
		"Database mode: OPEN, OK"
		"Database mode: OPEN MIGRATE, OK"
	)
	
	logs "${MSG[0]}"
	
	cp -f $ora12c/network/admin/tnsnames.ora $ora19c/network/admin/
	
	oracleENVconfig "19c"

	lsnrctl start >> $oraUpgradeLogs

	sqlplus -S / as sysdba >> $oraUpgradeLogs <<EOF
startup upgrade;
exit;
EOF

	dbModeChecking=$(checkDatabaseMode)
	if [ "${dbModeChecking}" == "OPEN" ]; then 
		logs "${MSG[1]}"
	else
		logs "${MSG[2]}"
	fi
	
	logs " "
}

function step6()
{
	declare -a MSG=(
		"--Step 6: Upgrade the oracle 19c database--"
		"Files catctl.pl & catupgrd.sql exist: OK"
		"Files catctl.pl & catupgrd.sql exist: FAILED"
		"Upgrade: OK"
		"Upgrade: FAILED"
	)
	
	logs "${MSG[0]}"
	
	##6.1 Verify files needed for upgrade 
	cd $ORACLE_HOME/rdbms/admin
	ls -l catctl.pl catupgrd.sql >/dev/null
	if [ $? -eq 0 ]; then 
		logs "${MSG[1]}";
	else 
		logs "${MSG[2]}";
	fi

	##6.2 Execute the database 19c upgrade
	$ORACLE_HOME/perl/bin/perl catctl.pl catupgrd.sql >> $oraUpgradeLogs 2>&1
	if [ $? -eq 0 ]; then 
		logs "${MSG[3]}";
	else
		logs "${MSG[4]}";
	fi
	
	logs " "
}

function step7()
{
	declare -a MSG=(
		"--Step 7: Post oracle 19c server configuration--"
		"Database mode: OPEN, OK"
		"Database mode: OPEN MIGRATE, OK"
	)
	
	logs "${MSG[0]}"
	
	restartDB "1"

	##7.1 Check open mode of the database.
	dbModeChecking=$(checkDatabaseMode)
	if [ "${dbModeChecking}" == "OPEN" ]; then 
		logs "${MSG[1]}"
	else
		logs "${MSG[2]}"
	fi

	##7.2 Check the database registry as result after the oracle 19c upgrade
	sqlplus -S / as sysdba >> $oraUpgradeLogs <<EOF
col comp_id for a20
col comp_name for a45
col version for A20
col linesize 180
select comp_id, comp_name, version, status from dba_registry;
exit;
EOF

	##7.3 Upgrade the database time zone file using the DBMS_DST package.
	sqlplus -S / as sysdba >> $oraUpgradeLogs <<EOF
select TZ_VERSION from registry\$database;

col value for a20
col property_name for a50
set linesize 150
SELECT PROPERTY_NAME, SUBSTR(property_value, 1, 30) value FROM DATABASE_PROPERTIES WHERE PROPERTY_NAME LIKE 'DST_%';
EOF

	restartDB "2"
	
	sqlplus -S / as sysdba >> $oraUpgradeLogs <<EOF
set serveroutput on
declare
  v_tz_version pls_integer;
begin
  v_tz_version := dbms_dst.get_latest_timezone_version;
  dbms_output.put_line('v_tz_version=' || v_tz_version);
  dbms_dst.begin_upgrade(v_tz_version);
end;
/

SELECT PROPERTY_NAME, SUBSTR(property_value, 1, 30) value FROM DATABASE_PROPERTIES WHERE PROPERTY_NAME LIKE 'DST_%' ORDER BY PROPERTY_NAME;
EOF

	restartDB "1"
	
	sqlplus -S / as sysdba >> $oraUpgradeLogs <<EOF
set serveroutput on
declare
  v_failures   pls_integer;
begin
  dbms_dst.upgrade_database(v_failures);
  dbms_output.put_line('dbms_dst.upgrade_database : v_failures=' || v_failures);
  dbms_dst.end_upgrade(v_failures);
  dbms_output.put_line('dbms_dst.end_upgrade : v_failures=' || v_failures);
end;
/

SELECT PROPERTY_NAME, SUBSTR(property_value, 1, 30) value FROM DATABASE_PROPERTIES WHERE PROPERTY_NAME LIKE 'DST_%' ORDER BY PROPERTY_NAME;
exit;
EOF

	##7.4 Recreate any directory objects listed, using path names that contain no symbolic links.
	sqlplus / as sysdba >> $oraUpgradeLogs <<EOF
@$ORACLE_HOME/rdbms/admin/utldirsymlink.sql
exit;
EOF

	##7.5 Gather dictionary statistics.
	sqlplus / as sysdba >> $oraUpgradeLogs <<EOF
execute dbms_stats.gather_dictionary_stats;
exit;
EOF

	##7.6 Gather statistics on fixed objects after the upgrade.
	sqlplus / as sysdba >> $oraUpgradeLogs <<EOF
execute dbms_stats.gather_fixed_objects_stats;
exit;
EOF

	##7.7 Run postupgrade_fixups.sql generated by preupgrade.jar.
	sqlplus / as sysdba >> $oraUpgradeLogs <<EOF
@$oraBase/cfgtoollogs/ORCL/preupgrade/postupgrade_fixups.sql
exit;
EOF
	
	logs " "
}

function step8()
{
	declare -a MSG=(
		"--Step 8: Check and fix issues after upgrading the oracle 19c database--"
		"Number of invalid objects before fixing: "
		"Number of invalid objects after fixing: "
		"Compatible version before update: "
		"Compatible version after update: "
	)
	
	logs "${MSG[0]}"
	
	##8.1: Check and fix invalid objects 
	_numberOfInvalidObjects=$(sqlplus -S / as sysdba <<EOF
select count(*) from dba_objects where status='INVALID';
exit;
EOF
)
	numberOfInvalidObjects=$(echo $_numberOfInvalidObjects | awk '{ print $(NF) }')
	logs "${MSG[1]} $numberOfInvalidObjects"

	sqlplus -S / as sysdba >> $oraUpgradeLogs <<EOF
@$ORACLE_HOME/rdbms/admin/utlrp.sql
exit;
EOF

	_numberOfInvalidObjects=$(sqlplus -S / as sysdba <<EOF
select count(*) from dba_objects where status='INVALID';
exit;
EOF
)
	numberOfInvalidObjects=$(echo $_numberOfInvalidObjects | awk '{ print $(NF) }')
	logs "${MSG[2]} $numberOfInvalidObjects"

	##8.2: Check and fix compability version
	_compatibleCheck=$(sqlplus -S / as sysdba <<EOF
show parameter COMPATIBLE;
exit;
EOF
)
	compatibleCheck=$(echo $_compatibleCheck | awk '{ print $(NF-3) }')
	logs "${MSG[3]} $compatibleCheck"

	sqlplus -S / as sysdba >> $oraUpgradeLogs <<EOF
alter system set compatible = '19.0.0' scope=spfile;
exit;
EOF
	restartDB "1"
	_compatibleCheck=$(sqlplus -S / as sysdba <<EOF
show parameter COMPATIBLE;
exit;
EOF
)
	compatibleCheck=$(echo $_compatibleCheck | awk '{ print $(NF-3) }')
	logs "${MSG[4]} $compatibleCheck"

	##8.3: View the result of the oracle 19c database after upgrade and configuration.
	sqlplus -S / as sysdba >> $oraUpgradeLogs <<EOF
@$ORACLE_HOME/rdbms/admin/utlusts.sql TEXT
exit;
EOF

	##8.4: Verify the database registry.
	sqlplus -S / as sysdba >> $oraUpgradeLogs <<EOF
col comp_name for a45
set linesize 200
select comp_id,comp_name,version,status from dba_registry;
exit
EOF

	logs " "
}


##### MAIN #####
init
oracleENVconfig "19c"
# Step 1: Setup oracle 19c server environment.
step1
# Step 2: Install oracle 19c database software.
step2
# Step 3: Make a clone of some files from oracle12c to oracle19c. 
step3
# Step 4: Check and fix issues before upgrading the oracle 19c.
step4
# Step 5: Start listener and database of the oracle 19c database with upgrade option.
step5
# Step 6: Upgrade the oracle 19c database.
step6
# Step 7: Post oracle 19c server configuration.
step7
# Step 8: Check and fix issues after upgrading the oracle 19c database.
step8

