# MPC Sample — temporary root SSH over USB

By **puckcv** on MPC-Forums. Target: **Akai MPC Sample AC50/AZ07, firmware 1.3.0.12**.

Starts the built-in OpenSSH server through the stock SD autorun mechanism.
No firmware flashing or modified Akai binary is required. The device-side
autorun in this repository is the exact version the author successfully used
to log in on 19 October 2026. Version 1.2 starts SSH in a separate temporary
service: waiting for USB happens outside autorun, with all runtime logs in RAM.
SSH starts automatically when the prepared SD is detected; there is no dialog.

**Hardware validation:** two full cold boots with the prepared SD inserted,
successful root SSH on both boots, and normal interface/sound confirmed by
the device owner. The stock application hash and launch configuration remained
unchanged. This is validation on one MPC Sample, not on every firmware/device.

**USB address: `192.168.155.1` · SSH port: `2222` · User: `root`**

This is the MPC-side USB address used by this setup; it is not your Wi-Fi/router
address. Do not replace it with the computer's address. Other firmware versions
and beta builds have not been verified. macOS/Linux setup is host-tested;
the Windows setup script is provided but has not been run on Windows by the author.

> **Version 1.2 starts USB-only root SSH automatically with your personal keys.**
> You can leave the prepared SD inserted during startup or insert it after boot.
> To start without SSH, boot without the autorun card. Removing SD later does not
> stop a server that has already started.

## 1. Download

Download **mpc-sample-root-ssh-v1.2.0.zip** from
[Releases](https://github.com/orrpunk-art/mpc-sample-root-ssh/releases/latest)
and extract it on your computer. Use this fresh public download for each new
person/device. Do not download or reuse somebody else's prepared SD folder.

You need an exFAT SD card, an SD reader, a USB-C data cable and an SSH client.
Save your MPC project before testing. Back up an existing `autorun` folder on
the SD card; do not merge two autorun packages or reformat a card containing data.

## 2. Generate your own keys on the computer

Choose **one** setup method below. Both create:

| File | Where it belongs |
|---|---|
| `mpc_sample_client_ed25519` | Private client key: stays in your computer's `.ssh` folder |
| `mpc_sample_client_ed25519.pub` | Client public key: copied to `autorun/authorized_keys` |
| `ssh_host_ed25519_key` | Separate private server identity: on your personal SD, then copied to MPC RAM |
| `ssh_host_ed25519_key.pub` | Public server identity: used to check the first-connection fingerprint |

### macOS / Linux

Open Terminal in the extracted `mpc-sample-root-ssh` folder. If you extracted it
to Downloads, this is normally:

```sh
cd ~/Downloads/mpc-sample-root-ssh
sh setup_unix.sh
```

The script first checks `autorun.check`, then creates the keys. Choose a
passphrase when asked for the **client** key and enter it again to confirm.
Nothing appears while you type the passphrase; that is normal.
The separate host key is generated automatically without a passphrase so the
MPC can start the server. No keys are downloaded from anyone else.

Wait for `PERSONAL_AUTORUN_PREPARED`. Keep the displayed **host fingerprint**
for the first connection. You can display it again from this folder:

```sh
ssh-keygen -lf autorun/ssh_host_ed25519_key.pub
```

If the client-key filename already exists, setup stops instead of overwriting it.
Use a fresh extraction and choose a new filename, for example:

```sh
MPC_CLIENT_KEY="$HOME/.ssh/mpc_sample_client_new_ed25519" sh setup_unix.sh
```

Then use that new path in the SSH command. Do not run setup with `sudo`.

### Windows

Open PowerShell in the extracted folder. Check that OpenSSH Client is available:

```powershell
Get-Command ssh, ssh-keygen
```

If either command is missing, install the **OpenSSH Client** Windows optional
feature first. Run the included local setup script:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup_windows.ps1
```

This execution-policy option applies to that PowerShell process only. Inspect
the local script before running it. For the **client key**, choose and confirm
a passphrase. When the script announces the separate **SERVER HOST key**, leave
its passphrase empty: press Enter twice. Wait for `PERSONAL_AUTORUN_PREPARED`
and keep the displayed host fingerprint.

If a client key already exists, use a fresh extraction and a new filename:

```powershell
$env:MPC_CLIENT_KEY = "$HOME\.ssh\mpc_sample_client_new_ed25519"
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup_windows.ps1
```

Use the selected filename when connecting. Setup never intentionally overwrites keys.

## 3. Prepare the SD card

Copy the **whole generated `autorun` folder** to the **root of the exFAT SD**.
The result must be:

```text
SD card/
└── autorun/
    ├── autorun.json
    ├── autorun.check
    ├── autorun.sh
    ├── authorized_keys
    ├── ssh_host_ed25519_key
    └── ssh_host_ed25519_key.pub
```

Do not put the entire extracted repository inside `autorun`, and do not copy
only the contents of `autorun` directly into the SD root. Keep the client
private key on the computer. Safely eject the SD card from the computer.

## 4. Start SSH on the MPC

1. Save your project and safely eject the prepared SD from the computer.
2. Connect the MPC to the computer using a **USB-C data cable**.
3. Either insert the SD into the MPC's own slot before powering on, or insert/
   mount it through the normal storage interface after the MPC has booted.
4. SSH starts **automatically**. There is no **Start SSH** prompt in version 1.2.
5. Allow normal MPC startup and up to **45 seconds** for USB networking.

No USB mass-storage/controller-mode switch or Wi-Fi connection is required.
USB mass-storage mode exposes the SD to the computer; it is a different use
from running the MPC normally with USB networking for SSH.

If USB was absent for the entire 45-second wait, connect the cable and safely
unmount/reinsert/mount the SD, or normally reboot with the card and cable attached.
The SSH worker times out independently; it does not make autorun wait for USB.

## 5. Connect from the computer

**macOS / Linux Terminal:**

```sh
ssh -p 2222 -i ~/.ssh/mpc_sample_client_ed25519 root@192.168.155.1
```

**Windows PowerShell:**

```powershell
ssh -p 2222 -i "$HOME\.ssh\mpc_sample_client_ed25519" root@192.168.155.1
```

On the first connection, compare the server fingerprint with the one printed
by setup. If it matches, type `yes`. When asked for the key passphrase, enter
the **client-key passphrase you chose on your computer**. There is no shared
root password. If you chose another key filename, adjust the `-i` argument.

After login, run:

```sh
id
```

Expected: `uid=0(root)`. You now have a root shell. Use `exit` to disconnect.
Disconnecting the client does not stop the server.

## 6. Troubleshooting

- **No Start SSH prompt:** expected in version 1.2. Connect using the command
  above; this version starts SSH automatically when the prepared card is detected.
- **Connection refused:** wait up to 45 seconds. Check that this SD was prepared
  with your keys, the folder layout is correct, and the MPC is in normal operation
  rather than USB mass-storage mode. If USB was connected too late, safely
  unmount/reinsert/mount the card or normally reboot with USB attached.
- **USB/network startup errors:** after obtaining SSH, inspect the RAM logs:

  ```sh
  systemctl status mpc-sample-usb-ssh.service --no-pager
  cat /run/mpc-sample-ssh/setup.log
  cat /run/mpc-sample-ssh/worker.log
  ```

  Version 1.2 does not create new `SSH_START.txt` / `SSH_AUTH_LOG.txt` on SD.
  Old SD reports can remain from an earlier version; their timestamps do not
  describe the current run.
- **MPC hangs during project loading:** if the device is stuck, press and hold
  power until it switches off, remove the SD, then boot without it. Restore the
  working backup if needed. A forced shutdown can lose unsaved work. Earlier
  versions could hang when booted with the autorun card inserted; v1.2 moves
  startup work to a separate service and removes the startup dialog.
- **Connection timed out / no route:** check the USB connection and the computer's
  USB network interface. The target is `192.168.155.1`, not the computer's IP.
- **Permission denied (publickey):** use the private client key belonging to the
  public key copied into this card's `authorized_keys`.
- **Key already exists:** do not delete an existing key; choose a new filename
  with `MPC_CLIENT_KEY` as described above.
- **Host identification changed:** check that you intentionally generated a new
  server host key and compare fingerprints. If confirmed, remove only this
  endpoint's old known-host entry, then reconnect:

  ```sh
  ssh-keygen -R "[192.168.155.1]:2222"
  ```

Review logs before sharing them; they may contain authentication details.

## 7. Stop and remove

Save your work, disconnect SSH with `exit`, then use a **normal MPC shutdown/
reboot**. The temporary server/configuration do not survive reboot. To boot
without SSH, leave the autorun card out. Removing the card alone does
not stop an already running SSH server. Back up/remove the personal `autorun` folder
from the card on your computer when you no longer need it.

## Sharing and scope

Share the public repository/release ZIP only. **Never publish a prepared SD
folder, private keys or personal SSH logs.** Every person generates their own
client key and a separate host key for their device.

The script configures the existing sshd for root public-key login only, bound
to the USB address. Password login and forwarding are disabled. Configuration,
active credentials, logs and the temporary service are all under `/run`.
It does not flash firmware, replace the stock app, restart `ac50.service`, or
modify persistent SSH configuration. Normal OS activity may independently write
to internal storage. A root shell can modify the device: this kit supplies access,
not a recovery guarantee or a patched firmware.

For contributors, `python3 tools/check_autorun.py` verifies the exact-byte
checksum and `python3 tools/build_release.py` creates a keyless ZIP using a fixed
allowlist. The checksum covers raw JSON + script + firmware-specific salt;
generated keys are not listed in `files[]`, so key generation does not change it.
Any edit to the manifest or autorun script requires a new checksum and testing.
