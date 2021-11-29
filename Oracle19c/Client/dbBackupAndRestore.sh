#!/bin/bash
###############################################################################
# Copyright (c) 2021 RIBBON. All rights reserved.                             #
#                                                                              #
# Use of this software and its contents is subject to the terms and            #
# conditions of the applicable end user or software license agreement,         #
# right to use notice, and all relevant copyright protections.                 #
#                                                                              #
################################################################################

# Bash debug may be turned on with a script argument of "-x" or
# by uncommenting the following line
#set -x

# Tool debug logs may be turned on with a script argument of "-d" or
# by uncommenting the following line.
#debug_logs_enabled=On

################################################################################
# GENView Provisioning and Portal (GVPP) Database backup and restore
# utility tool.
#
# This main purpose of this script is to perform a GVPP database backup or
# restore using the Oracle's data pump mechanism (expdp/impdp).
#
# The tool will sftp transfer the database backup file between
# the Oracle database server and the server running the tool,
# which is expected to be the GVPP-PS.
#
# For security, the tool supports a jail user "sftp" configuration
# set-up on the Oracle database server. Before using the tool, the secure user
# set-up must be completed; this is part of GVPP IM (installation method)
# documentation
#
# If sftp access is not permitted, due to customer security restrictions,
# the tool may be used to perform the data pump import and export
# actions only where the customer manually manage the backup files externally.
#
# This tool is intended to be mainly used by the GENBAND Cloud Compatible
# Middleware (CCM) software management component.
#
# This tool also supports multiple command line arguments to provide
# standalone use in silent or interactive modes.
#
# History
# Date     Name          Details of change
# -------- ------------- -----------------------------------------------------
# 20150918 Andre Ouellet ACQ-13824 Script creation backup only
# 20151029 Andre Ouellet ACQ-13826 Add restore capability and refactor
# 20211123 GINO          ACQ-21775 Oracle 19c Client upgrade
#
###########################################################################
#
# TODO Additions for internal designer usage todo
# TODO   -Support tool running on database server directly
# TODO   -Extend interactive to override environment variables and default
# TODO    including user ids and remapping schemas
# TODO   - Replace global script variables with local where possible.
# TODO   - Expand validation of db privileges
# TODO Feature development todo
# TODO  - Optional: Support chroot with a different backup directory path
# TODO  - Required: Log/Backupfile rotation and/or CCM NFS mount
# TODO  - Optional: Additional syntax/logic to allow restore file name without
# TODO    specifying full path
# TODO    Optional: Cancel operation support for CCM
#
#-------------------------------------------------------------------------------
#
# Environment Variables used by the tool are typically expected to be set
# on an installed GVPP-PS servers for the "c3" user. The following are the
# environment variables used by the tool:
#
# FILESDIR [optional] Directory name maintaining Oracle data pump dump files.
#	Examples: $VERSION_ROOT/files or /home/c3/C3C/V9_2_0_49/files
#
# LOGDIR: [optional] For backup and restore logs.
#	Examples: $VERSION_ROOT/files/logs/ or /home/c3/C3C/V9_2_0_49/files/logs
#
# ORACLE_HOME: Required. Oracle utility tools depend on this variable being set.
#   Tool will verify variable is set but relies on the execution of Oracle tools
#   to validate the directory is set properly, search path and library paths.
#
# HOME: Built-in. Home directory is used to store tool logs and database files
#   if LOGDIR or FILEDIR is not set, for example if run by "root".
#
# TWO_TASK: Required. TNS Name of Oracle database connection. This is also
#   required for GVPP-PS and should already be set to a value listed in
#   $ORACLE_HOME/network/admin/tnsnames.ora file.
#
# USER: Required. Determine if user is permitted to run the tool. The "c3" user
#   is the only supported username, however it may be overridden if the tool is
#   executed in interactive mode.
#
# VERSION: [optional] For display and logging purposes only
#
################################################################################

################################################################################
# Function: import_for_backup_and_restore
#
# Source external script files, such as log functions, to support this tool.
#
# No parameters.
################################################################################

import_for_backup_and_restore() {
  # Source common functions for constants and logging
  . gvpp_tools_common_functions.sh
  . gvpp_tools_common_db_functions.sh
}

## CONSTANTS - /bin/ executables
readonly CAT=/bin/cat
readonly ECHO=/bin/echo
readonly DF=/bin/df
readonly AWK=/bin/awk

## CONSTANTS - other
readonly BACKUP_INFO_FILENAME='backup_info'
readonly SCRIPT_NAME=$(basename $0)

################################################################################
# Function: oracleValidation
#
# Verify the version of the oracle database server 
# - If the oracle server is 12c: set the oracle client version to 11g.
# - If the oracle server is 19c: do nothing.
#
# No parameters.
################################################################################
function _changeC3Profile(){
  # Temporarily remove the old $ORACLE_HOME/bin from the PATH environment of c3 user.
  PATH=$(echo :$PATH: | sed -e 's%:/oracle11g/OraHome1/bin:%:%g' -e 's/^://' -e 's/:$//') 
  # Temporarily set the ORACLE_HOME to link with the /oracle11g/OraHome1/ora11g for using the impdp and expdp version 11
  export ORACLE_HOME=/oracle11g/OraHome1/ora11g
  # Temporarily add a new path for the PATH environment which will be flexibly used for backup and restore with oracle database 12c.
  # It does not affect the current version of the oracle client 19c upgrade.
  export PATH=$PATH:$ORACLE_HOME/bin
  # Temporarily set the others variable for oracle client to point to the lib and perl directories
  export LD_LIBRARY_PATH=$ORACLE_HOME/lib
  export PERLHOME=$ORACLE_HOME/perl
}
function oracleValidation(){

  local _oracleCheck=$(sqlplus -S $connection << EOF 
select version from v\$instance;
exit;
EOF
)
  local oracleVersion=$(echo $_oracleCheck | awk '{ print $3 }' | tr "." " " | awk '{ print $1 }')

  if [ "$oracleVersion" == "12" ]
  then 
    _changeC3Profile
  fi 
}

################################################################################
# Function: initializeToolEnvironment
#
# Initializes various constants, variables and default values used by the script
#
# No parameters.
################################################################################
function initializeToolEnvironment() {

  if [ "$USER" != "$gvpp_USER" ]; then
    # If the script is run by a non-c3 user, set the file mask to allow
    # other users access to logs. Mainly to ensure c3 will always have future
    # access to any generated files.
    umask 011
  fi

  local script_path=$(dirname $0)
  if [[ ! "${PATH}" =~ "${script_path}"(:|$) ]]; then
    # Adding missing path as any imports will need it. This would likely only
    # be for non-c3 users, i.e. root
    PATH=${PATH}:${script_path}
  fi

  # Include any other shell script files required by this tool.
  import_for_backup_and_restore
}

################################################################################
# Function: printToolSyntax
#
# Prints help text to the console terminal display with tool syntax.
#
# No parameters.
################################################################################
function printToolSyntax() {
  local tool_usage=$(echo "${font_bold}${SCRIPT_NAME}${font_normal} " \
    "[--action=<backup|restore>]" \
    "[--restoreFileName=<file name>" \
    "[-u <database user id>] " \
    "[-p <database user password>]" \
    "[--backupDir=<directory> ]" \
    "[-q]" \
    "[-d]" \
    "[-x]")

  local tool_usage2=$(echo "${font_bold}${SCRIPT_NAME}${font_normal} " \
    "-h")

  echo "    ${tool_usage}"
  echo "    ${tool_usage2}"
}
################################################################################
# Function: printToolExamples
#
# Prints help text to the console terminal display with tool usage examples.
#
# No parameters.
################################################################################
function printToolExamples() {
  local tool_example="$(
    cat <<TEXT_MARKERS
   ${font_bold}${SCRIPT_NAME}${font_normal}
   Backup using defaults from environment settings

   ${font_bold}${SCRIPT_NAME} --action backup -u GVPP_O -p secret -d${font_normal}
   Backup specifying user name and password.

   ${font_bold}${SCRIPT_NAME} --action backup -u GVPP_O -p secret -d --backupDir /backup${font_normal}
   Backup specifying user name, password and backup directory

   ${font_bold}${SCRIPT_NAME} --action restore -u GVPP -p secret -d --restoreFileName=/home/c3/C3C/V9_2_0_49/files/backup/GVPPDatabase20151030130406.dmp${font_normal}
   Restore from selected backup file.

TEXT_MARKERS
  )"
  echo "${tool_example}"
}

################################################################################
# Function: printToolHelp
#
# Prints detailed help text to the console terminal display with:
#  tool description
#  tool syntax
#  argument description
#  tool usage examples.
#
# No parameters.
################################################################################
function printToolHelp() {

  local tool_description="$(
    cat <<TEXT_MARKER
${font_bold}NAME${font_normal}
    ${SCRIPT_NAME} - GVPP database backup and restore script

${font_bold}SYNOPSIS${font_normal}
$(printToolSyntax)

${font_bold}DESCRIPTION${font_normal}
 GENView Provisioning and Portal (GVPP) Database backup and restore
 utilitiy tool.

 This main purpose of this script is to perform a GVPP database backup
 or restore using the Oracle data pump mechanism.

 The tool will sftp transfer the database backup file between this
 server and the Oracle database server.

 For security, the tool supports a jail user 'sftp' configuration
 set-up on the Oracle database server. Before using the tool, the secure user
 set-up must be completed; this is part of GVPP IM (installation method)
 documentation

 If sftp access is not permitted, due to security policies, the tool may be
 used to perform the the data pump import (backup) and export (restore)
 directives only. No file transfer is required in this mode, the backup file
 remains on the the database server. User is responsible for file retention.

 This tool is intended to be mainly used by the GENBAND Cloud Compatible
 Middleware (CCM) software management component. This tool also supports
 multiple command line arguments to provide standalone use in silent or
 interactive modes.

${font_bold}OPTIONS${font_normal}
${font_bold}   --action${font_normal} ${font_underline_on}action_type${font_underline_off}
        Performs the ${font_underline_on}action_type${font_underline_off} on database. Backup is the default.

${font_bold}   --backupDir${font_normal} ${font_underline_on}backup directory${font_underline_off}
        The directory in which the backup files are to be stored.

${font_bold}   --restoreFileName${font_normal} ${font_underline_on}file_name${font_underline_off}
        Uses ${font_underline_on}file_name${font_underline_off} when performing a restore. Last
        backup stored on the local server is the default.

${font_bold}   -u${font_normal} ${font_underline_on}user_id${font_underline_off}
        Database user id performing the action. Default value: ${GVPP_SQL_OWNER_ID}
        Default determined from environment variable GVPP_SQL_OWNER_ID.

${font_bold}   -p${font_normal} ${font_underline_on}user_password${font_underline_off}
        Database user id password performing the action. If -u and -p options are
        not provided, a secure password is deterived from system.

${font_bold}   -q${font_normal}   Quiet mode. No output on terminal console screen.

${font_bold}   -d${font_normal}   Enable debug level logs.

${font_bold}   -i${font_normal}   Interactive mode for lab use only.

${font_bold}   -h ${font_normal}  This help information about tool options

${font_bold}EXAMPLES${font_normal}
$(printToolExamples)

TEXT_MARKER
  )"
  echo "${tool_description}"
}
################################################################################
# Function: processToolOptions
#
# Process script parameters
#
################################################################################
function processToolOptions() {

  readonly CONST_ACTION_BACKUP="backup"
  readonly CONST_ACTION_RESTORE="restore"

  # Default tool_action is backup
  tool_action=$CONST_ACTION_BACKUP

  # Using "getopt" instead of built-in "getopts" to support long name options.
  # Same syntax of ":" when an argument is required and "::" for optional
  # argument.
  local options=$(getopt -o u:p:hdxqi -l "action:,backupDir:,restoreFileName:" -n "$0" -- "$@")
  eval set -- "$options"
  while true; do
    case "$1" in

    # QUIET/SILENT MODE disables terminal output.
    -q)
      setConsoleDisplayOff
      shift
      ;;

    # INTERACTIVE MODE prompts user to override defaults.
    -i)
      tool_mode_interactive=true
      shift
      ;;

    # Debug logs enabled
    -d)
      setDebugLogsOn
      shift
      ;;

    # Bash debug tracing enabled.
    # Intended for internal use only and not listed in help syntax
    -x)
      set -x
      shift
      ;;

    # Database user name to perform backup or restore.
    -u)
      case "$2" in
      "") shift 2 ;;
      *)
        current_db_user_id=$2
        shift 2
        ;;
      esac
      ;;

    # Database user password to perform restore
    -p)
      case "$2" in
      "") shift 2 ;;
      *)
        current_db_user_password=$2
        shift 2
        ;;
      esac
      ;;

    # Indicated whether script is performing a backup or restore
    --action)
      case "$2" in
      $CONST_ACTION_BACKUP | $CONST_ACTION_RESTORE)
        tool_action=$2
        shift 2
        ;;
      *)
        printToolSyntax
        echo "Syntax error: Value '$2' is an unknown action."
        echo "Valid values for the '--action' option are 'backup' or 'restore'."
        echo "Default: '--action=backup'"
        exit 1
        ;;
      esac
      ;;

    --backupDir)
      local_backup_directory=$2
      shift 2
      ;;

    --restoreFileName)
      db_restore_file_directory=${2%\/*}
      db_restore_file_name=${2##*\/}
      if [ "${db_restore_file_directory}" == "${db_restore_file_name}" ]; then
        # The pattern match has the same value for directory
        # and  filename... which means it was just a file
        # name without the full path. Default to local backup
        # directory.
        db_restore_file_directory=${local_backup_directory}
      fi
      db_backup_filename=$2
      shift 2
      ;;

    -h)
      # Set IFS (internal field separator) to an empty
      # character to override the  default of whitespace. This
      # will allow the heredoc to preserve formatting
      printToolHelp
      exit 0
      ;;

    # End of option processing
    --)
      shift
      break
      ;;

    # Catch all, unsupported option
    *)
      printToolSyntax
      exit 1
      ;;
    esac
  done
  let local argumentCount=$#+1

  # TODO option combination validation once CCM & Restore are coded
  if [ "$argumentCount" != "$OPTIND" ]; then
    printToolSyntax
    exit 1
  fi
}
################################################################################
# Function: validateToolOptions
#
# Validate script parameters.
#
# Most options all have default values from environment variables and values
# will be validated prior to the backup or restore action.
#
# This function will validate any mandatory parameter combinations.
#
################################################################################
function validateToolOptions() {

  # Pretty much every argument has a default value except during a restore when
  # the restore database file name much be provided.
  #
  if [ "${tool_action}" == "${CONST_ACTION_RESTORE}" ]; then
    logDebug "Restore filename is ${db_restore_file_directory}/${db_restore_file_name}"
    if [ "${db_restore_file_directory}/${db_restore_file_name}" == "/" ]; then
      logError "Syntax error, restore file name must be provided when a \
            restore action is requested."
      printToolSyntax
      return 1
    fi
  fi
}

################################################################################
# FUNCTION: exitOnError()
#
# Utility method to determines if program should exit based on whether the
# provided return code in not zero (0).
#
# Prints an exit message indicating unsuccessful end to the script.
#
# Parameters:
# 1. Return code of calling function to include in exit message
#
################################################################################
function exitOnError() {
  # If an error, print error message in bold red and exit.
  if [ $1 -ne 0 ]; then
    logfileInfo
    log -n $font_bold$font_red
    log -n "GVPP backup and restore has not completed (rc=$1)."
    log "${font_normal}${font_red}Review logs for details.${font_normal}"
    log ""

    createCCMInfoBlockLog ${tool_action} "An error has occurred (code=$1). For additional information, please refer to ${logfile}."
    if [ -n "${last_error_message}" ]; then
      createCCMInfoBlockLog ${tool_action} "The last reported error was: '${last_error_message}'."
    fi

    printToStderr "An error has occurred ($1). For additional information, please refer to ${logfile}."

    exit $1
  fi

}

################################################################################
# FUNCTION: validateToolUser()
#
# Checks if the user is permitted to run the tool. Currently only the "c3" user
# is permitted, unless interactive prompt overrides value.
#
# Parameters:
# 1. User id to validate.
################################################################################
function validateToolUser() {
  traceStartOfFunction "$*"
  logInfo "Validating if user is permitted to run this script."

  if [ $# -ne 1 ]; then
    logError "Script error, unexpected number of parameters,expected 1 " \
      "argument but got '$#'"
    return 2
  fi

  if [ "$1" == "$gvpp_USER" ]; then
    logInfo "Success. User '$1' permitted to run this script."
  else
    askUser "Tool is expected to be run by user 'c3' you are '$1'. Do you want to continue (Yes/No)? [No]:"
    if [ $? -eq 0 ]; then
      logError "User '$1' is not permitted to run this script."
      return 1
    else
      logDebug "User override: Tool run by '$1'"
    fi
  fi
  traceEndOfFunction
}
################################################################################
# FUNCTION: backupDatabase
#
# Validate that the database contains the mandatory GVPP objects and performs
# a backup.
#
# Parameters:
# 1. None
################################################################################
function backupDatabase() {

  # Validate GVPP_O user exists (owner)
  validateDbUserExists $gvpp_o_db_user_id
  exitOnError $?

  # Validate GVPP user exists (runtime user)
  validateDbUserExists $gvpp_db_user_id
  exitOnError $?

  # Validate the GVPP table space exists
  validateTablespace $gvpp_tablespace_id
  exitOnError $?

  # Validate the GVPP temporary tablespace exists
  validateTablespaceTemp $gvpp_tablespace_temp_id
  exitOnError $?

  # Validate that the database user id used for sqlplus and expdp has an
  # adequate level of permissions to backup the GVPP related data & definitions
  validateDbExportDataPrivileges
  exitOnError $?

  # Validate that the database has a GVPP defined data pump backup directory.
  # This is useful for security reason to isolate GVPP activity on the
  # database server when a sftp jailed user is configured.
  getDatabaseServerBackupDirectoryPath $db_backup_directory_reference_name
  return_code=$?
  if [ ${return_code} -ne 0 ]; then
    logInfo "GVPP specific backup directory does not appear available on " \
      "the database server. Will use default directory."
    db_backup_directory_reference_name="${db_backup_directory_reference_name_oracle_default}"
    getDatabaseServerBackupDirectoryPath $db_backup_directory_reference_name
    return_code=$?
    if [ ${return_code} -ne 0 ]; then
      logError "Unable to determine default database server directory"
    fi
  fi

  # Validate GVPP data pump backup directory is accessible on database server
  # file system by the GVPP sftp user.
  validateDatabaseServerAccessBackupDirectory $db_backup_directory
  exitOnError $?

  # Backup the database
  backupDatabaseTablespaces
  exitOnError $?
  
  # Save all datafiles
  saveDatafileLocation "$local_backup_directory/datafiles.info" "$local_backup_directory/mapping_datafiles.info"
  exitOnError $?
  
  # Create info file for Non-GVPP user database import
  create_info_file
  exitOnError $?
}

################################################################################
# FUNCTION: backupDatabaseTablespaces
#
# Executes the Oracle data pump export command.
#
# Parameters:
# 1. None
################################################################################

function backupDatabaseTablespaces() {
  traceStartOfFunction "$*"
  logInfo "Executing database backup "
  local return_code=99

  # Backup in "Full" mode in order to pick-up dependencies relates to synonyms,
  # tablespace, roles, etc. This backup should have sufficient data to recreate
  # all GVPP database objects.One notable exclusion is the "GVPP_DATA_PUMP_DIR"
  # datapump directory definition (will continue to investigate).

  # FYI
  # There are 3 types of exports available:
  # - FULL   (available objects listed in table DATABASE_EXPORT_OBJECTS)
  # - Schema (available objects listed in table FROM SCHEMA_EXPORT_OBJECTS)
  # - Table  (available objects listed in table FROM TABLE_EXPORT_OBJECTS)
  # For example select a.OBJECT_PATH from SCHEMA_EXPORT_OBJECTS a where a.OBJECT_PATH like 'SCHEMA_EXPORT%';
  # This script exports the GVPP schemas using the full export mode in order
  # to capture dependencies related with GVPP schemas.

  local command="expdp $connection \
        FULL=y \
        include=SCHEMA:\"IN ('${gvpp_o_db_user_id}','${gvpp_db_user_id}')\",ROLE,USER,SYSTEM_GRANT,ROLE_GRANT,DEFAULT_ROLE,TABLESPACE_QUOTA,TABLESPACE,DIRECTORY \
        directory=$db_backup_directory_reference_name \
        dumpfile=$db_backup_filename \
        logfile=$db_backup_logfilename"

  # The expdp command can take a few minutes so we display the command output
  # to the screen so that the the user doesn't think the tool is stuck.
  # Output (stdout/stderr) is also redirected to our log file and into a
  # variable for debug or error logs.
  # Turn on pipefail option to capture exit code of command
  set -o pipefail
  command_response=$($command 2>&1 | tee >(cat - >&2))
  return_code=$?
  logOnly "EXPDP command output: ${command_response}"
  if [ $return_code -ne 0 ]; then
    local temp_number_of_errors=${command_response##*completed with }
    local current_number_of_errors=${temp_number_of_errors%% error*}
    printToStderr "Analyzing the ${current_number_of_errors} reported error(s)"
    if [[ $command_response == *"ORA-39070"* ]]; then
      # We should have detected this permission problem earlier,
      # but just in case we encounter the error, lets help point the
      # person in towards a solution.
      logError "Common database error code 'ORA-39070' detected. " \
        "This may indicate user '$current_db_user_id' may not have " \
        "permission to backup database or the backup directory on the " \
        "database server"
    elif [[ $command_response == *"ORA-39168: Object path ROLE"* ]]; then
      logError "No Roles configured for GVPP users, this error may be ignored."
      local number_of_errors_to_ignore=$(grep -o "ORA-39168: Object path ROLE" <<<${command_response} | wc -l)
      logDebug "There are ${number_of_errors_to_ignore} role errors which can be ignored from ${current_number_of_errors}"
      if [ ${current_number_of_errors} -ge ${number_of_errors_to_ignore} ]; then
        current_number_of_errors=$((${current_number_of_errors} - ${number_of_errors_to_ignore}))
        logDebug "There are now ${current_number_of_errors} remaining."
      fi
    else
      logError "Database backup. RC=$return_code. " \
        "Error message = '${command_response:-Refer to log file}'. " \
        "Log file '$db_backup_logfilename'"
    fi
    if [ 0 -ge ${current_number_of_errors} ]; then
      return_code=0
      printToStderr "All reported errors have been recognized as warnings and may be ignored."
      logInfo "All reported errors have been recognized as warnings and may be ignored."
    else
      printToStderr "There are ${current_number_of_errors} error(s) that require attention."
      logError "There are ${current_number_of_errors} error(s) that require attention."
      printToStderr "Logfile ${logfile}"
    fi
  fi
  if [ $return_code -ne 0 ]; then

    logInfo "Success. Database backup file '$db_backup_filename' " \
      "created on database server"
    logDebug "Database backup $db_backup_filename created on database server. \
                    Local log file $db_backup_logfilename" "$command" "$return_code"
  fi
  traceEndOfFunction $return_code
  return ${return_code}
}

################################################################################
# FUNCTION: create_info_file
#
# Create a file contains Non-gvpp user information which helps restore procedure.
#
# Parameters:
# 1. None
################################################################################

create_info_file() {
  echo "${gvpp_o_db_user_id} ${gvpp_db_user_id} ${gvpp_tablespace_id} ${gvpp_tablespace_temp_id}" >"${local_backup_directory}/${BACKUP_INFO_FILENAME}"
  $(chmod 664 ${local_backup_directory}/${BACKUP_INFO_FILENAME})
}

################################################################################
# FUNCTION: create_remap_datafile_variable
#
# Create remap_datafile if restoration is difference version (Ex: 9.3->10.0).
#
# Parameters:
# 1. None
################################################################################

create_remap_datafile_variable() {
  local datafile="$db_restore_file_directory/datafiles.info"
  local mapping_datafile="$db_restore_file_directory/mapping_datafiles.info"
  updateDatafileInfo "$datafile" "$mapping_datafile"
  local first_line=$(head -n 1 $mapping_datafile)
  local src_dir=$($AWK '{print $1}' <<<$first_line)
  local target_dir=$($AWK '{print $2}' <<<$first_line)
  if [[ ${src_dir} == ${target_dir%/} ]]; then
    remap_datafile=""
  else
    remap_datafile=
    while read line <&4 || [ -n "$line" ]; do
      local target_path=$(sed "s:$src_dir:${target_dir%/}:g" <<<$line)
      remap_datafile="$remap_datafile remap_datafile=\'$line\':\'$target_path\'"
    done 4<"$datafile"
    exec 4>&-
  fi
}

################################################################################
# FUNCTION: restoreDatabase
#
# Validate database restore pre-conditions, such as backup file access and
# perform a database restore
#
# Parameters:
# None
################################################################################
function restoreDatabase() {
  local return_code=99
  # Validate the the database user execute the restore has adequate database
  # privileges to update the database.
  validateDbImportDataPrivileges
  exitOnError $?

  # Use the GVPP backup directory if it exists, otherwise fall back to the
  # Oracle default data pump backup directory if it exists. This is helpful
  # in the event the database server is re-commissioned to get GVPP up
  # and running with minimal set-up.
  getDatabaseServerBackupDirectoryPath $db_backup_directory_reference_name
  return_code=$?
  if [ ${return_code} -ne 0 ]; then
    logInfo "GVPP specific backup directory does not appear available on " \
      "the database server. Will use default directory."
    db_backup_directory_reference_name="${db_backup_directory_reference_name_oracle_default}"
    getDatabaseServerBackupDirectoryPath $db_backup_directory_reference_name
    return_code=$?
    if [ ${return_code} -ne 0 ]; then
      logError "Unable to determine default database server directory"
    fi
  fi
  exitOnError ${return_code}

  # Validate database backup directory access
  validateDatabaseServerAccessBackupDirectory $db_backup_directory
  exitOnError $?

  # Check if database backup file to restore is already on the database
  # server. If so, use it, otherwise attempt to transfer the file to the
  # database server.
  validateFileExistsRemotely ${db_backup_directory}/${db_restore_file_name}
  if [ $? -ne 0 ]; then
    validateFileExistsLocally "${db_restore_file_directory}/${db_restore_file_name}"
    rc=$?
    if [ $rc -ne 0 ]; then
      logError "Database backup file to restore does not exist: '${db_restore_file_directory}/${db_restore_file_name}'."
    fi
    exitOnError $rc
    logDebug "Transferring local backup file to database server."
    # Add read permission to the backup file, so the "oracle" user id on the
    # database server will be able to read it. sftp will preserve the
    # permission by default unless additional security restriction are
    # configured on the database server

    if [ ! -r ${db_restore_file_directory}/${db_restore_file_name} ]; then
      local command_response=""
      command_response=$(chmod ugo+r ${db_restore_file_directory}/${db_restore_file_name} 2>&1)
      rc=$?
      if [ $rc -ne 0 ]; then
        logError "Permission error, unable to read restore file '${db_restore_file_directory}/${db_restore_file_name}'"
        return ${rc}
      fi
    fi
    chmod ugo+r ${db_restore_file_directory}/${db_restore_file_name}
    putDatabaseBackupFileonDatabaseServer ${db_restore_file_directory}/${db_restore_file_name} $db_backup_directory
    return_code=$?
    if [ ${return_code} -ne 0 ]; then
      logError "Unable to transfer the backup file to the database server " \
        "(${database_server}) directory '${db_restore_file_directory}'. " \
        "Check the permissions, or manually transfer the file."
    fi
    exitOnError ${return_code}
  fi
  logDebug "Restore Action processing."
  # Delete the GVPP database, the restore will recreate all the data

  # Validate GVPP user exists before deleting(runtime user)
  validateDbUserExists $gvpp_db_user_id
  if [ $? -eq 0 ]; then
    deleteDatabaseUser ${gvpp_db_user_id}
  else
    logDebug "User ${gvpp_db_user_id} does not exist, no need to delete user."
  fi
  # Validate GVPP_O user exists before deleting (owner)
  validateDbUserExists $gvpp_o_db_user_id
  if [ $? -eq 0 ]; then
    deleteDatabaseUser ${gvpp_o_db_user_id}
  else
    logDebug "User ${gvpp_o_db_user_id} does not exist, no need to delete user."
  fi

  # Validate the GVPP temporary tablespace exists before deleting
  validateTablespaceTemp $gvpp_tablespace_temp_id
  if [ $? -eq 0 ]; then
    deleteDatabaseTablespace ${gvpp_tablespace_temp_id}
  else
    logDebug "Tablespace ${gvpp_tablespace_temp_id} does not exist, no need to delete."
  fi

  # Validate the GVPP table space exists before deleting
  validateTablespace $gvpp_tablespace_id
  if [ $? -eq 0 ]; then
    deleteDatabaseTablespace ${gvpp_tablespace_id}
  else
    logDebug "Tablespace ${gvpp_tablespace_id} does not exist, no need to delete."
  fi

  # The backed-up file contents were defined with multiple criteria in order
  # to capture all the dependencies, but the restore is more simple as
  # impdp will take care of re-creating dependencies such as user and tablespace
  # to support the schema import.
  read_backup_info
  create_remap_datafile_variable
  restoreDatabaseSchema
  return_code=$?
  if [ ${return_code} -eq 0 ]; then
    if [ ! -z "${CS_PS_IPADDRESS}" ]; then
      local message="ACTION REQUIRED On the primary database server ${database_server} \
execute the following command with the 'oracle' user id: 'cd ~oracle/warm_standby/bin;./build_standby_database.sh'"
      logInfo "$message"
      # Let the user know the stand by neeeds to be re-build. We don;t have the Oracle
      # password, otherwise we would automate this in adminRestore.sh.
      createCCMInfoBlockLog ${tool_action} "$message"

      # CCM is currently ignoring the above message because it is considered a success
      # path. We really want the user to know that no action was performed.
      # If we exit with non-zero the message will be displayed however an alarm
      # will be raised. CCM is not blocking stdErr, so we'll use that until
      # such time as CCM displays the infoBlock message.
      printToStderr "$message"
    fi
  fi
  return ${return_code}
}

################################################################################
# FUNCTION: read_backup_info
#
# Read the backup file info if exists
#
# Parameters:
# None
################################################################################
read_backup_info() {
  local backup_info_path="$db_restore_file_directory/$BACKUP_INFO_FILENAME"
  local backup_info_content=
  backup_info_content=$($CAT $backup_info_path)
  # TODO: this way is expensive, read the file to a variable then parse it
  if [[ -f $backup_info_path ]]; then
    previous_gvpp_o_db_user_id=$($ECHO $backup_info_content | $AWK '{print $1}')
    previous_gvpp_db_user_id=$($ECHO $backup_info_content | $AWK '{print $2}')
    previous_gvpp_tablespace_id=$($ECHO $backup_info_content | $AWK '{print $3}')
    previous_gvpp_tablespace_temp_id=$($ECHO $backup_info_content | $AWK '{print $4}')
  fi
}

restoreDatabaseSchema() {
  traceStartOfFunction "$*"
  logInfo "Executing database restore "
  local return_code=99
  local command=
  local non_gvpp_database_import_command="impdp $connection \
        full=y \
        include=\"TABLESPACE:IN ('${gvpp_tablespace_id}','${gvpp_tablespace_temp_id}')\", \"SCHEMA:IN ('${gvpp_o_db_user_id}','${gvpp_db_user_id}')\", INDEX:\"NOT LIKE '%AUD_TRAIL_PAYLOAD%'\",DIRECTORY:\"IN('${db_backup_directory_reference_name}')\" \
        REUSE_DATAFILES=y \
        directory=$db_backup_directory_reference_name \
        remap_schema=${previous_gvpp_o_db_user_id}:${gvpp_o_db_user_id} remap_schema=${previous_gvpp_db_user_id}:${gvpp_db_user_id}\
        remap_tablespace=${previous_gvpp_tablespace_id}:${gvpp_tablespace_id} \
        remap_tablespace=${previous_gvpp_tablespace_temp_id}:${gvpp_tablespace_temp_id} \
        dumpfile=$db_restore_file_name \
        table_exists_action=replace \
        logfile=$db_backup_logfilename \
        ${remap_datafile}"
  local gvpp_database_import_command="impdp $connection \
        full=y \
        include=\"TABLESPACE:IN ('${gvpp_tablespace_id}','${gvpp_tablespace_temp_id}')\", \"SCHEMA:IN ('${gvpp_o_db_user_id}','${gvpp_db_user_id}')\", INDEX:\"NOT LIKE '%AUD_TRAIL_PAYLOAD%'\",DIRECTORY:\"IN('${db_backup_directory_reference_name}')\" \
        REUSE_DATAFILES=y \
        directory=$db_backup_directory_reference_name \
        dumpfile=$db_restore_file_name \
        table_exists_action=replace \
        logfile=$db_backup_logfilename \
        ${remap_datafile}"
  # Fast check, base on the assumption that gvpp_o_db_user_id, gvpp_db_user_id, previous_gvpp_tablespace_id and previous_gvpp_tablespace_temp_id change together
  if [[ (-z ${previous_gvpp_o_db_user_id}) || (${previous_gvpp_o_db_user_id} == "${gvpp_o_db_user_id}") ]]; then
    command=${gvpp_database_import_command}
  else
    command=${non_gvpp_database_import_command}
  fi
  logInfo $command
  local command_response=""

  # The impdp command can take a few minutes so we display the command output
  # to the screen so that the the user doesn't think the tool is stuck.
  # Output (stdout/stderr) is also redirected to our log file and into a
  # variable for debug or error logs.
  # Turn on pipefail option to capture exit code of command
  set -o pipefail
  command_response=$($command 2>&1 | tee >(cat - >&2))
  return_code=$?
  logOnly "IMPDP command output: ${command_response}"
  if [ $return_code -ne 0 ]; then
    local temp_number_of_errors=${command_response##*completed with }
    local current_number_of_errors=${temp_number_of_errors%% error*}
    printToStderr "Analyzing the ${current_number_of_errors} reported error(s)"
    if [[ $command_response == *"ORA-39070"* ]]; then
      # We should have detected this permission problem earlier,
      # but just in case we encounter the error, lets help point the
      # person in towards a solution.
      logError "Common database error code 'ORA-39070' detected. " \
        "This may indicate user '$current_db_user_id' may not have " \
        "permission to restore database or the backup directory on the " \
        "database server"
    elif [[ $command_response == *"ORA-31684: Object type"*"already exists"* ]]; then
      # Example: ORA-31684: Object type DIRECTORY:"GVPP_DATA_PUMP_DIR" already exists
      logError "Importing an object already exists, this error may be ignored."
      local number_of_errors_to_ignore=$(grep -o "ORA-31684: Object type.*already exists" <<<${command_response} | wc -l)
      logDebug "There are ${number_of_errors_to_ignore} role errors which can be ignored from ${current_number_of_errors}"
      if [ ${current_number_of_errors} -ge ${number_of_errors_to_ignore} ]; then
        current_number_of_errors=$((${current_number_of_errors} - ${number_of_errors_to_ignore}))
        logDebug "There are now ${current_number_of_errors} remaining."
      fi

    else
      logError "Database restore. RC=$return_code. " \
        "Refer to log file '$db_backup_logfilename'"
      logOnly "IMPDP command: $command"
    fi
    if [ 0 -ge ${current_number_of_errors} ]; then
      return_code=0
      printToStderr "All reported errors have been recognized as warnings and may be ignored."
      logInfo "All reported errors have been recognized as warnings and may be ignored."
    else
      printToStderr "There are ${current_number_of_errors} error(s) that require attention."
      logError "There are ${current_number_of_errors} error(s) that require attention."
      printToStderr "Logfile ${logfile}"
    fi
  else
    logInfo "Success. Database restore of file '$db_backup_filename' " \
      "applied to database server"
    logDebug "Database restore $db_backup_filename applied to database server. \
                    Local log file $db_backup_logfilename" "$command" "$return_code"
  fi

  traceEndOfFunction $return_code
  return ${return_code}
}

################################################################################
# FUNCTION check_space
#
# Check the local directory if it has enough space to contain database dump file.
# NOTE: dump file size is estimated using BLOCKS method.
#
# Parms: none
################################################################################

check_space() {
  # Estimate dump file size
  local GIGABYTE="GB"
  local command="expdp $current_db_user_id/$current_db_user_password FULL=y include=SCHEMA:\"IN \( \'GVPP_O\',\'GVPP\'\)\",ROLE,USER,SYSTEM_GRANT,ROLE_GRANT,DEFAULT_ROLE,TABLESPACE_QUOTA,TABLESPACE,DIRECTORY  ESTIMATE_ONLY=YES  NOLOGFILE=YES"
  local command_result=
  # Turn on pipefail option to capture exit code of command
  set -o pipefail
  command_result=$($command 2>&1)
  local return_code=$?
  if [[ $return_code -ne 0 ]]; then
    logWarning "Can not evaluate space needed for backup. Target directory may not has enough space for database dump file."
    return 0
  fi
  local size_string=
  size_string=$(echo $command_result | grep -o -P "(?<=Total estimation using BLOCKS method:\s)([^\s$]{1,}\s[^\s$]{1,})")
  local arr=($size_string)
  local required_space="${arr[@]:0:1}"
  required_space=$(echo "${required_space//./}")
  local type="${arr[@]:1:2}"
  if [[ $type == "$GIGABYTE" ]]; then
    required_space=$(((required_space * 1024) / 1000))
  else
    required_space=$((required_space / 10))
  fi
  # Check size
  local available_space=
  available_space=$($DF -P "$local_backup_directory" | $AWK 'NR==2 { print $4 }')
  local avail_space_in_MB=$(((available_space + 1023) / 1024))
  if [[ $avail_space_in_MB -le $required_space ]]; then
    logError "Target directory '${local_backup_directory}' does not have enough space for database dump file. Available space: ${avail_space_in_MB} MB - Required space: ${required_space} MB."
    return 2
  fi
  logDebug "Target directory '${local_backup_directory}' have enough space for database dump file. Available space: ${avail_space_in_MB} MB - Required space: ${required_space} MB."
  return 0
}

################################################################################
#################           MAIN            ####################################
################################################################################

initializeToolEnvironment

initializeDatabaseVariables

processToolOptions $*
startLogging

validateToolOptions
exitOnError $?

prepareDatabaseConnectionCommand

logInfo "Tool Version $gvpp_rel"
logDebug "Command: '$0 $*' run from $(pwd)"

logInfo "Validating prerequisites ...."

validateToolUser $USER
exitOnError $?
logInfo "Test for standby configuration."
if [ ! -z "${CS_PS_ENABLED}" ]; then
  message="GVPP database ${tool_action} not available on this stand-by "
  message="$message server. The ${tool_action} should be executed on the "
  message="$message primary server. "
  logInfo "Exiting tool on stand by system. No action performed."
  # Let the user know nothing was performed.
  createCCMInfoBlockLog ${tool_action} "$message"

  # CCM is currently ignoring the above message because it is considered a
  # success path. We really want the user to know that no action was
  # performed.  If we exit with non-zero the message will be displayed however
  # an alarm will be raised. CCM is not blocking stdErr, so we'll use that
  # until such time as CCM displays the infoBlock message.
  printToStderr "$message"
  exit 2
fi

# Validate oracle server version (19c or 12c)
oracleValidation

validateEnvVar "ORACLE_HOME"
exitOnError $?

validatePath "sqlplus"
exitOnError $?

validatePath "tnsping"
exitOnError $?

validatePath "impdp"
exitOnError $?

validatePath "expdp"
exitOnError $?

askUser "Using database TNS name '$tns_db_name' [$tns_db_name]:" $tns_db_name
validateDatabaseConnection $tns_db_name
exitOnError $?

validateDbLogin
exitOnError $?

getDatabaseServerHostName

# Validate database server access
validateDatabaseServerFileAccess
exitOnError $?



if [ $tool_action = $CONST_ACTION_BACKUP ]; then
  check_space
  exitOnError $?
  # Perform BACKUP logic
  logDebug "Backup Action processing."
  backupDatabase
  exitOnError $?
  printToStderr "Transferring file..."
  logDebug "Backup Action backup-processing.get ${db_backup_directory}/${db_backup_filename} ${local_backup_directory}"
  getDatabaseBackupFileFromDatabaseServer ${db_backup_directory}/${db_backup_filename} ${local_backup_directory}
  exitOnError $?
  logInfo "Backup file available at: $local_backup_directory/$db_backup_filename"

else
  # Perform RESTORE logic
  logDebug "Restore action processing."
  restoreDatabase
  exitOnError $?
fi

logfileInfo

log "${font_bold}GVPP database ${tool_action} has been successfully completed.${font_normal}"
createCCMInfoBlockLog ${tool_action} "GVPP database ${tool_action} has been successfully completed."

exit 0

################### END OF MAIN ###############################################
