#!/bin/bash

# Variables
readonly ora_User=oracle
readonly ora_Group=dba
readonly ora_Home=/oracle12c/OraHome19c 
readonly ora_Upgrade=/oracle12c/upgrade
readonly ora_Setup=/oracle12c/setup
readonly ora_Logs=/oracle12c/dbpatch/logs
readonly upgrade_Logs=${ora_Logs}/oracle19c_upgrade.log
readonly runUser="/sbin/runuser -l ${ora_User} -c"
readonly kill_Proc="/bin/kill -9"
readonly gvppDmpDir=/oracle12c/admin/ORCL/dpdump/gvpp_dump_dir
readonly gvppLogDir=/oracle12c/admin/ORCL/adump

mkdir -p ${ora_Home} ${ora_Upgrade} ${ora_Setup} ${ora_Logs} ${gvppDmpDir} ${gvppLogDir}
touch ${upgrade_Logs}
chown -R ${ora_User}:${ora_Group} /oracle12c 

currentDir=$(pwd)
cd ${gvppDmpDir}
for i in {0..20}; 
do 
    touch GVPP$(date +%Y%m%d%H%M%S)${i}.dmp; 
    touch GVPP$(date +%Y%m%d%H%M%S)${i}.txt; 
done;
cd ${currentDir}

