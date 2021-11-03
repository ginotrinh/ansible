#!/bin/bash

# Variables
readonly ora_User=oracle
readonly ora_Group=dba
readonly ora_Home=/oracle12c/OraHome19c 
readonly ora_Upgrade=/oracle12c/upgrade
readonly ora_Setup=/oracle12c/setup
readonly ora_Logs=/oracle12c/dbpatch/logs
readonly runUser="/sbin/runuser -l ${ora_User} -c"
readonly kill_Proc="/bin/kill -9"

# Functions
#Appendix 0. Record logs
_logRecord()
{
    # Variables 
    local upgrade_Logs=${ora_Logs}/oracle19c_upgrade.log
    local msg=$1 

    # Check if log file exists
    if [ ! -d ${ora_Logs} ]; then 
        mkdir -p ${ora_Logs}
    fi 

    if [ ! -f ${upgrade_Logs} ]; then 
        touch ${upgrade_Logs}
        > ${upgrade_Logs}
    fi

    echo "${msg}" >> ${upgrade_Logs}
}


#Appendix 1. Start up database (as oracle user)
_startupDB()
{
    # Variables 
    declare -a MESSAGE=(
        '--Appendix 1: Start up database--'
        'FAILED: cannot start the database !'
        'PASS: startup the database successfully !'
        'INFO: database is already started !'
        )

    echo "${MESSAGE[0]}"

    # 0: startup state
    # 1: shutdown state
    local rc_DB=0
    
    # 0: normal startup
    # 1: upgrade startup
    local is_Upg=$1

    # Check the database is already shutdown or not
    process=$(ps -ef | grep ora_pmon | grep -vi grep)
    if [ "$process" == "" ]; then
        rc_DB=1
    fi

    # Set permission to $ORACLE_HOME
    chown -R ${ora_User}:${ora_Group} /oracle12c

    # Verification
    if [ $rc_DB -eq 1 ]; then
        if [ $is_Upg -eq 0 ]; then 
            $runUser 'sqlplus / as sysdba <<EOF
startup
exit;
EOF' >/dev/null 2>&1
        else 
            $runUser 'sqlplus / as sysdba <<EOF
startup upgrade
exit;
EOF' >/dev/null 2>&1
        fi 
        proc=$(ps -ef | grep ora_pmon | grep -vi grep | awk '{ print $2 }')
        if [ "$proc" == "" ]; then
            _logRecord ${MESSAGE[1]}
            _cleanUp "1"
        fi
        echo "${MESSAGE[2]}"
    else
        echo "${MESSAGE[3]}"
    fi

  echo
} 

#Appendix 2. Start up listener (as oracle user)
_startupListener()
{
    # Variables 
    declare -a MESSAGE=(
        '--Appendix 2: Start up listener--'
        'FAILED: cannot start the listener !'
        'PASS: startup the listener successfully !'
        'INFO: listener is already started !'
        )

    echo "${MESSAGE[0]}"

    # 0: startup state
    # 1: shutdown state
    local rc_LSN=0

    # Check the listener is already shutdown or not
    $runUser "lsnrctl status" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        rc_LSN=1
    fi

    # Set permission to $ORACLE_HOME
    chown -R ${ora_User}:${ora_Group} /oracle12c

    # Verification
    if [ $rc_LSN -eq 1 ]; then
        $runUser "lsnrctl start" >/dev/null 2>&1
        $runUser "lsnrctl status" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "${MESSAGE[1]}"
            _cleanUp "1"
        fi

        echo "${MESSAGE[2]}"
    else 
        echo "${MESSAGE[3]}"
    fi

  chown -R ${ora_User}:${ora_Group} /oracle12c

  echo
} 

#Appendix 3. Shut down database (as oracle user)
_shutdownDB()
{
    # Variables 
    declare -a MESSAGE=(
        "Appendix 3: Shut down database !" 
        "FAILED: cannot shut down the database !"
        "PASS: shut down the database successfully !"
        "INFO: database is already shut down !"
        )

    _logRecord "${MESSAGE[1]}"

    # 0: startup state
    # 1: shutdown state
    local rc_DB=0

    # Check the database is already shutdown or not
    process=$(ps -ef | grep ora_pmon | grep -vi grep)
    if [ "$process" == "" ]; then
        rc_DB=1
    fi

    # Verification
    if [ $rc_DB -eq 0 ]; then
        $runUser 'sqlplus / as sysdba <<EOF
shutdown immediate
exit;
EOF
' >/dev/null 2>&1
        proc=$(ps -ef | grep ora_pmon | grep -vi grep | awk '{ print $2 }')
        if [ "$proc" != "" ]; then
            $kill_Proc $proc
            if [ $? -ne 0 ]; then
                _logRecord "${MESSAGE[2]}"
                _cleanUp "2"
            fi
        fi
        _logRecord "${MESSAGE[3]}"
    else
        _logRecord "${MESSAGE[4]}"
    fi

  chown -R ${ora_User}:${ora_Group} /oracle12c

  echo
}

#Appendix 4. Shut down listener (as oracle user)
_shutdownListener()
{
    # Variables 
    declare -a MESSAGE=(
        "Appendix 4: Shut down listener !" 
        "FAILED: cannot shut down the listener !"
        "PASS: shut down the listener successfully !"
        "INFO: listener is already shut down !"
        )

    _logRecord "${MESSAGE[1]}"

    # 0: startup state
    # 1: shutdown state
    local rc_LSN=0

    # Check the listener is already shutdown or not
    $runUser "lsnrctl status" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        rc_LSN=1
    fi

    # Verification
    if [ $rc_LSN -eq 0 ]; then
        $runUser "lsnrctl stop" >/dev/null 2>&1
        $runUser "lsnrctl status" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            _logRecord "${MESSAGE[2]}"
            _cleanUp "2"
        fi

        _logRecord "${MESSAGE[3]}"
    else 
        _logRecord "${MESSAGE[4]}"
    fi

  chown -R ${ora_User}:${ora_Group} /oracle12c

  echo
}

#1. Check requirement (as root user)
prerequisiteCheck()
{
    # Variables 
    declare -a MESSAGE=(
        "--Step 1: Start checking the environment--" 
        "FAILED: cannot clear P&P database logs !"
        "PASS: clear P&P database logs successfully !"
        "FAILED: cannot clear P&P database dump files !"
        "PASS: clear P&P database dump files successfully !"
        "FAILED: cannot clear P&P database dump text files !"
        "PASS: clear P&P database dump text files successfully !"
        "FAILED: There is no space left for oracle database 19c upgrade" 
        "FAILED: The available space is $spaceAvailable"
        "PASS: The available space is $spaceAvailable"
        "INFO: Creating $ora_Home directory..."
        "INFO: $ora_Home directory existed !"
        )

    local gvppDmpDir=/oracle12c/admin/ORCL/dpdump/gvpp_dump_dir
    local gvppLogDir=/oracle12c/admin/ORCL/adump
    local spaceCheck=$(df -h | grep oracle12c | awk '{print $4}' | tr -d '[:alpha:]')
    local spaceAvailable=$(expr $spaceCheck + 0)

    #1. introduce
    echo -e "${MESSAGE[0]}"   

    #2. delete all logs from $gvppLogDir directory.
    rm -f ${gvppLogDir}/* >/dev/null 
    if [ $? -ne 0 ]; then 
        echo -e "${MESSAGE[1]}" 
    else 
        echo -e "${MESSAGE[2]}" 
    fi

    #3. delete all dmp files, only keep 3 files 
    local _counts=$(ls -l ${gvppDmpDir} | grep '.dmp' | wc -l)
    local _listDmpFile=$(ls -tp ${gvppDmpDir} | grep '.dmp' | grep -v '/$' | tail -n $(expr \$_counts - 3))
    if [ $? -ne 0 ]; then 
        echo -e "${MESSAGE[3]}" 
    else 
        echo -e "${MESSAGE[4]}" 
    fi

    #4. delete all txt files, only keep 3 files 
    local _counts=$(ls -l ${gvppDmpDir} | grep '.txt' | wc -l)
    ls -tp ${gvppDmpDir} | grep '.txt'  | grep -v '/$' | tail -n $(expr $_counts - 3) | xargs -I {} rm -- {}
    if [ $? -ne 0 ]; then 
        echo -e "${MESSAGE[5]}" 
    else 
        echo -e "${MESSAGE[6]}" 
    fi

    #5. check available space
    if [ $spaceAvailable -lt 30 ]; then 
        echo -e "${MESSAGE[7]}"  
        echo -e "${MESSAGE[8]}"  
        exit 4
    else 
        echo -e "${MESSAGE[9]}"  
    fi

    # Check #2
    if [ ! -d $ora_Home ]; then 
        echo -e "${MESSAGE[10]}"  
        mkdir -p $ora_Home
    else 
        echo -e "${MESSAGE[11]}"  
    fi

    echo 
}

#2. Install all packages from /oracle12c/upgrade/rpm (as root user)
installPkg()
{
    echo -e "Step 2: Start installing packages !"

    local pkgPath=/oracle12c/upgrade/rpm
    local pkgLog=/oracle12c/upgrade/rpm/.rpm_install.log
    : > $pkgLog
    declare -a pkgItem=(
        "smartmontools-7.0-2.el7.x86_64" 
        "libXmu-1.1.2-2.el7.x86_64" 
        "xorg-x11-xauth-1.0.9-1.el7.x86_64"
        "libXxf86misc-1.0.3-7.1.el7.x86_64"
        "libdmx-1.1.3-3.el7.x86_64"
        "libXxf86dga-1.1.4-2.1.el7.x86_64"
        "libXv-1.0.11-1.el7.x86_64"
        "xorg-x11-utils-7.5-23.el7.x86_64"
        "oracle-database-preinstall-19c-1.0-2.el7.x86_64"
        )

    for i in "${pkgItem[@]}"
    do
        if [ ! -f "${pkgPath}/${i}.rpm" ]; then 
            echo -e "Missing package ${i} !"
        else 
            local pkgCheck=$(yum list installed | grep ${i})
            if [ "$pkgCheck" == "" ]; then 
                yum -y install ${pkgPath}/${i}.rpm >> $pkgLog
                if [ $? -eq 0 ]; then 
                    echo -e "Package ${i} was installed successfully!";
                else 
                    echo -e "Failed installing package ${i}.rpm, see ${pkgLog} for more detail";
                fi
                echo >> ${pkgLog}
            else
                echo -e "Package ${i} existed !";
            fi
        fi
    done    
    echo 
}

#3. Extracting all neccessary files (as oracle user)
fileDecompression()
{
    echo -e "Step 3: Start decompressing some files !"

    if [ ! -f ${ora_Upgrade}/main/LINUX.X64_193000_db_home.zip ]; then 
        exit 4
    fi 

    if [ ! ${ora_Upgrade}/main/preupgrade_19_cbuild_10_lf.zip ]; then 
        exit 4
    fi 

    if [ ! -d ${ora_Home}/rdbms/admin/ ]; then
        mkdir -p ${ora_Home}/rdbms/admin/
    fi

    # Cleanup before decompression
    rm -rf ${ora_Home}/* >/dev/null 2>&1
    rm -rf ${ora_Home}/rdbms/admin/* >/dev/null 2>&1
    # For all hidden files and folders
    find ${ora_Home}/.* -type d -prune -exec rm -rf {} + >/dev/null 2>&1
    find ${ora_Home}/rdbms/admin/.* -type d -prune -exec rm -rf {} + >/dev/null 2>&1

    # Decompress files
    unzip -o ${ora_Upgrade}/main/LINUX.X64_193000_db_home.zip -d ${ora_Home}/ >> /root/ginotest
    rc=$?
    if [ $rc -ne 0 ]; then 
        echo -e "Error occurred during decompressing the setup file !"
        exit 4
    else 
        echo -e "Decompressing the setup file 1 has been completed successfully!"
    fi

    echo >> /root/ginotest

    unzip -o ${ora_Upgrade}/main/preupgrade_19_cbuild_10_lf.zip -d ${ora_Home}/rdbms/admin/ >> /root/ginotest
    rc=$?
    if [ $rc -ne 0 ]; then 
        echo -e "Error occurred during decompressing the setup file !"
        exit 4
    else 
        echo -e "Decompressing the setup file 2 has been completed successfully!"
    fi

    chown -R ${ora_User}:${ora_Group} ${ora_Home} 

    echo
}

#4. Enviroment preparation (as oracle user)
envPrep()
{
    echo -e "Step 4: Start enviroment setup !"

    local backup_Dir=/oracle12c/dbpatch/backup
    
    if [ ! -d ${backup_Dir} ]; then 
        mkdir -p ${backup_Dir}
        echo -e "Oracle backup directory created"
    fi 

    if [ ! -f ${backup_Dir}/.profile_12c ]; then 
        if [ -f /home/${ora_User}/.profile ]; then 
            mv /home/${ora_User}/.profile ${backup_Dir}/.profile_12c
            local rc=$?
            if [ $rc -ne 0 ]; then 
                echo -e "Error occurred during backing up the .profile. Message: $rc !"
                _cleanUp
            else
                echo -e "Backing up the old .profile successfully !"
            fi
            
            cp ${backup_Dir}/.profile_12c /home/${ora_User}/
            local rc=$?
            if [ $rc -ne 0 ]; then 
                echo -e "Error occurred during copying the old .profile to the oracle home directory. Message: $rc !"
            else
                echo -e "Cloning the old .profile successfully !"
            fi

            if [ -f ${ora_Upgrade}/main/.profile ]; then 
                cp ${ora_Upgrade}/main/.profile /home/${ora_User}/
                local rc=$?
                if [ $rc -ne 0 ]; then 
                    echo -e "Error occurred during setting up the new .profile. Message: $rc !"
                else
                    echo -e "Setting up the new .profile successfully !"
                fi
            else 
                mv ${backup_Dir}/.profile_12c /home/${ora_User}/.profile
                echo -e "There is no .profile file in ${ora_Upgrade}/main/ directory !"
                _cleanUp
            fi
        else 
            echo -e "There is no .profile file in /home/${ora_User} directory !"
            _cleanUp
        fi
    else 
        echo -e "Setting up the new .profile file is already done !"
    fi

    chmod -R 750 ${backup_Dir}
    chown -R ${ora_User}:${ora_Group} ${backup_Dir} 
    chown -R ${ora_User}:${ora_Group} /home/${ora_User} 

    $runUser '. ~/.profile' >/dev/null 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then 
        echo -e "Setting up the environment is incorrect. Message: $rc !"
        _cleanUp
    fi

    #Verification
    $runUser "env | grep OraHome19c" >/dev/null 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then 
        echo -e "Setting up the environment is incorrect. Message: $rc !"
        _cleanUp
    fi
    
    echo
}

#5. Installing the oracle 19c database
oracle19cInstallation()
{
    echo -e "Step 5: Start installing oracle 19c database !"
    
    # Install 1: oracle 19c database
    $runUser "cd ${ora_Home} && \
    ./runInstaller -ignorePrereq -waitforcompletion -silent \
		-responseFile ${ora_Home}/install/response/db_install.rsp \
		oracle.install.option=INSTALL_DB_SWONLY \
		ORACLE_HOSTNAME=\${ORACLE_HOSTNAME} \
		UNIX_GROUP_NAME=oinstall \
		INVENTORY_LOCATION=\${ORACLE_INVENTORY} \
		SELECTED_LANGUAGES=en,en_GB \
		ORACLE_HOME=\${ORACLE_HOME} \
		ORACLE_BASE=\${ORACLE_BASE} \
		oracle.install.db.InstallEdition=EE \
		oracle.install.db.OSDBA_GROUP=dba \
		oracle.install.db.OSBACKUPDBA_GROUP=dba \
		oracle.install.db.OSDGDBA_GROUP=dba \
		oracle.install.db.OSKMDBA_GROUP=dba \
		oracle.install.db.OSRACDBA_GROUP=dba \
		SECURITY_UPDATES_VIA_MYORACLESUPPORT=false \
        DECLINE_SECURITY_UPDATES=true"

    local rc=$?
    if [ $rc -ne 0 ]; then 
        echo -e "---Section 1: Error occurred during oracle 19c installation or you have already run this installation. Message: $rc"
        _cleanUp
    fi		

    #Install 2: root configuration
    ${ora_Home}/root.sh
    local rc=$?
    if [ $rc -ne 0 ]; then 
        echo -e "---Section 2: Error occurred during running root script of oracle 19c installation. Message: $rc"
        _cleanUp
    fi

    chown -R ${ora_User}:${ora_Group} /oracle12c

    echo -e "Oracle 19c installation has been done successfully !"	
    echo

}

#6. Switching the .profile from 12c to 19c and vice versa
switchProfile()
{

    

    local oraBase=/home/oracle/
    #switch 1 => .profile - current 12c
    #switch 2 => .profile - current 19c
    local switch=$1

    

    if [ "$switch" == "1" ]; then 
        if [ -f ${oraBase}/.profile_19c ]; then
            echo -e "Step 6: Start switching .profile file from oracle 12c to 19c !"
            mv -f ${oraBase}/.profile ${oraBase}/.profile_12c
            mv -f ${oraBase}/.profile_19c ${oraBase}/.profile
            echo -e "Switching .profile from oracle 12c to 19c has been done successfully !"	
        fi
    elif [ "$switch" == "2" ]; then
        if [ -f ${oraBase}/.profile_12c ]; then
            echo -e "Step 6: Start switching .profile file from oracle 19c to 12c !"
            mv -f ${oraBase}/.profile ${oraBase}/.profile_19c
            mv -f ${oraBase}/.profile_12c ${oraBase}/.profile
            echo -e "Switching .profile from oracle 19c to 12c has been done successfully !"	
        fi
    else
        echo -e "This script does not support parameter $switch";
    fi

    $runUser '. ~/.profile' >/dev/null 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then 
        echo -e "Failed switching the .profile. Message: $rc !"
        _cleanUp
    fi

    
    echo

}

#7. Preupgrade tasks
oracle19cPreUpgrade()
{
    echo -e "Step 7: Start preparing oracle 19c preupgrade !"

    # Sec 1: Copy sfile and password file from 12c to 19c home
    if [ ! -d /oracle12c/OraHome19c/dbs/ ]; then 
        mkdir -p /oracle12c/OraHome19c/dbs/
    fi 
    cp -f /oracle12c/OraHome1/dbs/spfileORCL.ora /oracle12c/OraHome19c/dbs/
    cp -f /oracle12c/OraHome1/dbs/orapwORCL /oracle12c/OraHome19c/dbs/

    # Sec 2: Run the "preupgrade.jar"
    $runUser "${ora_Home}/jdk/bin/java -jar ${ora_Home}/rdbms/admin/preupgrade.jar TERMINAL TEXT"
    local rc=$?
    if [ $rc -ne 0 ]; then 
        echo -e "2. Error occurred during running preupgrade.jar file. Message: $rc"
        #_cleanUp
    fi

    # Sec 3: Re-compile invalid objects
    $runUser "sqlplus / as sysdba <<EOF
@\$ORACLE_HOME/rdbms/admin/utlrp.sql
SET SERVEROUTPUT ON;
EXECUTE DBMS_PREUP.INVALID_OBJECTS;
exit;
EOF"
    local rc=$?
    if [ $rc -ne 0 ]; then 
        echo -e "3. Error occurred during re-compiling invalid objects. Message: $rc"
        #_cleanUp
    fi

    # Sec 4: Run preupgrade-fixups.sql script
    $runUser "sqlplus / as sysdba <<EOF
@\$ORACLE_HOME/cfgtoollogs/ORCL/preupgrade/preupgrade_fixups.sql
exit;
EOF"
    local rc=$?
    if [ $rc -ne 0 ]; then 
        echo -e "4. Error occurred during running the preupgrade-fixups sql script. Message: $rc"
        #_cleanUp
    fi

    _shutdownDB
    _shutdownListener

    echo 

}

#8. Upgrade tasks
oracle19cUpgrade()
{
    _startupListener
    _startupDB 1
    dbStatus=$(runuser -l oracle -c 'sqlplus -s / as sysdba <<EOF
select name,open_mode,cdb,version,status from v\$database,v\$instance;
exit;
EOF' | grep "OPEN MIGRATE" | awk '{print $6}')

    if [ "$dbStatus" != "OPEN" ]; then 
        echo -e "Database has a problem, cannot continue the oracle 19c upgrade !"
        _cleanUp
    fi

    runuser -l oracle -c 'cd \$ORACLE_HOME/rdbms/admin && $ORACLE_HOME/perl/bin/perl catctl.pl catupgrd.sql'
    local rc=$?
    if [ $rc -ne 0 ]; then 
        echo -e "Error occurred during running the oracle 19c upgrade !"
        exit 4
    fi


    # Startup Database from Oracle 19c Home and check the registry
    _startupDB 0
    dbStatus=$(runuser -l oracle -c 'sqlplus -s / as sysdba <<EOF
select name,open_mode,cdb,version,status from v\$database,v\$instance;
exit;
EOF' | grep "OPEN" | awk '{print $6}')

    if [ "$dbStatus" != "OPEN" ]; then 
        echo -e "Database has a problem, cannot continue the oracle 19c upgrade !"
        exit 4
    fi

    runuser -l oracle -c 'sqlplus -s / as sysdba <<EOF
COL COMP_ID FOR A20
COL COMP_NAME FOR A45
COL VERSION FOR A20
SET LINESIZE 180
SELECT COMP_ID,COMP_NAME,VERSION,STATUS FROM DBA_REGISTRY;
exit;
EOF
' 
    local rc=$?
    if [ $rc -ne 0 ]; then 
        echo -e "Error occurred during running the oracle 19c upgrade !"
        exit 4
    fi
    echo 
}

#8. Post Upgrade tasks
oracle19cPostUpgrade()
{
    #Upgrade database time zone, it is expected that the time zone upgrade should only run one time 
    $runUser 'sqlplus -s / as sysdba <<EOF
select TZ_VERSION from registry\$database;
SHUTDOWN IMMEDIATE
STARTUP UPGRADE
exit;
EOF'

    
    $runUser "sqlplus -s / as sysdba <<EOF
SET SERVEROUTPUT ON;
DECLARE
  v_tz_version PLS_INTEGER;
BEGIN
  v_tz_version := DBMS_DST.get_latest_timezone_version;
  DBMS_OUTPUT.put_line('v_tz_version=' || v_tz_version);
  DBMS_DST.begin_upgrade(v_tz_version);
END;
/
exit;
EOF"

    $runUser "sqlplus -s / as sysdba <<EOF
SET SERVEROUTPUT ON
DECLARE
  v_failures   PLS_INTEGER;
BEGIN
  DBMS_DST.upgrade_database(v_failures);
  DBMS_OUTPUT.put_line('DBMS_DST.upgrade_database : v_failures=' || v_failures);
  DBMS_DST.end_upgrade(v_failures);
  DBMS_OUTPUT.put_line('DBMS_DST.end_upgrade : v_failures=' || v_failures);
END;
/
exit;
EOF"

    $runUser "sqlplus -s / as sysdba <<EOF
SELECT PROPERTY_NAME, SUBSTR(property_value, 1, 30) value FROM DATABASE_PROPERTIES WHERE PROPERTY_NAME LIKE 'DST_%' ORDER BY PROPERTY_NAME;  
exit;
EOF"

    # Recreate any directory objects listed, using path names that contain no symbolic links:
    $runUser 'sqlplus / as sysdba <<EOF
@$ORACLE_HOME/rdbms/admin/utldirsymlink.sql
exit;
EOF'

    # Gather dictionary statistics & statistics on fixed objects after the upgrade:
    $runUser 'sqlplus / as sysdba <<EOF
EXECUTE DBMS_STATS.GATHER_DICTIONARY_STATS;
EXECUTE DBMS_STATS.GATHER_FIXED_OBJECTS_STATS;
exit;
EOF'

    # Run postupgrade_fixups.sql generated by preupgrade.jar:
    $runUser 'sqlplus / as sysdba <<EOF
@/oracle12c/OraHome1/cfgtoollogs/ORCL/preupgrade/postupgrade_fixups.sql
exit;
EOF'

    # Fix invalid objects:
    $runUser 'sqlplus / as sysdba <<EOF
@\$ORACLE_HOME/rdbms/admin/utlrp.sql
exit; 
EOF'

    # Changes COMPATIBALE parameter value to 19.0.0:
    $runUser "sqlplus -s / as sysdba <<EOF
alter system set COMPATIBLE = '19.0.0' scope=spfile;
shutdown immediate
startup
show parameter COMPATIBLE
exit; 
EOF"

    # Run utlusts.sql
    $runUser 'sqlplus -s / as sysdba <<EOF
@\$ORACLE_HOME/rdbms/admin/utlusts.sql TEXT
exit; 
EOF'

    # Verify Database Registry:
    $runUser 'sqlplus / as sysdba <<EOF
COL COMP_NAME FOR A45
set linesize 200
select COMP_ID,COMP_NAME,VERSION,STATUS from dba_registry;
exit; 
EOF'

    # Add new oracle home on /etc/oratab
    existOraHome=$(cat /etc/oratab | grep OraHome19c)
    if [ "$existOraHome" == "" ]; then 
        sed -i 's/OraHome1/OraHome19c/g' /etc/oratab
    fi 
    echo 
}

    


_cleanUp()
{
    # Variables 
    declare -a MESSAGE=(
        "--Appendix 5: Error occured, perform cleanup--"
        "INFO: only phases 1,2,3 are covered by the cleanup function. For other phase, you should delete the DB and re-create it then perform the data restore and contact support."
        "FAILED: cannot start the database and listener correctly, please check that !"
        )
    local rollback=$1

    _logRecord "${MESSAGE[1]}"
    _logRecord "${MESSAGE[2]}"

    case $rollback in 
        "1")
            _logRecord "${MESSAGE[3]}"
            ;;
        "2")
            ;;
        "3")
            ;;
        *)
            ;;
    esac

    exit 4;

    #Step 1: Shut down listener and database as oracle 19c .profile
    #switchProfile 1
    #_shutdownDB
    #_shutdownListener

    #Step 2: Revert oracle home from /etc/oratab
    #sed -i 's/OraHome19c/OraHome1/g' /etc/oratab

    #Step 3: Removing package 
    #local pkgPath=/oracle12c/upgrade/rpm
    #local pkgLog=/oracle12c/upgrade/rpm/.rpm_remove.log
    #: > $pkgLog
    #declare -a pkgItem=(
    #    "smartmontools" 
    #    "libXmu" 
    #    "xorg-x11-xauth"
    #    "libXxf86misc"
    #    "libdmx"
    #    "libXxf86dga"
    #    "libXv"
    #    "xorg-x11-utils"
    #    "oracle-database-preinstall-19c"
    #    )

    #for i in "${pkgItem[@]}"
    #do
    #    local pkgCheck=$(yum list installed | grep ${i})
    #    if [ "$pkgCheck" != "" ]; then 
    #        yum -y remove ${pkgPath}/${i} >> $pkgLog
    #        if [ $? -eq 0 ]; then 
    #            echo -e "Package ${i} was removed successfully!";
    #        else 
    #            echo -e "Failed removing package ${i}.rpm, see ${pkgLog} for more detail";
    #        fi
    #        echo >> ${pkgLog}
    #    else
    #        echo -e "Package ${i} is not yet installed !";
    #    fi
    #done    

    #rm -rf ${ora_Home}

    #Step 4: Start up the listener and database as oracle 12c .profile
    #switchProfile 2
    #_startupListener
    #_startupDB 0

    #echo 

    #exit 4

}


#Main. As root user, run the below functions

_logRecord "\n"
#phase 1: make sure the database is already started up before the oracle19c upgrade.
_startupDB 0
_startupListener
prerequisiteCheck

#Phase 2: oracle 19c installation
#installPkg
#fileDecompression
#envPrep
#oracle19cInstallation

#Phase 3: preupgrade oracle 19c as .profile of 12c.
#switchProfile 2
#oracle19cPreUpgrade
#switchProfile 1

#Phase 4: upgrade oracle 19c as .profile of 19c.
#oracle19cUpgrade


# Continue here
