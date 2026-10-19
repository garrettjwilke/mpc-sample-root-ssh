#!/bin/sh
# Host-side preparation only. Run on macOS/Linux, not on the MPC.
set -eu
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
A="$ROOT/autorun"
CLIENT_KEY=${MPC_CLIENT_KEY:-"$HOME/.ssh/mpc_sample_client_ed25519"}
HOST_KEY="$A/ssh_host_ed25519_key"

command -v ssh-keygen >/dev/null 2>&1 || { echo 'ERROR: ssh-keygen is required' >&2; exit 1; }
if command -v shasum >/dev/null 2>&1; then
  ACTUAL=$({ cat "$A/autorun.json" "$A/autorun.sh"; printf '%s' 'f7bed1c9-7e90-4731-9194-c996666b4331'; } | shasum -a 256 | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  ACTUAL=$({ cat "$A/autorun.json" "$A/autorun.sh"; printf '%s' 'f7bed1c9-7e90-4731-9194-c996666b4331'; } | sha256sum | awk '{print $1}')
else
  echo 'ERROR: shasum or sha256sum is required' >&2; exit 1
fi
EXPECTED=$(cat "$A/autorun.check")
[ "$ACTUAL" = "$EXPECTED" ] || { echo 'ERROR: autorun.check mismatch; use a clean download' >&2; exit 1; }
echo 'AUTORUN_CHECK_VERIFIED'
for path in "$CLIENT_KEY" "$CLIENT_KEY.pub" "$A/authorized_keys" "$HOST_KEY" "$HOST_KEY.pub"; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    printf 'ERROR: refusing to overwrite %s\n' "$path" >&2
    echo 'Use a clean extraction; choose MPC_CLIENT_KEY=/path/to/a/new/key if needed.' >&2
    exit 1
  fi
done
mkdir -p "$(dirname -- "$CLIENT_KEY")"
echo 'Creating your client key. Choose a passphrase when prompted.'
ssh-keygen -t ed25519 -a 64 -f "$CLIENT_KEY" -C 'mpc-sample-client'
chmod 600 "$CLIENT_KEY"
cp "$CLIENT_KEY.pub" "$A/authorized_keys"
echo 'Creating a separate server host key for your MPC.'
ssh-keygen -q -t ed25519 -N '' -f "$HOST_KEY" -C 'mpc-sample-host'
chmod 600 "$HOST_KEY"
echo ''
echo 'PERSONAL_AUTORUN_PREPARED'
echo 'Expected MPC host fingerprint (compare on first connection):'
ssh-keygen -lf "$HOST_KEY.pub"
echo 'Copy the complete autorun/ directory to the ROOT of an exFAT SD card.'
echo 'Keep the client private key on this computer. Do not publish the prepared folder.'
printf 'Connect: ssh -p 2222 -i "%s" root@192.168.155.1\n' "$CLIENT_KEY"
