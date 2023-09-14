# Create Systemd Timer Units

During my testing, I found it easier to use a `systemd timer` running as as regular user (my account, not root) which allows access to my SSH configuration and keys.

---

## Create User Service

The following creates a service file in your home directory.

```bash
vi ~/.config/systemd/user/hostcheck.service
```

Cut and paste the following content:

```text
[Unit]
Description=Check Remote Hosts for Dropbear prompts

[Service]
Type=simple
ExecStart=/usr/local/bin/host-check.sh --debug -a 

[Install]
WantedBy=default.target
```

* `--debug` enabled more detailed logging such as messages from SSH screen scrape
* `-a` will scan all defined hostnames

### Enable and Test Service

NOTE: as this is non-root, `sudo` is not required:

```bash
systemctl --user enable hostcheck.service
```

```bash
systemctl --user start hostcheck.service
```

Review output / logs:

```bash
systemctl --user status hostcheck.service
```

If you have an error and need to make service corrections, then to reload the service file:

```bash
systemctl --user daemon-reload
```

---

## Create Timer Service

Once you have tested the service manually, you can schedule the service to be called at regular intervals such as hourly, or every 10 minutes, whatever you needs require.

```bash
vi ~/.config/systemd/user/hostcheck.timer
```

Cut and paste the following content:

```text
[Unit]
Description=Run hostcheck service every 10 minutes

[Timer]
#Execute job if it missed a run due to machine being off
Persistent=true
#Run 120 seconds after boot for the first time
OnBootSec=120
#Run every 10 minute thereafter
OnCalendar=*:0/10
#File describing job to execute
Unit=hostcheck.service

[Install]
WantedBy=timers.target
```

### Enable and Test Timer Service

NOTE: as this is non-root, `sudo` is not required:

```bash
systemctl --user enable hostcheck.timer
```

```bash
systemctl --user start hostcheck.timer
```

### Monitor Timer Service

```bash
$ journalctl -b -f | grep "host-check.sh"

Sep 13 21:20:01 dldsk01 host-check.sh[3267113]: -- Loading configuration file: /home/user/.config/host-check/host-check.conf
Sep 13 21:20:01 dldsk01 host-check.sh[3267118]: Connection to k3s01 (192.168.10.215) 22 port [tcp/*] succeeded!
Sep 13 21:20:01 dldsk01 host-check.sh[3267119]: Connection to k3s02 (192.168.10.216) 22 port [tcp/*] succeeded!
Sep 13 21:20:01 dldsk01 host-check.sh[3267120]: Connection to k3s03 (192.168.10.217) 22 port [tcp/*] succeeded!
```

* `-b` show this boot only
* `-f` tail journal log for additional messages

```bash
$ systemctl --user list-timers hostcheck

NEXT                        LEFT         LAST                        PASSED   UNIT            ACTIVATES        
Wed 2023-09-13 17:30:00 EDT 4min 7s left Wed 2023-09-13 17:20:01 EDT 5min ago hostcheck.timer hostcheck.service

1 timers listed.
```
