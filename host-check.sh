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
RELDATE="09/10/2023"
VERSION="0.04"
##############################################################################

### [ Define Variables ] #####################################################

# Define array of hostnames to loop over:
hostnames=("k3s01" "k3s02" "k3s03" "k3s04" "k3s05" "k3s06")

# Define array of possible SSH ports to check:
ssh_ports=("22")

# Define array of possible Dropbear ports to check:
dropbear_ports=("222" "2222")

# Webhook Notifications used in __send_notification() subroutine
webhook="https://hooks.slack.com/<WEBHOOK_HERE>"

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
  -a, --all         : Process all hosts, all ports, all passphrase prompts.
  -d, --dropbear    : Detect if dropbear ports are open on specified host.
  -l, --list        : List defined hostnames and ports within the script.
  -s, --ssh         : Detect if ssh ports are open on specified host.
  -h, --help        : This usage statement.
  -v, --version     : Return script version.
  
  ${0##*/} [--debug] [-flags] [-a | -all | <hostname>] ['passphrase']

  Note: passphrase should be wrapped in single-quotes when used.
  "
}

# ---[ How to handle notifications ]------------------------------------------
# This is a user defined area of how to handle notifications in the script.
# This can be changed to send email notification or slack channel webhook, etc.

__send_notification() {
  local message="$1"

  # Send notification via webhook
  if [ -n "$message" ]; then
    if curl -X POST -H 'Content-type: application/json' --data '{"text":"'"$message"'"}' "$webhook" > /dev/null 2> /dev/null
    then
      echo "-- -- Notification sent"
    fi
  fi
}

# ---[ What to do when Dropbear unavilable or failed ]------------------------
# This is user defined area of what to do if dropbear is not available or
# failed.  

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

  if [ -n "$passphrase" ]; then
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
  "Enter passphrase" {
    send -- "\$PASS\r"
    send_log -- "\rDEBUG: passphrase entered\r"
    sleep 1 
    send -- "\r" 
    exp_continue
  }

  # ZBM Welcome Banner
  "Welcome to the ZFSBootMenu initramfs shell" {
    send -- "zbm\r"
    sleep 1
    send -- "\r"
    set ret 0
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

  # This would be seen with ZBM and incorrect passphrase
  "No boot environments" {
    set ret 1
    send_log -- "\rDEBUG: No boot environments detected\r"
    exit
  }

  # Logoin prompt would be a good sign too
  "login:" {
    set ret 0
    send_log -- "\rDEBUG: Login prompt detected\r"
    exit
  }
}
exit \$ret
EOF

    output=$("$tmp_expect_script" "$passphrase")
    result=$?

    if [ "$DEBUG" == "$TRUE" ]; then
      # Strip out ANSI color and cursor codes used by ZFS Boot Menu if present
      echo "-- -- DEBUG:"
      output=$(sed 's/\x1B[@A-Z\\\]^_]\|\x1B\[[0-9:;<=>?]*[-!"#$%&'"'"'()*+,.\/]*[][\\@A-Z^_`a-z{|}~]//g' < "$tmp_expect_log" | strings) 
      echo "$output"
    fi
    # Cleanup temp file    
    rm "$tmp_expect_script" "$tmp_expect_log"
    return $result
  else
    echo "error: passphrase required (be sure to wrap passphrase within single quotes!)" >&2
    exit 1
  fi
}

# ---[ Detect if DropBear Port is opened ]------------------------------------
__detect_dropbear_port() {
  local hostname="$1"
  local passphrase="$2"
  local result=1

  if [ -n "$hostname" ]; then
    echo "-- Dropbear check on host: $hostname"

    for port in "${dropbear_ports[@]}"; do
      nc -z -w1 "$hostname" "$port"
      result=$?

      if [ $result -eq 0 ]; then
        echo "-- -- Dropbear port $port is open on $hostname"
        __answer_passphrase "$hostname" "$passphrase"
        if [ $? -eq 0 ]; then
          echo "-- -- No error detected in passphrase exchange"
          __send_notification "Successful dropbear passphrase given to: $hostname"
          break
        else
          echo "-- -- Error detected during passphrase exchange"
          __send_notification "ERROR: Dropbear passphrase failed with: $hostname"
        fi
      else
        echo "-- -- Dropbear port $port is not open on $hostname"
      fi
    done
    return $result
  else
    echo "error: hostname required" >&2
    exit 1
  fi
}

# ---[ Process SSH Ports ]----------------------------------------------------
# detect if any of the defined ssh ports are active for specified host
__detect_ssh_ports() {
  local hostname="$1"
  local result=1

  if [ -n "$hostname" ]; then
    for port in "${ssh_ports[@]}"; do
      nc -z -w1 "$hostname" "$port"
      result=$?

      if [ $result -eq 0 ]; then
        # no need to check any additional ports
        break
      else
        echo "Connection to $hostname ($(getent hosts "$hostname" | awk '{print $1}')) $port port failed!"
      fi
    done
    return $result
  else
    echo "error: hostname required" >&2
    exit 1
  fi
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
      fi
    echo
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
  echo "Dropbear port(s) defined:"
  for port in "${dropbear_ports[@]}"; do
    echo "$port"
  done
}

FALSE=0
TRUE=1
DEBUG="$FALSE"

# --- [ Process Argument List ]-----------------------------------------------
if [ "$#" -ne 0 ]; then
  while [ "$#" -gt 0 ]
  do
    case "$1" in
    -a|--all)
      passphrase=$2
      __process_all_hostnames "$passphrase"
      ;;
    -d|--dropbear)
      hostname=$2
      passphrase=$3
      __detect_dropbear_port "$hostname" "$passphrase"
      ;;
    --debug)
      DEBUG="$TRUE"
      ;;
    -h|--help)
      __usage
      exit 0
      ;;
    -l|--list)
      __list_hosts_and_ports
      ;;
    -s|--ssh)
      hostname=$2
      __detect_ssh_ports "$hostname"
      ;;
    -v|--version)
      echo "$VERSION"
      exit 0
      ;;
    --)
      break
      ;;
    -*)
      echo "Invalid option '$1'. Use --help to see the valid options" >&2
      exit 1
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
