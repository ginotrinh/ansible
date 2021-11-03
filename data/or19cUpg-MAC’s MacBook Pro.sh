#!/bin/bash

# Variables
readonly ora_User=oracle
readonly ora_Group=dba
readonly ora_Home=/oracle12c/OraHome19c 
readonly ora_Bin=/oracle12c/OraHome1/bin
readonly ora_Upgrade=/oracle12c/upgrade
readonly ora_Setup=/oracle12c/setup
readonly runUser="/sbin/runuser -l ${ora_User} -c"
readonly kill_Proc="/bin/kill -9"

# Functions
#Appendix 1. Start up database (as oracle user)
_startupDB()
{
    echo -e "Appendix 1: Start up database !"

    # 0: startup state
    # 1: shutdown state
    local rc_DB=0

    # Check the database is already shutdown or not
    process=$(ps -ef | grep ora_pmon | grep -vi grep)
    if [ "$process" == "" ]; then
        rc_DB=1
    fi

    # Set permission to $ORACLE_HOME
    chown -R ${ora_User}:${ora_Group} /oracle12c

    # Verification
    if [ $rc_DB -eq 1 ]; then
        $runUser 'sqlplus / as sysdba <<EOF
startup
exit;
EOF
' >/dev/null 2>&1
        proc=$(ps -ef | grep ora_pmon | grep -vi grep | awk '{ print $2 }')
        if [ "$proc" != "" ]; then
            $kill_Proc $proc
            if [ $? -ne 0 ]; then
                exit 4;
            fi
        fi
        echo -e "Database has been started up successfully !";
    else
        echo -e "Database is already started !";
    fi

  echo
} 

#Appendix 2. Start up listener (as oracle user)
_startupListener()
{
    echo -e "Appendix 2: Start up listener !"

    # 0: startup state
    # 1: shutdown state
    local rc_LSN=0

    # Check the listener is already shutdown or not
    $runUser "${ora_Bin}/lsnrctl status" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        rc_LSN=1
    fi

    # Set permission to $ORACLE_HOME
    chown -R ${ora_User}:${ora_Group} /oracle12c

    # Verification
    if [ $rc_LSN -eq 1 ]; then
        $runUser "${ora_Bin}/lsnrctl start" >/dev/null 2>&1
        $runUser "${ora_Bin}/lsnrctl status" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            exit 4;
        fi

        echo -e "Listener has been started up successfully !";
    else 
        echo -e "Listener is already started up !";
    fi

  chown -R ${ora_User}:${ora_Group} /oracle12c
  chmod 755 ${ora_Bin}

  echo
} 

#Appendix 3. Shut down database (as oracle user)
_shutdownDB()
{
    echo -e "Appendix 3: Shut down database !"

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
                exit 4;
            fi
        fi

        echo -e "Database has been shutdown successfully !";
    else
        echo -e "Database is already shutdown !";
 
    fi

  chown -R ${ora_User}:${ora_Group} /oracle12c
  chmod 755 ${ora_Bin}

  echo
}

#Appendix 4. Shut down listener (as oracle user)
_shutdownListener()
{
    echo -e "Appendix 4: Shut down listener !"

    # 0: startup state
    # 1: shutdown state
    local rc_LSN=0

    # Check the listener is already shutdown or not
    $runUser "${ora_Bin}/lsnrctl status" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        rc_LSN=1
    fi

    # Verification
    if [ $rc_LSN -eq 0 ]; then
        $runUser "${ora_Bin}/lsnrctl stop" >/dev/null 2>&1
        $runUser "${ora_Bin}/lsnrctl status" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            exit 4;
        fi

        echo -e "Listener has been shutdown successfully !";

    else 
        echo -e "Listener is already shutdown successfully !";
    fi

  chown -R ${ora_User}:${ora_Group} /oracle12c
  chmod 755 ${ora_Bin}

  echo
}

#1. Check requirement (as root user)
prerequisiteCheck()
{
    echo -e "Step 1: Start checking the environment !"
    # Check #1
    local _spaceCheck=$(df -h | grep oracle12c | awk '{print $4}' | tr -d '[:alpha:]')
    local spaceAvailable=$(expr $_spaceCheck + 0)
    if [ $spaceAvailable -lt 20 ]; then 
        echo -e "There is no space left for oracle database 19c upgrade";
        echo -e "The available space is $spaceAvailable, FAILED";
        exit 1;
    else 
        echo -e "The available space is $spaceAvailable, PASSED";
    fi

    # Check #2
    if [ ! -d $ora_Home ]; then 
        echo -e "Creating $ora_Home directory...";
        mkdir -p $ora_Home
    else 
        echo -e "$ora_Home directory existed !";
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
            else
                echo -e "Backing up the old .profile successfully !"
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
                exit 4
            fi
        else 
            echo -e "There is no .profile file in /home/${ora_User} directory !"
            exit 4;
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
        exit 4
    fi

    #Verification
    $runUser "env | grep OraHome19c" >/dev/null 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then 
        echo -e "Setting up the environment is incorrect. Message: $rc !"
        exit 4
    fi
    
    echo
}

#5. Extracting all neccessary files (as oracle user)
fileDecompression()
{
    echo -e "Step 5: Start decompressing some files !"

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

    chown -R ${ora_User}:${ora_Group} ${ora_Home} ${ora_Setup}

    echo
}



#6. Installing the oracle 19c database and others
oracle19cInstallation()
{
    echo -e "Step 6: Start installing oracle 19c database !"
    
    # Install 1: oracle 19c database
    # $runUser "cd ${ora_Home} && ./runInstaller -ignorePrereq -waitforcompletion -silent \
	# 	-responseFile ${ora_Home}/install/response/db_install.rsp \
	# 	oracle.install.option=INSTALL_DB_SWONLY \
	# 	ORACLE_HOSTNAME=\${ORACLE_HOSTNAME} \
	# 	UNIX_GROUP_NAME=oinstall \
	# 	INVENTORY_LOCATION=\${ORACLE_INVENTORY} \
	# 	SELECTED_LANGUAGES=en,en_GB \
	# 	ORACLE_HOME=\${ORACLE_HOME} \
	# 	ORACLE_BASE=\${ORACLE_BASE} \
	# 	oracle.install.db.InstallEdition=EE \
	# 	oracle.install.db.OSDBA_GROUP=dba \
	# 	oracle.install.db.OSBACKUPDBA_GROUP=dba \
	# 	oracle.install.db.OSDGDBA_GROUP=dba \
	# 	oracle.install.db.OSKMDBA_GROUP=dba \
	# 	oracle.install.db.OSRACDBA_GROUP=dba \
	# 	SECURITY_UPDATES_VIA_MYORACLESUPPORT=false \
    #     DECLINE_SECURITY_UPDATES=true"

    # local rc=$?
    # if [ $rc -ne 0 ]; then 
    #     echo -e "---Install 1: Error occurred during oracle 19c installation. Message: $rc"
    #     exit 4
    # fi		

    #Install 2: root configuration
    # ${ora_Home}/root.sh
    # local rc=$?
    # if [ $rc -ne 0 ]; then 
    #     echo -e "---Install 2: Error occurred during oracle 19c installation. Message: $rc"
    #     exit 4
    # fi

    # Sec 3: Start up database
    _startupDB

    # Sec 4: Run the "preupgrade.jar"
    $runUser "${ora_Home}/jdk/bin/java -jar ${ora_Home}/rdbms/admin/preupgrade.jar TERMINAL TEXT"
    local rc=$?
    if [ $rc -ne 0 ]; then 
        echo -e "--Section 4: Error occurred during oracle 19c installation. Message: $rc"
        exit 4
    fi

    # Sec 5: Re-compile invalid objects
    $runUser "sqlplus / as sysdba <<EOF
@\$ORACLE_HOME/rdbms/admin/utlrp.sql
SET SERVEROUTPUT ON;
EXECUTE DBMS_PREUP.INVALID_OBJECTS;
exit;
EOF"
    local rc=$?
    if [ $rc -ne 0 ]; then 
        echo -e "--Section 5: Error occurred during oracle 19c installation. Message: $rc"
        exit 4
    fi

    # Sec 6: Run preupgrade-fixups.sql script
    $runUser "sqlplus / as sysdba <<EOF
@\$ORACLE_HOME/cfgtoollogs/ORCL/preupgrade/preupgrade_fixups.sql
exit;
EOF"
    local rc=$?
    if [ $rc -ne 0 ]; then 
        echo -e "--Section 6: Error occurred during oracle 19c installation. Message: $rc"
        exit 4
    fi

    echo -e "Oracle 19c installation has been done successfully !"	
    echo
}


#Main. As root user, run the below functions

echo 
#prerequisiteCheck
#installPkg
#envPrep
#fileDecompression
oracle19cInstallation