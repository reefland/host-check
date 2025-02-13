# Passphrase Host Check

This BASH script is intended to check if remote hosts are waiting at a passphrase prompt to unlock encrypted volumes at boot which are exposed via an SSH daemon such as [Dropbear](https://github.com/mkj/dropbear).  This script will parse potential prompts and enter the passphrase to allow the remote boot to progress.

## Tested Against Remotes Using

* Ubuntu using Encrypted ZFS on Root with passphrase using Dropbear (`boot` and `root` pool method)
* Ubuntu using Encrypted ZFS on Root with ZFS Boot Menu using Dropbear (single `root` pool method)

---

## Features

* Scan a single remote host or predefined list of remote hosts.
* Multiple SSH ports can be checked (for people who don't like using `22`) - _if SSH is available, then host is healthy and not at passphrase prompt._
* Multiple Dropbear SSH ports can be checked.
* Easily customized notification on results of passphrase (mailx, slack or Discord webhook, etc.)
* Customizable steps to take upon Dropbear passphrase failure.
* Heartbeat health checks can be enabled to monitoring service like [healthchecks.io](https://healthchecks.io/) to alert you if this script stops processing.

---

### Prerequisites

* You will need `unlock-<hostname>` script naming convention for your remote hosts. These are easily defined within your `~/.ssh/config` file such as:

  ```text
  Host unlock-testlinux
    Hostname testlinux.mydomain.com
    IdentityFile /home/someuser/.ssh/dropbear_ed25519
    user root
    IdentitiesOnly yes
    Port 222
    RequestTTY yes
    RemoteCommand zfsbootmenu
  ```

  * Host-Check BASH script only cares about the `Host unlock-<hostname>` line, the rest is just however you normally connect to the remote Dropbear to enter a passphrase.

The following packages are required to be installed:

* `expect` - this does the text parsing of SSH prompts and enters the provided passphrase.
* `nc` - is used to detect if remote SSH ports are opened.
* `curl` - used to send webhook notifications.
* `strings` - used to filter non-printable characters when `--debug` mode is enabled

---

### Configuration

Configuration is defined via an external configuration file.

* The default location is: `$HOME/.config/host-check/host-check.conf`
  * An alternate file can be specified with the `--config` parameter

#### Example Configuration File

```text
# Define array of hostnames to loop over:
hostnames=("k3s01" "k3s02" "k3s03" "k3s04" "k3s05" "k3s06")

# Passphrase to unlock remote dropbear volumes (Use single quotes!) 
passphrase='mySecret!'

# Webhook Notifications used in __send_notification() subroutine
webhook="https://hooks.slack.com/<webhook_uri_here>"

# Webhook to "monitor the monitor". Send notification on each run to healthchecks.io
# to get an alert if this stops running.
healthcheck="https://<webhook_uti_here>"

# Set to 1 to enable heart beat health check, anything else to disable.
enable_healthcheck=0

# Define array of possible SSH ports to check:
ssh_ports=("22")

# Define array of possible Dropbear ports to check:
dropbear_ports=("222" "2222")

# Define how many times dropbear connection should be tried before
# determining host down. Allow enough time typical system initialization
dropbear_retries="6"

# How many seconds delay between dropbear connection attempts
dropbear_retry_delay="20"

# Delay in minutes to wait between notifications of host down (reduces spamming alerts)
host_state_retry_min="59"

# How many minutes must a host be down before calling __dropbear_failed_payload()
host_state_failed_threshold="180" 
```

| Variable  | Description |
|---        |---          |
|`hostnames`  | is BASH array of hostnames that will be checked each time the script is run when a `-a` or `--all` parameter is passed. |
|`passphrase` | is the password or passphrase needed to unlock remote disk volumes via Dropbear.  This value needs to be wrapped by single-quotes to prevent shell processing of special characters. |
|`webhook`    | can be populated with a webhook URL of your choice to send a notification to.  This allows easy notifications to Slack, Discord, Mattermost, etc. |
|`healthcheck`| a heartbeat webhook sent to a push notification service such as healthchecks.io to monitor this script is working at expected intervals. |
|`enable_healthcheck`| a simple toggle to enable / disable sending a heartbeat webhook. |
|`ssh_ports`  | is a BASH array of SSH port numbers to check. Typically just `22` is used, but alternate ports can be specified. If any of the `ssh_ports` ports are detected to be `open` then the remote host is assumed to be fully booted and not waiting for a passphrase.  No other action is taken, next host is checked. |
|`dropbear_ports` | is a BASH array of SSH port numbers to check. Typical numbers are `222` or `2222`, additional ports can be added if needed. If any of these ports are detected to be `open` then the host is waiting for a passphrase. The Host-Check script will then attempt to answer the passphrase prompt. If the remote host has neither SSH or Dropbear ports open, then the host is powered off, hung or some other error condition.  A notification can be sent when this is detected. |
|`dropbear_retries` | is an integer number of how many times to check all defined Dropbear ports for a connection before returning a failed/host down status. |
|`dropbear_retry_delay` | is an integer number of how many seconds to wait between Dropbear connection attempts.|
|`host_state_retry_min` | is an integer number of how many consecutive minutes to wait before sending next alert when a host is down.  This is to help reduce the amount of spam alerts messages generated.  |
|`host_state_failed_threshold`  | is an integer number of how many consecutive minutes a host needs to be down before sub-routine __dropbear_failed_payload() is executed. |

---

### Modifications

There are some routines within the script you may want to consider making modifications. Instead of editing the script directly, simply cut & paste the default routine from the script and place it in the config file (`host-check.conf`).  Customize the version within your config file.

* `__send_notification()` is called to send a notification.  
  * By default it sends a webhook notification to the URL specified in variable `$webhook`.
  * If you would rather send an email, then you can modify this to use `mailx` or some other email client.  The content of the notification is in variable `$message`.

* `__send_heartbeat()` is called each time the `-a` or `--all` (process all hosts) switch it used. This sends a message (webhook, email, etc) to monitoring service used as a heartbeat that this script is operating as expected. (This has nothing to do with status of scanned hosts).
  * By default it sends a heartbeat to the URL specified in variable `$healthcheck` if variable `$enable_healthcheck` is set to `1` to enable this.
  * If you would rather send an email, then you can modify this to use `mailx` or some other email client.

* `__dropbear_failed_payload()` is called when no SSH ports are detected, no dropbear ports are detected or the passphrase to unlock the volume failed.
  * Often there is nothing you can do about it, just needs a human to investigate.
  * The example within the script shows self-hosted kubernetes nodes having a `taint` applied which notified the rest of the cluster that this host will not be available until a human does something.
  * The variable `$hostname` will contain the name of the host having an issue.

* `__answer_passphrase()` can be modified if you use LUKS encryption.  You would add an entry with the passphrase text prompt to look for modeled after this entry:

  ```text
  "Enter passphrase" {
    send -- "\$PASS\r"
    send_log -- "\rDEBUG: passphrase entered\r"
    sleep 1 
    send -- "\r" 
    exp_continue
  }
  ```

---

#### Installation

Download a copy of the script and place it where you like. Once downloaded, you use `install`:

```shell
$ sudo install host-check.sh /usr/local/bin

$ ls -l /usr/local/bin/host-check.sh

-rwxr-xr-x 1 root root 9710 Aug 26 18:27 /usr/local/bin/host-check.sh
```

* Create configuration file `$HOME/.config/host-check/host-check.conf` as outlined above.
* Once configured [create systemd timer](./docs/create_systemd_timer.md) to run the host-check script as needed.

---

### Usage Statement

```text
  host-check.sh | Version: 0.20 | 02/13/2025 | Richard J. Durso

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
  
  host-check.sh [--debug] [-c <path/name.config>] [-flags] [-a | <hostname>]

  Default configuration file: /home/user/.config/host-check/host-check.conf
```

---

#### Examples

1. Individual Host with Successful Passphrase:

    ```shell
    $  host-check.sh -s testlinux

    Connection to testlinux (192.168.10.110) 22 port failed! [New incident detected!]
    -- Dropbear check on host: testlinux
    Connection to testlinux (192.168.10.110) 222 port [tcp/rsh-spx] succeeded!
    -- -- Dropbear port 222 is open on testlinux
    -- -- Attempting Dropbear passphrase on testlinux
    -- -- No error detected in passphrase exchange
    -- -- Notification sent
    ```

    NOTE: The passphrase must be wrapped in single-quotes to prevent BASH, ZSH, Linux for acting on special characters.

    * Slack Webhook notification:
      ![slack notification example](./docs/slack_notification_sucessful.png)

2. Individual Host with Debug Mode and Successful Passphrase:

    ```shell
    $  host-check.sh --debug -s testlinux

    Connection to testlinux (192.168.10.110) 22 port failed! [Host known to be down]
    -- Dropbear check on host: testlinux
    Connection to testlinux (192.168.10.110) 222 port [tcp/rsh-spx] succeeded!
    -- -- Dropbear port 222 is open on testlinux
    -- -- Attempting Dropbear passphrase on testlinux
    spawn ssh unlock-testlinux
    Enter passphrase for 'rpool':
    1 / 1 key(s) successfully loaded
    ZFS Root Pool Decrypted
    -- -- No error detected in passphrase exchange
    -- -- Notification sent
    ```

    * The `--debug` mode enabled the expect screen scrape to be visible:

      ```text
      spawn ssh unlock-testlinux
      Enter passphrase for 'rpool':
      1 / 1 key(s) successfully loaded
      ZFS Root Pool Decrypted
      ```

3. Scan all defined hosts:

    ```shell
    $ host-check.sh -a

    -- host-check.sh v0.21: Loading configuration file: /home/user/.config/host-check/host-check.conf
    Connection to k3s01 (192.168.10.215) 22 port [tcp/*] succeeded!
    Connection to k3s02 (192.168.10.216) 22 port [tcp/*] succeeded!
    Connection to k3s03 (192.168.10.217) 22 port [tcp/*] succeeded!
    Connection to k3s04 (192.168.10.218) 22 port [tcp/*] succeeded!
    Connection to k3s05 (192.168.10.219) 22 port [tcp/*] succeeded!
    Connection to k3s06 (192.168.10.220) 22 port [tcp/*] succeeded!
     -- -- Heartbeat sent (OK)
    ```

    * All hosts are up with SSH ports open, nothing to do!

4. List Current Configuration (and status of tracked hosts):

    ```shell
    $ host-check.sh -l

    -- host-check.sh v0.17: Loading configuration file: /home/user/.config/host-check/host-check.conf
    Hostname(s) defined:
    k3s01
    k3s02
    k3s03
    k3s04
    k3s05
    k3s06
    testlinux [ Host marked down via state file /home/user/.config/host-check/testlinux.down since 2023-09-25T13:11:53-0400 ]

    SSH port(s) defined:
    22

    Dropbear will be tried 6 times at 20 second intervals
    Dropbear port(s) defined:
    222
    2222

    Unlock passphrase has been defined.
    ```

5. Test notifications:

    ```shell
    $ ./host-check.sh -t

    -- host-check.sh v0.20: Loading configuration file: /home/user/.config/host-check/host-check.conf
    ok-- -- Notification sent (Test message from host-check.sh)
    ```

    * If webhooks or other notifications are defined within `__send_notification()` then a test message will be sent:

    ![test-message-results](./docs/discord_notification_sucessful_test.png)
