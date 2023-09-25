#!/bin/bash
# NAME: host-check.sh
# 
# DESCRIPTION:
# This script will process an array of hostnames to determine if the host is
# up and running.  This is determined by checking an arrary of possible SSH
# ports. If SSH is running, the node is assumed to be healthy.  If SSH is not
# running, then the host will be checked against an array of possible Dropbear
# ports. If Dropbear is detected then an "expect" script is executed to process
# the passphrase (such as encrypted ZFS on Root and ZFS BootMenu prompts)
#

AUTHOR="Richard J. Durso"
RELDATE="09/25/2023"
VERSION="0.15"
##############################################################################

### [ Routines ] #############################################################
required_utils=("expect" "nc" "curl" "strings")

# Confirm required utilities are installed.
for util in "${required_utils[@]}"; do
  [ -z "$(command -v "$util")" ] && echo "ERROR: the utility '$util' is required to be installed." >&2 && exit 1
done

# ---[ Usage Statement ]------------------------------------------------------
__usage() {
  echo "
  ${0##*/} | Version: ${VERSION} | ${RELDATE} | ${AUTHOR}

  Check if hosts are stuck at Dropbear passphrase prompt.
  ----------------------------------------------------------------------------

  This script will check a defined list of hostname(s) to determine if any of
  the hosts are waiting for a Dropbear passphrase before booting. If detected
  the script will enter the passphrase to allow the remote system to resume
  its boot process.

  --debug           : Show expect screen scrape in progress.
  -c, --config      : Full path and name of configuration file.
  -a, --all         : Process all hosts, all ports, all passphrase prompts.
  -s, --single      : Process single host, all ports, all passphrase prompts.
  -l, --list        : List defined hostnames and ports within the script.
  -h, --help        : This usage statement.
  -v, --version     : Return script version.
  
  ${0##*/} [--debug] [-c <path/name.config>] [-flags] [-a | <hostname>]

  Default configuration file: ${configfile}
  "
}

# ---[ Error Handler ]--------------------------------------------------------
# Write error messages to STDERR.

__error_message() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

# ---[ How to handle notifications ]------------------------------------------
# This is a user defined area of how to handle notifications in the script.
# This can be changed to send email notification or slack channel webhook, etc.

__send_notification() {
  local message="$1"

  # Send notification via webhook
  if [[ -n "$message" ]]; then
    if curl -X POST -H 'Content-type: application/json' --data '{"text":"'"$message"'"}' "$webhook" > /dev/null 2> /dev/null
    then
      echo "-- -- Notification sent (${message})"
    fi
  fi
}

# ---[ What to do when Dropbear unavilable or failed ]------------------------
# This is user defined area of what to do if dropbear is not available or
# failed.  You can copy & paste this into your configuration file instead of
# making modifications to this script.

__dropbear_failed_payload() {
  local hostname="$1"
  local result=1

  #This example applies taints to the Kubernetes node.
#  echo "-- Attempting fence of host: $hostname"
#  kubectl taint nodes "$hostname" node.kubernetes.io/out-of-service=nodeshutdown:NoExecute 2>&1
#  result=$?
  
#  if [ $result -eq 0 ]; then
#    kubectl taint nodes "$hostname" node.kubernetes.io/out-of-service=nodeshutdown:NoSchedule 2>&1
#    result=$?
#  fi

#  if [ $result -eq 0 ]; then
#    message="Node taints to fence $hostname sucessful."
#  else
#    message="FAILED to apply node taints on $hostname."
#  fi

#  echo "-- -- $message"
# __send_notification "$message"

  return $result
}

# ---[ Answer Dropbear Passphrase ]-------------------------------------------
# This could be customized for other Dropbear environments such as LUKS
__answer_passphrase(){
  local hostname="$1"
  local passphrase="$2"
  local result=1
  local tmp_expect_script="/tmp/host_check.exp"
  local tmp_expect_log="/tmp/host_check.log"

  echo "-- -- Attempting Dropbear passphrase on $hostname"

  if [[ -n "$passphrase" ]]; then
    touch "$tmp_expect_script"
    chmod 700 "$tmp_expect_script"

cat >"$tmp_expect_script" <<EOF
#!/usr/bin/expect -f
set timeout 30
log_file -noappend $tmp_expect_log
set PASS [lindex \$argv 0]
spawn ssh unlock-$hostname
sleep 2
# default return code is failure
set ret 1

# These prompts can be used in any order.
expect {
  # This would be seen with ZBM and incorrect passphrase
  "No boot environments" {
    set ret 1
    send_log -- "\rDEBUG: No boot environments detected\r"
    exit \$ret
  }

  # This would be seen with incorrect ZFS unlock key
  "Key load error:" {
    set ret 1
    send_log -- "\rDEBUG: Key load error detected\r"
    exit \$ret
  }

  # Logoin prompt would be a good sign too
  "login:" {
    set ret 0
    send_log -- "\rDEBUG: Login prompt detected\r"
    exit \$ret
  }

  "Enter passphrase" {
    send -- "\$PASS\r"
    send_log -- "\rDEBUG: passphrase entered\r"
    sleep 1 
    set ret 0
    exp_continue
  }

  # ZBM Welcome Banner
  "Welcome to the ZFSBootMenu initramfs shell" {
    send -- "zbm\r"
    sleep 1
    # send -- "\r"
    send_log -- "\rDEBUG: zbm sent to ZBM Welcome Banner\r"
    exp_continue
  }

  # This would be seen with ZBM with correct passphrase
  "snapshots" {
    sleep 1
    set ret 0
    send -- "\r"
    send_log -- "\rDEBUG: snapshot keyword detected\r"
    exp_continue
  }

  # This woudl be seen with traditional ZFS on Root
  "Pool Decrypted" {
    set ret 0
    send_log -- "\rDEBUG: Pool Decrypted keywords detected\r"
    exp_continue
  }

}
exit \$ret
EOF

    "$tmp_expect_script" "$passphrase" > /dev/null 2> /dev/null
    result=$?

    if [ "$DEBUG" == "$TRUE" ]; then
      # Strip out ANSI color and cursor codes used by ZFS Boot Menu if present
      echo "-- -- DEBUG: Expect script output:"
      output=$(sed 's/\x1B[@A-Z\\\]^_]\|\x1B\[[0-9:;<=>?]*[-!"#$%&'"'"'()*+,.\/]*[][\\@A-Z^_`a-z{|}~]//g' < "$tmp_expect_log" | strings) 
      echo "$output"
    fi
    # Cleanup temp file    
    rm "$tmp_expect_script" "$tmp_expect_log"
    return $result
  else
    __error_message "error: passphrase required in config file (be sure to wrap passphrase within single quotes!)"
    exit 2
  fi
}

# ---[ Detect if DropBear Port is opened ]------------------------------------
__detect_dropbear_port() {
  local hostname="$1"
  local passphrase="$2"
  local result=1
  local retries=0

  if [[ -n "$hostname" ]]; then
    for retries in $(seq "${dropbear_retries}")
    do
      echo "-- Dropbear check on host: $hostname (${retries} of ${dropbear_retries})"
      for port in "${dropbear_ports[@]}"; do
        nc -z -w1 "$hostname" "$port"
        result=$?

        if [ $result -eq 0 ]; then
          echo "-- -- Dropbear port $port is open on $hostname"
          
          if __answer_passphrase "$hostname" "$passphrase"
          then
            echo "-- -- No error detected in passphrase exchange"
            __send_notification "Successful dropbear passphrase given to: $hostname"
            break 2
          else
            echo "-- -- Error detected during passphrase exchange"
            __send_notification "ERROR: Dropbear passphrase failed with: $hostname"
          fi
        else
          echo "-- -- Dropbear port $port is not open on $hostname"
        fi
      done # ports

      sleep "$dropbear_retry_delay"
    done # retries

    if [[ "${retries}" -eq "${dropbear_retries}" ]]; then
      # Skip notification if host is known to be down
      if ! __check_host_state "$hostname"
      then 
        __send_notification "ERROR: $hostname failed all ${dropbear_retries} Dropbear connection attempts. Host down?"
        __create_host_state "$hostname"
      fi
    fi

    return $result
  else
    __error_message "error: hostname required"
    exit 2
  fi
}

# ---[ Process SSH Ports ]----------------------------------------------------
# detect if any of the defined ssh ports are active for specified host
__detect_ssh_ports() {
  local hostname="$1"
  local result=1

  if [[ -n "$hostname" ]]; then
    for port in "${ssh_ports[@]}"; do
      nc -z -w1 "$hostname" "$port"
      result=$?

      if [ $result -eq 0 ]; then
        # Cleanup any previous host down state files (if exists)
        if __remove_host_state "$hostname"
        then
          __send_notification "$hostname is now back on-line."
        fi
        # no need to check any additional ports
        break
      else
        echo "Connection to $hostname ($(getent hosts "$hostname" | awk '{print $1}')) $port port failed!"
      fi
    done
    return $result
  else
    __error_message "error: hostname required"
    exit 2
  fi
}

# ---[ Create Host State File ]-----------------------------------------------
# This will create a simmple file with the name of the host used to indicate
# that host is down and reduce the number of alerts that might be generated

__create_host_state() {
  local hostname="$1"
  local result=1

  if [[ -n "$hostname" ]]; then
    if touch "${configdir}/${hostname}.down"
      result=0
    then
      __error_message "error: unable to create host state file - ${configdir}/${hostname}.down"
    fi
  else
    __error_message "error: hostname required"
    exit 2
  fi

  return $result
}

# ---[ Check Host State File ]------------------------------------------------
# Check if a Host State File exists for the specified host.  If it does exist
# and is older than "host_state_retry_min" (minutes) delete the file. This
# will allow a notification to be triggered again.

__check_host_state() {
  local hostname="$1"
  local result=1

  if [[ -n "$hostname" ]]; then
    if [[ -f "${configdir}/${hostname}.down" ]]; then
      result=0
      # if Host State Fails is older than retry minutes delete the file (allows next notifcaiotns again)
      # return code that file nolonger exists
      if find "${configdir}" -name "${hostname}.down" -mmin "+${host_state_retry_min}" -type f -delete | grep -q "." 
      then
        echo "-- -- Removed Host State File: ${hostname}.down"
        result=1
      fi
    fi
  else
    __error_message "error: hostname required"
    exit 2
  fi
  return $result
}

# ---[ Remove Host State File ]------------------------------------------------
# Delete specified Host State File if it exists

__remove_host_state() {
  local hostname="$1"
  local result=1

  if [[ -n "$hostname" ]]; then
    if [[ -f "${configdir}/${hostname}.down" ]]; then
      rm "${configdir}/${hostname}.down" && result=0
    fi
  else
    __error_message "error: hostname required"
    exit 2
  fi
  return $result
}

# ---[ Primary Monitoring Loop ]----------------------------------------------
# This will loop over each defined hostname to determine if SSH port is open
# which indicates host is healthy.  If SSH ports are not open, the script will
# detect if Dropbear ports are opened, if detected it will attempt to answer
# passphrase prompt with the supplied passphrase
__process_all_hostnames() {
  local passphrase="$1"
  local result=1

  for hostname in "${hostnames[@]}"; do
    __detect_ssh_ports "$hostname"
    result=$?
    if [ $result -ne 0 ]; then
        __detect_dropbear_port "$hostname" "$passphrase"
        result=$?
        if [ $result -eq 0 ]; then
          # Passphrase was answered correctly
          break
        else
          # Process user defined steps to handle failed dropbear
          __dropbear_failed_payload "$hostname"
        fi
        echo
      fi
  done
}

# --- [ List Hosts and Ports ]------------------------------------------------
# List all hostnames and port numbers defined within this script.
__list_hosts_and_ports() {
  echo "Hostname(s) defined:"
  for hostname in "${hostnames[@]}"; do
    echo "$hostname"
  done

  echo
  echo "SSH port(s) defined:"
  for port in "${ssh_ports[@]}"; do
    echo "$port"
  done

  echo
  echo "Dropbear will be tried ${dropbear_retries} times at ${dropbear_retry_delay} second intervals"
  echo "Dropbear port(s) defined:"
  for port in "${dropbear_ports[@]}"; do
    echo "$port"
  done
  
  echo
  if [[ -n "$passphrase" ]]; then
    echo "Unlock passphrase has been defined."
  else
    echo "WARNING: passphrase unlock not defined!"
  fi
}

# --- [ Load Configuration File ]---------------------------------------------
__load_config_file() {
  local configfile="$1"

  echo "-- ${0##*/} ${VERSION}: Loading configuration file: $configfile"
  if [ -f "$configfile" ]; then
    # shellcheck source=/dev/null
    source "$configfile"
  else
    __error_message "error: configuration file not found."
    exit 2
  fi
}

# --- [ Define Constants / Default Values ]------------------------------------
FALSE=0
TRUE=1
DEBUG="$FALSE"

# Default values, use the config file to override these!
configdir="$HOME/.config/host-check"
configfile="${configdir}/host-check.conf"
hostnames=("localhost")
ssh_ports=("22")
dropbear_ports=("222")
dropbear_retries="3"
dropbear_retry_delay="30" # seconds
host_state_retry_min="59" # minutes
webhook="not_defined"
passphrase=

# Make sure directory to hold state information exists
if ! mkdir -p "${configdir}"
then
  __error_message "error: unable to create state directory: ${configdir}"
  exit 2
fi

# --- [ Process Argument List ]-----------------------------------------------
if [ "$#" -ne 0 ]; then
  while [ "$#" -gt 0 ]
  do
    case "$1" in
    -a|--all)
      __load_config_file "$configfile"
      __process_all_hostnames "$passphrase"
      ;;
    -c|--config)
      configfile=$2
      ;;
    --debug)
      DEBUG="$TRUE"
      ;;
    -h|--help)
      __usage
      exit 0
      ;;
    -l|--list)
      __load_config_file "$configfile"
      __list_hosts_and_ports
      ;;
    -s|--ssh)
      hostname=$2
      __load_config_file "$configfile"
      hostnames=("$hostname")
      __process_all_hostnames "$passphrase"
      ;;
    -v|--version)
      echo "$VERSION"
      exit 0
      ;;
    --)
      break
      ;;
    -*)
      __error_message "Invalid option '$1'. Use --help to see the valid options"
      exit 2
      ;;
    # an option argument, continue
    *)  ;;
    esac
    shift
  done
else
  __usage
  exit 1
fi
