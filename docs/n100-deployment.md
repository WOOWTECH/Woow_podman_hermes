# N100 deployment reliability

Provisioning waits up to 900 seconds for the gateway. Its enclosing systemd timeout is 1020 seconds so normal initialization can finish afterwards. The previous 300-second wait failed during simultaneous cold start on a four-core N100; account and model settings are unchanged.

The same runtime settings were exercised on an existing N100 with 53 containers. All containers recovered automatically after a physical reboot; the completed read-only check was at boot uptime 558.4 seconds. This is an observation, not a fixed startup-time guarantee.

[Physical-host evidence](https://github.com/WOOWTECH/Woow_ubuntu_version_control/blob/195dcda9357100a7821407e1c8469a349acc9831/distribution/docs/reboot-acceptance.md).
