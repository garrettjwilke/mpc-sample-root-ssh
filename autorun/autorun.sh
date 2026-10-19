#!/bin/sh
# Akai MPC Sample SSH server, RAM-only configuration. Does not modify eMMC.
set -u
D=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
REPORT="$D/SSH_START.txt"
RAM=/run/mpc-sample-ssh
exec > "$REPORT" 2>&1
trap 'sync' EXIT
printf '%s\n' '=== MPC SAMPLE USB SSH START ==='
date
id
if [ "$(id -u)" != '0' ]; then echo 'ERROR: root required'; exit 1; fi
if [ ! -x /usr/sbin/sshd ] || [ ! -x /usr/bin/ssh-keygen ]; then
  echo 'ERROR: system OpenSSH missing'; exit 1
fi
if [ ! -s "$D/authorized_keys" ] || [ ! -s "$D/ssh_host_ed25519_key" ]; then
  echo 'ERROR: Mac setup not completed: required SSH keys missing on SD'; exit 1
fi
# The USB network can appear after the SD autorun event. Wait before binding.
echo 'Waiting up to 45 seconds for USB IP 192.168.155.1...'
usb_wait=0
while ! grep -q '192.168.155.1' /proc/net/fib_trie 2>/dev/null; do
  if [ "$usb_wait" -ge 45 ]; then
    echo 'ERROR: USB IP absent after 45 seconds; SSH not started. Connect USB-C to the computer and run the SD autorun again.'
    exit 1
  fi
  sleep 1
  usb_wait=$((usb_wait + 1))
done
echo "USB_IP_READY=YES waited_seconds=$usb_wait"
umask 077
mkdir -p "$RAM" /run/sshd || exit 1
chmod 700 "$RAM"
chmod 755 /run/sshd
cp "$D/authorized_keys" "$RAM/authorized_keys" || exit 1
cp "$D/ssh_host_ed25519_key" "$RAM/ssh_host_ed25519_key" || exit 1
chmod 600 "$RAM/authorized_keys" "$RAM/ssh_host_ed25519_key"
cat > "$RAM/sshd_config" <<'SSHCONF'
Port 2222
ListenAddress 192.168.155.1
HostKey /run/mpc-sample-ssh/ssh_host_ed25519_key
PidFile /run/mpc-sample-ssh/sshd.pid
AuthorizedKeysFile /run/mpc-sample-ssh/authorized_keys
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AllowUsers root
StrictModes yes
UseDNS no
PermitTTY yes
PermitUserEnvironment no
PrintMotd no
PrintLastLog no
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
LogLevel VERBOSE
SSHCONF
printf '%s\n' 'Testing config...'
if ! /usr/sbin/sshd -t -f "$RAM/sshd_config"; then
  echo 'ERROR: SSHD config validation failed'; exit 1
fi
if [ -s "$RAM/sshd.pid" ]; then
  oldpid=$(cat "$RAM/sshd.pid" 2>/dev/null)
  if kill -0 "$oldpid" 2>/dev/null; then
    echo "SSH already running, PID=$oldpid"; exit 0
  fi
fi
printf '%s\n' 'Starting sshd on USB IP 192.168.155.1:2222...'
if ! /usr/sbin/sshd -f "$RAM/sshd_config" -E "$D/SSH_AUTH_LOG.txt"; then
  echo 'ERROR: SSHD refused start'
  cat "$D/SSH_AUTH_LOG.txt" 2>/dev/null || true
  exit 1
fi
sleep 1
started_pid=$(cat "$RAM/sshd.pid" 2>/dev/null || true)
case "$started_pid" in
  ''|*[!0-9]*) started_pid=0 ;;
esac
if [ "$started_pid" -gt 1 ] && kill -0 "$started_pid" 2>/dev/null; then
  echo "SSH_STARTED=YES PID=$started_pid"
else
  echo 'ERROR: SSH server did not remain running; see log below'
  cat "$D/SSH_AUTH_LOG.txt" 2>/dev/null || true
  exit 1
fi
cat "$D/SSH_AUTH_LOG.txt" 2>/dev/null || true
printf '%s\n' 'Auth debug log: autorun/SSH_AUTH_LOG.txt (on SD)'
printf '%s\n' 'This autorun has not modified internal persistent storage.'
