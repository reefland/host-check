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
RELDATE="02/13/2025"
VERSION="0.21"
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
  -t, --test        : Send test message to defined notifications.
  -h, --help        : This usage statement.
  -v, --version     : Return script version.
  
  ${0##*/} [--debug] [-c <path/name.config>] [-flags] [-a | <hostname>]

  Default configuration file: ${configfile}
  "
}

# ---[ Error Handler ]--------------------------------------------------------
# Write error messages to STDERR.

__error_message() {
  echo "[$(date "$timestamp_format")]: $*" >&2
}

# ---[ How to handle notifications ]------------------------------------------
# This is a user defined area of how to handle notifications in the script.
# This can be changed to send email notification or slack channel webhook, etc.

__send_notification() {
  local message="$1"

  # Confirm a webhook has been defined
  if [[ -z "$webhook" || "$webhook" == "not_defined" ]]; then
    __error_message "error: __send_notification() to webhook, but webhook has not been defined."
  fi

  # Send notification via webhook
  if [[ -n "$message" ]]; then
    if curl -X POST -H 'Content-type: application/json' --data '{"text":"'"$message"'"}' "$webhook" > /dev/null 2> /dev/null
    then
      echo "-- -- Notification sent (${message})"
    fi
  fi
}

# ---[ Process health check heartbeat for Monitoring ]-------------------------
# This script can signal a heartbeat to a monitoring service to notify this
# script has run to completion. If this script stops running (cron issue, host
# issue, etc.) then the monitoring service can alert you to a problem. If this
# script is scheduled to run every 5 minutes, you can configure the monitor to
# sent you an alert after 7 minutes without a heartbeat for example.

__send_heartbeat() {
  if [[ "$enable_healthcheck" == "$TRUE" ]]; then
    # Confirm a  has been defined
    if [[ -z "$healthcheck" || "$healthcheck" == "not_defined" ]]; then
      __error_message "error: __send_heartbeat() to healthcheck, but healthcheck has not been defined."
    fi

    if curl -m 10 --retry 5 "$healthcheck" > /dev/null 2> /dev/null
    then
      echo "-- -- Heartbeat sent (OK)"
    else
      __error_message "error: __send_heartbeat() to healthcheck failed"
    fi
  fi
}

# ---[ What to do when Dropbear unavailable or failed ]------------------------
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
#    message="Node taints to fence $hostname successful."
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

  # Login prompt would be a good sign too
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

  # This would be seen with traditional ZFS on Root
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

      # Skip sleep if this was the last host to check
      [[ "${retries}" -ne "${dropbear_retries}" ]] && sleep "$dropbear_retry_delay"
    done # retries

    if [[ "${retries}" -eq "${dropbear_retries}" ]]; then
      # Skip notification if host is known to be down
      if __check_host_state "$hostname"
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
  local state=""

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
        [[ -f "${configdir}/${hostname}.down" ]] && state="Host known to be down" || state="New incident detected!"

        echo "Connection to ${hostname} ($(getent hosts "$hostname" | awk '{print $1}')) ${port} port failed! [${state}]"
      fi
    done
    return $result
  else
    __error_message "error: hostname required"
    exit 2
  fi
}

# ---[ Create Host State File ]-----------------------------------------------
# This will create a simple file with the name of the host used to indicate
# that host is down. The datestamp in seconds (since the UNIX epoch) is written
# to the file to track when it was marked as down. If the file already exists
# do not create a new one, need to preserve the timestamp.

__create_host_state() {
  local hostname="$1"
  local result=1

  if [[ -n "$hostname" ]]; then
    if [[ ! -f "${configdir}/${hostname}.down" ]]; then
      if date +%s > "${configdir}/${hostname}.down"
      then
        result=0
      else
        __error_message "error: unable to create host state file - ${configdir}/${hostname}.down"
      fi
    fi
  else
    __error_message "error: hostname required"
    exit 2
  fi

  return $result
}

# ---[ Check Host State File ]------------------------------------------------
# Check if a Host State File exists for the specified host.  If it does exist
# and is older than "host_state_retry_min" (minutes) then update timestamp to
# now. This will allow a notification to be triggered again.

__check_host_state() {
  local hostname="$1"
  local result=1

  if [[ -n "$hostname" ]]; then
    if [[ -f "${configdir}/${hostname}.down" ]]; then
      # if Host State File is older than retry minutes, uptime timestamp (allows next notifications again)
      # return code to allow notification
      if [[ -n $(find "${configdir}" -name "${hostname}.down" -mmin "+${host_state_retry_min}" -type f) ]]; then
        find "${configdir}" -name "${hostname}.down" -mmin "+${host_state_retry_min}" -type f -exec touch {} \;
        result=0
      fi
    else
      # no existing host state file, return code to allow notification
      result=0
    fi
  else
    __error_message "error: hostname required"
    exit 2
  fi
  return $result
}

# --- [ Get Host Down Duration ]-----------------------------------------------
# Get the host down timestamp from the host down file and calculate down
# duration to now in seconds. Returns number of seconds host has been down.

__get_host_down_duration_seconds() {
  local hostname="$1"
  local result=1
  local initial_down=""
  local now=""

  if [[ -n "$hostname" ]]; then
    if [[ -f "${configdir}/${hostname}.down" ]]; then
      initial_down=$(cat "${configdir}/${hostname}.down")
      now=$(date +%s)
      echo $((now - initial_down))
    else
      __error_message "error: host not down"
      exit 2
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
  local host_down_seconds=""
  local now=""

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
          # See if host down is longer than host failed threshold
          host_down_seconds=$(__get_host_down_duration_seconds "$hostname")
          if [[ "$host_down_seconds" -gt $((host_state_failed_threshold * 60)) ]];then
            # Process user defined steps to handle failed dropbear
            __dropbear_failed_payload "$hostname"
          else
            # Calculate when host failed threshold will be reached
            now=$(date +%s)
            echo "-- Host $hostname failed threshold set at: $(date -d @$(( now + (host_state_failed_threshold * 60) - host_down_seconds)) "$timestamp_format")"
          fi
        fi
        echo
      fi
  done
  
  __send_heartbeat
}

# --- [ List Hosts and Ports ]------------------------------------------------
# List all hostnames and port numbers defined within this script.

__list_hosts_and_ports() {
  local hostname=""
  local port=""
  local state=""
  local now=""
  
  now=$(date +%s)
  echo "Hostname(s) defined:"
  for hostname in "${hostnames[@]}"; do
    if [[ -f "${configdir}/${hostname}.down" ]]; then
      host_down_seconds=$(__get_host_down_duration_seconds "$hostname")
      state="[ Host marked down via state file ${configdir}/${hostname}.down since $(date -d @$(( now - host_down_seconds)) "$timestamp_format") ]"
    else
      state=""
    fi
    echo "${hostname} ${state}" 
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

  echo "-- ${0##*/} v${VERSION}: Loading configuration file: $configfile"
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
timestamp_format="+%Y-%m-%dT%H:%M:%S%z"  # 2023-09-25T12:56:02-0400

# Default values, use the config file to override these!
configdir="$HOME/.config/host-check"
configfile="${configdir}/host-check.conf"
hostnames=("localhost")
ssh_ports=("22")
dropbear_ports=("222")
dropbear_retries="3"
dropbear_retry_delay="30" # seconds
host_state_retry_min="59" # minutes
host_state_failed_threshold="180" # minutes
enable_healthcheck="$FALSE"
webhook="not_defined"
healthcheck="not_defined"
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
    -t|--test)
      __load_config_file "$configfile"
      __send_notification "Test message from ${0##*/}"
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
