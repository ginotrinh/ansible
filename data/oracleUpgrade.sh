#!/bin/bash

# Common variables
readonly ora_User=oracle
readonly ora_Group=dba
readonly ora_Home=/oracle12c/OraHome19c 
readonly ora_Upgrade=/oracle12c/upgrade
readonly ora_Setup=/oracle12c/upgrade/setup
readonly ora_Bk=/oracle12c/dbpatch/backup
readonly runUser="/sbin/runuser -l ${ora_User} -c"
readonly kill_Proc="/bin/kill -9"

# Log variables
readonly ora_Logs=/oracle12c/dbpatch/logs
readonly upgrade_Logs=${ora_Logs}/oracle19c_upgrade.log
readonly _pkgRpm=/oracle12c/upgrade/rpm
readonly _pkgRpmLog=/oracle12c/upgrade/rpm/.rpm_install.log
readonly _pkgRpmLogRemoval=/oracle12c/upgrade/rpm/.rpm_removal.log
readonly _pkgDec=/oracle12c/upgrade/setup
readonly _pkgDecLog=/oracle12c/upgrade/setup/.setup_install.log

# Changable variables
taskRecord=0

# Functions
#Appendix 0. Record logs
_logRecord()
{
    # Variables 
    local msg=$1 

    # Check if log file exists
    if [ ! -d ${ora_Logs} ]; then 
        mkdir -p ${ora_Logs}
    fi 

    if [ ! -f ${upgrade_Logs} ]; then 
        touch ${upgrade_Logs}
        > ${upgrade_Logs}
    fi

    echo "${msg}"
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

    _logRecord "${MESSAGE[0]}"

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
    if [ $rc_DB -eq 1 ]; 
    then
        if [ $is_Upg -eq 0 ]; 
        then 
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
        if [ "$proc" == "" ]; 
        then
            _logRecord ${MESSAGE[1]}
            _cleanUp "10"
        fi
        _logRecord "${MESSAGE[2]}"
    else
        _logRecord "${MESSAGE[3]}"
    fi

  _logRecord " "
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

    _logRecord "${MESSAGE[0]}"

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
            _logRecord "${MESSAGE[1]}"
            _cleanUp "1"
        fi

        _logRecord "${MESSAGE[2]}"
    else 
        _logRecord "${MESSAGE[3]}"
    fi

  chown -R ${ora_User}:${ora_Group} /oracle12c

  _logRecord " "
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

  _logRecord " "
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

#Task 1. Check requirement (as root user)
prerequisiteCheck()
{
    taskRecord="1"

    # Variables 
    local gvppDmpDir=/oracle12c/admin/ORCL/dpdump/gvpp_dump_dir
    local gvppLogDir=/oracle12c/admin/ORCL/adump
    local spaceCheck=$(df -h /oracle12c | tail -n 1 | awk '{print $4}' | tr -d '[:alpha:]')
    local spaceAvailable=$(expr $spaceCheck + 0)

    declare -a MESSAGE=(
        "--Step 1: Start checking the environment--" 
        "FAILED: cannot clear P&P database logs !"
        "PASS: clear P&P database logs successfully !"
        "FAILED: cannot clear P&P database dump files !"
        "PASS: clear P&P database dump files successfully !"
        "FAILED: cannot clear P&P database dump text files !"
        "PASS: clear P&P database dump text files successfully !"
        "FAILED: There is no space left for oracle database 19c upgrade !" 
        "FAILED: The available space is $spaceAvailable !"
        "PASS: The available space is $spaceAvailable !"
        "INFO: Creating $ora_Home directory..."
        "INFO: $ora_Home directory existed !"
        )

    #1. introduce
    _logRecord "${MESSAGE[0]}" 

    #2. delete all logs & dmp and text files
    rm -f ${gvppLogDir}/* >/dev/null 
    if [ $? -ne 0 ]; then 
        _logRecord "${MESSAGE[1]}" 
    else 
        _logRecord "${MESSAGE[2]}" 
    fi

    local _workingDir=$(pwd)
    
    cd ${gvppDmpDir}
    local _counts=$(ls -l . | grep '.dmp' | wc -l)
    local _countConvert=$(expr $_counts + 0)
    if [ $_countConvert -gt 3 ];
    then
        local _removeDmpFile=$(ls -tp . | grep '.dmp' | grep -v '/$' | tail -n $(expr ${_counts} - 3) | xargs -I {} rm -- {})
        if [ $? -ne 0 ]; 
        then 
            _logRecord "${MESSAGE[3]}" 
        else 
            _logRecord "${MESSAGE[4]}" 
        fi
    fi
    
    local _counts=$(ls -l . | grep '.txt' | wc -l)
    local _countConvert=$(expr $_counts + 0)
    if [ $_countConvert -gt 3 ];
    then
        local _removeTxtFiles=$(ls -tp . | grep '.txt'  | grep -v '/$' | tail -n $(expr $_counts - 3) | xargs -I {} rm -- {})
        if [ $? -ne 0 ]; 
        then 
            _logRecord "${MESSAGE[5]}" 
        else 
            _logRecord "${MESSAGE[6]}" 
        fi
    fi
    
    cd ${_workingDir}

    #3. check available space
    if [ $spaceAvailable -lt 30 ]; then 
        _logRecord "${MESSAGE[7]}"  
        _logRecord "${MESSAGE[8]}"  
        _cleanUp "1"
    else 
        _logRecord "${MESSAGE[9]}"  
    fi

    # Check oracle home version 19c if it is already created
    if [ ! -d $ora_Home ]; then 
        _logRecord "${MESSAGE[10]}"  
        mkdir -p $ora_Home
    else 
        _logRecord "${MESSAGE[11]}"  
    fi

    _logRecord " "
}

#Task 2. Install all packages from /oracle12c/upgrade/rpm (as root user)
installPkg()
{
    taskRecord="2"

    # Local variables
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

    declare -a MESSAGE=(
        "--Step 2: Install oracle packages--" #0
        "FAILED: Missing package named: " #1
        "PASS: Installing successfully package named: " #2
        "FAILED: Cannot install package named " #3
        "INFO: Package was already installed named " #4
        )

    #1. introduce
    _logRecord "${MESSAGE[0]}" 

    #2. functioning
    : > ${_pkgRpmLog}
    
    for i in "${pkgItem[@]}"
    do
        if [ ! -f "${_pkgRpm}/${i}.rpm" ]; then 
            _logRecord "${MESSAGE[1]} ${i}.rpm" 
        else 
            local _pkgCheck=$(yum list installed | grep ${i})
            if [ "$_pkgCheck" == "" ]; then 
                yum -y install ${_pkgRpm}/${i}.rpm >> ${_pkgRpmLog}
                if [ $? -eq 0 ]; then 
                    _logRecord "${MESSAGE[2]} ${i}.rpm"
                else 
                    _logRecord "${MESSAGE[3]} ${i}.rpm, see ${_pkgRpmLog} for more detail !";
                    _cleanUp "21"
                fi
                echo >> ${_pkgRpmLog}
            else
                _logRecord "${MESSAGE[3]} ${i}.rpm"
            fi
        fi
    done    
    _logRecord " " 
}

#Task 3. Extracting all neccessary files (as oracle user)
fileDecompression()
{
    taskRecord="3"

    # Local variables
    local _rc=
    declare -a MESSAGE=(
        "--Step 3: Decompress the oracle database 19c upgrade files--" #0
        "FAILED: misssing file named LINUX.X64_193000_db_home.zip, rolling back code 31 !" #1 
        "INFO: make sure the ${ora_Upgrade}/main directory contain file named LINUX.X64_193000_db_home.zip !" #2
        "FAILED: miss file named preupgrade_19_cbuild_10_lf.zip, rolling back code 32 !" #3
        "INFO: make sure the ${ora_Upgrade}/main directory contain file named preupgrade_19_cbuild_10_lf.zip !" #4
        "PASS: clear some files #1 before decompression successfully !" #5
        "FAILED: cannot clear some files #1 !" #6
        "PASS: clear some files #2 before decompression successfully !" #7
        "FAILED: cannot clear some files #2! " #8
        "FAILED: cannot decompress the neccesary setup file #1, see ${_pkgDecLog} for more information, rolling back code 33 !" #9
        "PASS: decompress the neccesary setup file #1 successfully !" #10
        "FAILED: cannot decompress the neccesary setup file #2, see ${_pkgDecLog} for more information, rolling back code 34 !" #11
        "PASS: decompress the neccesary setup file #2 successfully !" #12
        )

    #1. introduce
    _logRecord "${MESSAGE[0]}" 

    #2. functioning
    : > ${_pkgDecLog}

    if [ ! -f ${_pkgDec}/LINUX.X64_193000_db_home.zip ]; then 
        _logRecord "${MESSAGE[1]}"
        _logRecord "${MESSAGE[2]}"  
        _cleanUp "31"
    fi 

    if [ ! -f ${_pkgDec}/preupgrade_19_cbuild_10_lf.zip ]; then 
        _logRecord "${MESSAGE[3]}"
        _logRecord "${MESSAGE[4]}"  
        _cleanUp "32"
    fi 

    if [ ! -d ${ora_Home}/rdbms/admin/ ]; then
        mkdir -p ${ora_Home}/rdbms/admin/
    fi

    # Cleanup before decompression
    rm -rf ${ora_Home}/* >/dev/null 2>&1
    if [ $? -eq 0 ]; then 
        _logRecord "${MESSAGE[5]}"
    else 
        _logRecord "${MESSAGE[6]}"
    fi 
    
    rm -rf ${ora_Home}/rdbms/admin/* >/dev/null 2>&1
    if [ $? -eq 0 ]; then 
        _logRecord "${MESSAGE[7]}"
    else 
        _logRecord "${MESSAGE[8]}"
    fi 

    # For all hidden files and folders
    find ${ora_Home}/.* -type d -prune -exec rm -rf {} + >/dev/null 2>&1
    find ${ora_Home}/rdbms/admin/.* -type d -prune -exec rm -rf {} + >/dev/null 2>&1

    # Decompress files
    unzip -o ${_pkgDec}/LINUX.X64_193000_db_home.zip -d ${ora_Home}/ >> ${_pkgDecLog}
    if [ $? -ne 0 ]; then 
        _logRecord "${MESSAGE[9]}"
        _cleanUp "33"
    else 
        _logRecord "${MESSAGE[10]}"
    fi

    echo >> ${_pkgDecLog}

    unzip -o ${_pkgDec}/preupgrade_19_cbuild_10_lf.zip -d ${ora_Home}/rdbms/admin/ >> ${_pkgDecLog}
    if [ $? -ne 0 ]; then 
        _logRecord "${MESSAGE[11]}"
        _cleanUp "34"
    else 
        _logRecord "${MESSAGE[12]}"
    fi

    chown -R ${ora_User}:${ora_Group} ${ora_Home} 
    _logRecord " "
}

#Task 4. Enviroment preparation (as oracle user)
envPrep()
{
    taskRecord="4"

    # Local variables
    declare -a MESSAGE=(
        "--Step 4: Setup the new oracle environment--" #0
        "PASS: oracle backup directory created !" #1
        "FAILED: cannot backup the .profile file, rolling back code 41 !" #2
        "PASS: backup the old file named .profile of oracle 12c #1 successfully !" #3
        "FAILED: cannot backup the old file named .profile of oracle 12c !" #4
        "PASS: backup the old file named .profile of oracle 12c #2 successfully !" #5
        "FAILED: cannot setup the new file named .profile of oracle 19c !" #6
        "PASS: setup the new file named .profile oracle 19c successfully !" #7
        "FAILED: there is no file named .profile in ${ora_Setup} directory, rolling back code 42 !" #8
        "FAILED: there is no file named .profile in /home/${ora_User} directory, rolling back code 43 !" #9
        "INFO: the new file named .profile is already setup !" #10
        "FAILED: the new file named .profile of oracle 19c is setup incorrectly, rolling back code 44 !" #11
        "FAILED: the new file named .profile of oracle 19c is setup incorrectly, rolling back code 45 !" #12
        )

    #1. introduce
    _logRecord "${MESSAGE[0]}" 
    
    #2. functioning
    if [ ! -d ${ora_Bk} ]; then 
        mkdir -p ${ora_Bk}
        _logRecord "${MESSAGE[1]}" 
    fi 

    if [ ! -f ${ora_Bk}/.profile_12c ]; 
    then 
        if [ -f /home/${ora_User}/.profile ]; 
        then 
            mv /home/${ora_User}/.profile ${ora_Bk}/.profile_12c 2>/dev/null
            if [ $? -ne 0 ]; 
            then 
                _logRecord "${MESSAGE[2]}" 
                _cleanUp "41"
            else
                _logRecord "${MESSAGE[3]}" 
            fi
            
            cp ${ora_Bk}/.profile_12c /home/${ora_User}/ 2>/dev/null
            if [ $? -ne 0 ]; 
            then 
                _logRecord "${MESSAGE[4]}"
            else
                _logRecord "${MESSAGE[5]}"
            fi

            if [ -f ${ora_Setup}/profile ]; 
            then 
                cp ${ora_Setup}/profile /home/${ora_User}/.profile 2>/dev/null
                if [ $? -ne 0 ]; 
                then 
                    _logRecord "${MESSAGE[6]}"
                else
                    _logRecord "${MESSAGE[7]}"
                fi
            else 
                cp ${ora_Bk}/.profile_12c /home/${ora_User}/.profile 2>/dev/null
                _logRecord "${MESSAGE[8]}"
                _cleanUp "42"
            fi
        else 
            _logRecord "${MESSAGE[9]}"
            _cleanUp "43"
        fi
    else 
        _logRecord "${MESSAGE[10]}"
    fi

    chmod -R 750 ${ora_Bk}
    chown -R ${ora_User}:${ora_Group} ${ora_Bk} 
    chown -R ${ora_User}:${ora_Group} /home/${ora_User} 

    $runUser '. ~/.profile' >/dev/null 2>&1
    if [ $? -ne 0 ]; then 
        _logRecord "${MESSAGE[11]}"
        _cleanUp "44"
    fi

    #Verification
    $runUser "cat /home/${ora_User}/.profile | grep OraHome19c" >/dev/null 2>&1
    if [ $? -ne 0 ]; then 
        _logRecord "${MESSAGE[12]}"
        _cleanUp "45"
    fi
    
    _logRecord " "
}

#5. Installing the oracle 19c database
oracle19cInstallation()
{
    taskRecord="5"

    # Local variables
    local rc=
    declare -a MESSAGE=(
        "--Step 5: Install the oracle 19c database--" #0
        "FAILED: the oracle runInstaller script return error, the oracle database installation cannot be done !" #1
        "FAILED: the oracle root script return error, the oracle database installation cannot be done !" #2
        "PASS: the oracle 19c database installation has been done successfully !" #3
        )

    #1. introduce
    _logRecord "${MESSAGE[0]}" 
    
    # Install 1: oracle 19c database
    rc=$($runUser "cd ${ora_Home} && \
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
        DECLINE_SECURITY_UPDATES=true")
    if [ $rc -ne 0 ]; then 
        _logRecord "${MESSAGE[1]}. Message ${rc}" 
        _cleanUp "51"
    fi		

    #Install 2: root configuration
    rc=$(${ora_Home}/root.sh)
    if [ $rc -ne 0 ]; then 
        _logRecord "${MESSAGE[2]}. Message ${rc}" 
        _cleanUp "52"
    fi

    chown -R ${ora_User}:${ora_Group} /oracle12c

    _logRecord "${MESSAGE[3]}" 
    _logRecord " " 

}

#6. Switching the .profile from 12c to 19c and vice versa
switchProfile()
{
    taskRecord="6"

    # Local variables
    #switch 1 => .profile - current 12c
    #switch 2 => .profile - current 19c
    local switch=$1
    local oraBase=/home/${ora_User}/

    declare -a MESSAGE=(
        "--Switching .profile file from oracle 12c to 19c--" #0
        "PASS: switch the version of .profile file from oracle 12c to 19c has been done successfully !" #1
        "--Switching .profile file from oracle 19c to 12c--" #2
        "PASS: switch the version of .profile file from oracle 19c to 12c has been done successfully !" #3
        "FAILED: unknown parameter $switch !" #4
        "FAILED: cannot switch the version of the .profile file !" #5
        )

    if [ "$switch" == "1" ]; then 
        if [ -f ${oraBase}/.profile_19c ]; then
            _logRecord "${MESSAGE[0]}" 
            mv -f ${oraBase}/.profile ${oraBase}/.profile_12c 2>/dev/null
            mv -f ${oraBase}/.profile_19c ${oraBase}/.profile 2>/dev/null
            _logRecord "${MESSAGE[1]}" 	
        fi
    elif [ "$switch" == "2" ]; then
        if [ -f ${oraBase}/.profile_12c ]; then
            _logRecord "${MESSAGE[2]}"
            mv -f ${oraBase}/.profile ${oraBase}/.profile_19c 2>/dev/null
            mv -f ${oraBase}/.profile_12c ${oraBase}/.profile 2>/dev/null
            _logRecord "${MESSAGE[3]}"
        elif [ -f ${ora_Bk}/.profile_12c ];
        then 
            mv -f ${ora_Bk}/.profile_12c ${oraBase}/.profile 2>/dev/null
        else
            _cleanUp "61"
        fi
    else
        _logRecord ${MESSAGE[4]}
        _cleanUp "62"
    fi

    $runUser '. ~/.profile' >/dev/null 2>&1
    if [ $? -ne 0 ]; then 
        _logRecord "${MESSAGE[5]}"
        _cleanUp "63"
    fi
    _logRecord " "
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
        "----------ROLLBACK----------" #0
        "INFO: only phases 1,2,3 are covered by the cleanup function. For other phase, you should delete the DB and re-create it then perform the data restore and contact for support." #1
        "INFO: ensure the available space of /oracle12c partition is greater than 30 Gb before taking place the oracle 19c upgrade!" #2
        "FAILED: cannot remove the installed files !" #3
        )
    local rollback=$1

    _logRecord " "
    _logRecord "${MESSAGE[0]}"
    _logRecord "${MESSAGE[1]}"

    case $taskRecord in 
        "1") #task 1
            _logRecord "${MESSAGE[2]}"
            ;;
        "2") #task 2
            __task2Rollback
            ;;
        "3") #task 3
            __task3Rollback "$rollback"
            __task2Rollback
            ;;
        "4") #task 4
            __task4Rollback "$rollback"
            __task3Rollback "$rollback"
            __task2Rollback
            ;;
        "6") #task 6
            __task6Rollback "$rollback"
            __task3Rollback "$rollback"
            __task2Rollback
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

    #Step 4: Start up the listener and database as oracle 12c .profile
    #switchProfile 2
    #_startupListener
    #_startupDB 0

    #echo 

    #exit 4

}

__task2Rollback()
{
    local task2Msg=
    declare -a _pkgItem=(
        "smartmontools" 
        "libXmu" 
        "xorg-x11-xauth"
        "libXxf86misc"
        "libdmx"
        "libXxf86dga"
        "libXv"
        "xorg-x11-utils"
        "oracle-database-preinstall-19c"
        )

    : > $_pkgRpmLogRemoval

    for i in "${_pkgItem[@]}";
    do
        local _pkgCheck=$(yum list installed | grep ${i})
        if [ "$_pkgCheck" != "" ]; 
        then 
            yum -y remove ${i} >> $_pkgRpmLogRemoval
            if [ $? -eq 0 ]; 
            then
                task2Msg="PASS: remove package named ${i} successfully !"
                _logRecord "$task2Msg"
            else 
                task2Msg="FAILED: cannot remove package named ${i}, see ${_pkgRpmLogRemoval} for more detail !"
                _logRecord "$task2Msg"
            fi
            echo >> ${_pkgRpmLogRemoval}
        else
            task2Msg="INFO: package named ${i} was not installed !"
            _logRecord "$task2Msg"
        fi
    done
}

__task3Rollback()
{
    local rollbackCode=$1
    # Variables 
    declare -a MESSAGE=(
        "FAILED: cannot remove the installed files !" #0
        )

    if [ "$rollbackCode" == "31" ] || [ "$rollbackCode" == "32" ];
    then 
        :
    elif [ "$rollbackCode" == "33" ] || [ "$rollbackCode" == "34" ];
    then
        find ${ora_Home}/.* -type d -prune -exec rm -rf {} + >/dev/null 2>&1
        find ${ora_Home}/rdbms/admin/.* -type d -prune -exec rm -rf {} + >/dev/null 2>&1
        
        rm -rf ${ora_Home}/rdbms/admin/* >/dev/null 2>&1
        if [ $? -ne 0 ]; then _logRecord "${MESSAGE[0]}"; fi 
        
        rm -rf ${ora_Home}/* >/dev/null 2>&1
        if [ $? -ne 0 ]; then _logRecord "${MESSAGE[0]}"; fi 
    fi
}

__task4Rollback()
{
    local rollbackCode=$1
    local msg=
    if [ "$rollbackCode" == "41" ] || [ "$rollbackCode" == "42" ];
    then 
        $runUser '. ~/.profile' >/dev/null 2>&1
    elif [ "$rollbackCode" == "43" ] || [ "$rollbackCode" == "44" ] || [ "$rollbackCode" == "45" ] ;
    then
        if [ -f /home/${ora_User}/.profile_12c ];
        then
            mv -f /home/${ora_User}/.profile_12c /home/${ora_User}/.profile 2>/dev/null
        elif [ -f ${ora_Bk}/.profile_12c ]; 
        then 
            mv -f ${ora_Bk}/.profile_12c /home/${ora_User}/.profile 2>/dev/null
        else
            :
        fi  
        msg="PASS: rollback the old file named .profile of oracle 12c successfully !"
        _logRecord "$msg"
    fi
}

__task6Rollback()
{
    local rollbackCode=$1
    local msg=
    if [ "$rollbackCode" == "61" ] || [ "$rollbackCode" == "62" ];
    then 
        :
    elif [ "$rollbackCode" == "63" ];
    then 
        if [ -f /home/${ora_User}/.profile_12c ];
        then
            mv -f /home/${ora_User}/.profile_12c /home/${ora_User}/.profile 2>/dev/null
        elif [ -f ${ora_Bk}/.profile_12c ]; 
        then 
            mv -f ${ora_Bk}/.profile_12c /home/${ora_User}/.profile 2>/dev/null
        else
            :
        fi
        msg="PASS: rollback the old file named .profile of oracle 12c successfully !"
        _logRecord "$msg"
    fi
}


#Main. As root user, run the below functions

_logRecord " "
#phase 1: make sure the database is already started up before the oracle19c upgrade (Done)
#_startupDB 0
#_startupListener
prerequisiteCheck

#Phase 2: oracle 19c installation (In-progress)
installPkg
#fileDecompression
envPrep
#oracle19cInstallation

#Phase 3: preupgrade oracle 19c as .profile of 12c.
#switchProfile 2
#oracle19cPreUpgrade
#switchProfile 1

#Phase 4: upgrade oracle 19c as .profile of 19c.
#oracle19cUpgrade


# Continue here
endMsg="INFO: for more information, please check the log file ${upgrade_Logs}"
echo "${endMsg}"