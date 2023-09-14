# Passphrase Host Check

This BASH script is intended to check if remote hosts are waiting at a passphrase prompt to unlock encrypted volumes at boot which are exposed via an SSH daemon such as [Dropbear](https://github.com/mkj/dropbear).  This script will parse potential prompts and enter the passphrase to allow the remote boot to progress.

## Tested Against Remotes Using

* Ubuntu using Encrypted ZFS on Root with passphrase using Dropbear (`boot` and `root` pool method)
* Ubuntu using Encrypted ZFS on Root with ZFS Boot Menu using Dropbear (single `root` pool method)

---

## Features

* Scan a single remote host or predefined list of remote hosts
* Multiple SSH ports can be checked (for people who don't like using `22`) - _if SSH is available, then host is healthy and not at passphrase prompt._
* Multiple Dropbear SSH ports can be checked
* Easily customized notification on results of passphrase (mailx, slack webhook, etc)
* Customizable steps to take upon Dropbear passphrase failure

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

# Define array of possible SSH ports to check:
ssh_ports=("22")

# Define array of possible Dropbear ports to check:
dropbear_ports=("222" "2222")

# Webhook Notifications used in __send_notification() subroutine
webhook="https://hooks.slack.com/<webhook_uri_here>"

# Passphrase to unlock remote dropbear volumes (Use single quotes!) 
passphrase='mySecret!'
```

* `hostnames` is BASH array of hostnames that will be checked each time the script is run when a `-a` or `--all` parameter is passed.
* `ssh_ports` is a BASH array of SSH port numbers to check. Typically just `22` is used, but alternate ports can be specified.
  * If any of the `ssh_ports` ports are detected to be `open` then the remote host is fully booted and not waiting for a passphrase.  No other action is taken, next host is checked.
* `dropbear_ports` is a BASH array of SSH port numbers to check. Typical numbers are `222` or `2222`, additional ports can be added if needed.
  * If any of these ports are detected to be `open` then the host is waiting for a passphrase. The Host-Check script will then attempt to answer the passphrase prompt.
  * If the remote host has neither SSH or Dropbear ports open, then the host is powered off, hung or some other error condition.  A notification can be sent when this is detected.
* `webhook` can be populated with a webhook URL of your choice to send a notification to.  This allows easy notifications to Slack, Mattermost, etc.
* `passphrase` is the password or passphrase needed to unlock remote disk volumes via Dropbear.
  * This value needs to be wrapped by single-quotes to prevent shell processing of special characters.

---

### Modifications

There are 2 routines within the script you may want to consider making modifications:

* `__send_notification()` is called to send a notification.  By default it sends a webhook notification to the URL specified in variable `$webhook`.
  * If you would rather an email, then you can modify this to use `mailx` or some other email client.  The content of the notification is in variable `$message`.

* `__dropbear_failed_payload()` is called when no SSH ports are detected, no dropbear ports are detected or the passphrase to unlock the volume failed.
  * Often there is nothing you can do about it, just needs a human to investigate.
  * The example shows self-hosted kubernetes nodes having a `taint` applied which notified the rest of the cluster that this host will not be available until a human does something.
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
  host-check.sh | Version: 0.06 | 09/13/2023 | Richard J. Durso

  Check if hosts are stuck at Dropbear passphrase prompt.
  ----------------------------------------------------------------------------

  This script will check a defined list of hostname(s) to determine if any of
  the hosts are waiting for a Dropbear passphrase before booting. If detected
  the script will enter the passphrase to allow the remote system to resume
  its boot process.

  --debug           : Show expect screen scrape in progress.
  -c, --config      : Full path and name of configuration file.
  -a, --all         : Process all hosts, all ports, all passphrase prompts.
  -d, --dropbear    : Detect if dropbear ports are open on specified host.
  -l, --list        : List defined hostnames and ports within the script.
  -s, --ssh         : Detect if ssh ports are open on specified host.
  -h, --help        : This usage statement.
  -v, --version     : Return script version.
  
  host-check.sh [--debug] [-c <path/name.config>] [-flags] [-a | <hostname>]

  Default configuration file: /home/user/.config/host-check/host-check.conf
```

---

#### Examples

1. Individual Host with Successful Passphrase:

    ```shell
    $  host-check.sh -d testlinux

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
    $  host-check.sh --debug -d testlinux

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

    Connection to k3s01 (192.168.10.215) 22 port [tcp/*] succeeded!
    Connection to k3s02 (192.168.10.216) 22 port [tcp/*] succeeded!
    Connection to k3s03 (192.168.10.217) 22 port [tcp/*] succeeded!
    Connection to k3s04 (192.168.10.218) 22 port [tcp/*] succeeded!
    Connection to k3s05 (192.168.10.219) 22 port [tcp/*] succeeded!
    Connection to k3s06 (192.168.10.210) 22 port [tcp/*] succeeded!
    ```

    * All hosts are up with SSH ports open, nothing to do!

4. List Current Configuration:

    ```shell
    $ host-check.sh -l

    Hostname(s) defined:
    k3s01
    k3s02
    k3s03
    k3s04
    k3s05
    k3s06

    SSH port(s) defined:
    22

    Dropbear port(s) defined:
    222
    2222

    Unlock passphrase has been defined.
    ```
