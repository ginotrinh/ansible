#!/bin/bash

# Global variables
nextopt=$2


# Functions
function init()
{
	dbUser=oracle
	dbPatch=/oracle12c/dbpatch
	runUser="/sbin/runuser -l $dbUser -c"
  pkgPath=/oracle12c/dbpatch/upgrade/rpm
  pkgInstall=/oracle12c/dbpatch/logs/.rpm_install.log
  pkgRemove=/oracle12c/dbpatch/logs/.rpm_remove.log

  # Create a DYNAMIC script #
  DYNAMIC_SCRIPT="/opt/gvppdb/gvppdbpatchpostphasescript"
  if [ ! -f $DYNAMIC_SCRIPT ]; then
    touch $DYNAMIC_SCRIPT
    cat > $DYNAMIC_SCRIPT << prepare
#!/bin/bash

prepare
  fi
 
  chmod 755 $DYNAMIC_SCRIPT
}

#Task 1. Check requirement (as root user)
prerequisiteCheck()
{
    taskRecord="1"

    # Variables 
    local gvppDmpDir=/oracle12c/admin/ORCL/dpdump/gvpp_dump_dir
    local gvppLogDir=/oracle12c/admin/ORCL/adump
    local _spaceCheck=$(df -h /oracle12c | tail -n 1 | awk '{print $4}' | tr -d '[:alpha:]')
    local spaceCheck=$(expr $_spaceCheck + 0)

    #2. delete all logs & dmp and text files
    rm -f ${gvppLogDir}/* >/dev/null 

    local _workingDir=$(pwd)
    cd ${gvppDmpDir}
    local _counts=$(ls -l . | grep '.dmp' | wc -l)
    local _countConvert=$(expr $_counts + 0)
    if [ $_countConvert -gt 3 ];
    then
        ls -tp . | grep '.dmp' | grep -v '/$' | tail -n $(expr ${_counts} - 3) | xargs -I {} rm -- {}
    fi
    
    local _counts=$(ls -l . | grep '.txt' | wc -l)
    local _countConvert=$(expr $_counts + 0)
    if [ $_countConvert -gt 3 ];
    then
        local _removeTxtFiles=$(ls -tp . | grep '.txt'  | grep -v '/$' | tail -n $(expr $_counts - 3) | xargs -I {} rm -- {})
    fi
    cd ${_workingDir}

    #3. check available space
    if [ $spaceAvailable -lt 30 ]; then 
      exit 4
    fi
}

packageRemoval()
{
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
  
  echo -n "" >> $pkgRemove

  for i in "${_pkgItem[@]}";
  do
    local _pkgCheck=$(yum list installed | grep $i)
    if [ "${_pkgCheck}" != "" ]; 
    then 
      yum -y remove $i >> $pkgRemove
      if [ $? -eq 0 ]; 
      then
          echo "PASS: remove package named ${i} successfully !" >> $pkgRemove
      else 
          echo "FAILED: cannot remove package named ${i}" >> $pkgRemove
      fi
    else
      echo "INFO: package named ${i} was not installed !" >> $pkgRemove
    fi
  done
}

function patchApply()
{
  cat >> $DYNAMIC_SCRIPT << EOF
#Installing packages
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

for i in "\${pkgItem[@]}"
do
    if [ ! -f "${pkgPath}/\${i}.rpm" ]; then 
      echo "ERROR: Package \${i} does not exist" >> $pkgInstall
    else 
      _pkgCheck=\$(yum list installed | grep \$i)
      if [ "\$_pkgCheck" == "" ]; then 
          yum -y install $pkgPath/\$i.rpm >> $pkgInstall
          if [ \$? -eq 0 ]; then 
              echo "PASS: Package \${i}.rpm has been installed successfully" >> $pkgInstall
          else 
              echo "ERROR: Error instaling package \${i}.rpm" >> $pkgInstall
          fi
      else
          echo "INFO: Package \${i}.rpm is already existed" >> $pkgInstall
      fi
    fi
done    

$runUser "$dbPatch/bin/oracleUpgrade.sh"
if [ \$? -eq 0 ]; then 
	sed -i 's%OraHome1%OraHome19c%g' /etc/oratab
	sed -i 's%OraHome1%OraHome19c%g' /home/$dbUser/.profile
fi
EOF
}

function patchRemove()
{
  #packageRemoval
  echo
}

# MAIN #
init
prerequisiteCheck

if [ "$nextopt" == "patch" ]
then 
  patchApply
else 
  patchRemove
fi