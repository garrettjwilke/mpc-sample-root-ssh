# Version 1.2 startup changes

The previous launcher offered a startup dialog and waited for USB inside the
autorun process, wrote SD logs, and called a global `sync` on exit. A project-load
hang was observed when booting with that autorun SD inserted. The exact blocking
operation was not isolated; this release does not claim to patch a stock firmware
bug or prove which of those operations was responsible.

The revised launcher:

- Uses `askQuestion: false`, avoiding a startup-time modal dialog. A prepared
  card starts USB-only SSH automatically with the owner's existing credentials.
- Performs only bounded setup in `/run`, then hands execution to a separate
  transient `mpc-sample-usb-ssh.service` using `systemd-run --no-block`.
- Orders that service after `ac50.service` without changing the stock unit.
- Waits up to 45 seconds for USB in the independent worker, then runs the stock
  `sshd -D -e` in the foreground under systemd supervision.
- Keeps configuration, active credentials and logs in tmpfs `/run`.
- Leaves an existing service or the known legacy SSH server running, preserving
  active sessions on repeated mount events.

No firmware, stock app, permanent unit or restart-lock file is patched.

## Validation on 19 October 2026

- Two full cold boots with the prepared SD inserted completed on the owner's
  MPC Sample AC50/AZ07 running firmware 1.3.0.12.
- Both boots had different kernel boot IDs and successful `uid=0(root)` SSH
  sessions. The new service was active from `/run/systemd/transient/`.
- The owner confirmed normal interface operation and working audio/pads.
- `ac50.service` stayed active with the original `/usr/bin/launch-ac50`, no
  drop-ins and no environment overrides.
- Stock `/usr/bin/MPC Sample` SHA-256 remained
  `b6584cba76e416e432ad202509099d34373dc2c3d6a8fb625f5678bf0193b508`.
- Runtime credentials remained root-owned with mode 0600, directory 0700.
- Nine offline shell integration tests cover nonblocking handoff, delayed/absent
  USB, invalid configuration, missing credentials, existing services/server,
  service-submission failure and the checksum contract.

The no-USB timeout is tested offline; a physical cold boot without USB and a
post-change rollback boot have not been repeated in this validation. Other
devices/firmware and the Windows setup script remain unverified.

## Developer checks

```sh
python3 -m unittest discover -s tests -v
python3 tools/check_autorun.py
python3 tools/build_release.py
```

Keep personal hardware logs and prepared keys out of Git and release archives.
