#!/bin/sh
# Experimental cold-boot launcher. No waiting, SD log writes or global sync.
# Only /run is changed; SSH startup is owned by a separate transient service.
set -eu
umask 077

D=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RAM=/run/mpc-sample-ssh
UNIT=mpc-sample-usb-ssh

[ "$(id -u)" = 0 ] || exit 1
[ -x /usr/sbin/sshd ] || exit 1
command -v systemd-run >/dev/null 2>&1 || exit 1
command -v systemctl >/dev/null 2>&1 || exit 1
grep -q ' /run tmpfs ' /proc/mounts || exit 1
[ -s "$D/authorized_keys" ] || exit 1
[ -s "$D/ssh_host_ed25519_key" ] || exit 1

mkdir -p "$RAM" /run/sshd
chmod 700 "$RAM"
chmod 755 /run/sshd

# Unlock execution on the SD card (mounted noexec by edisksd on boot/insert).
mount -o remount,exec /media/MPC 2>/dev/null || true

# Repeated mount events must neither replace active credentials nor stop sessions.
if systemctl is-active --quiet "$UNIT.service"; then
  exit 0
fi
if [ -s "$RAM/sshd.pid" ]; then
  pid=$(cat "$RAM/sshd.pid")
  case "$pid" in
    ''|*[!0-9]*) pid=0 ;;
  esac
  if [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null &&
     [ "$(readlink "/proc/$pid/exe" 2>/dev/null || true)" = /usr/sbin/sshd ]; then
    exit 0
  fi
fi

cp "$D/authorized_keys" "$RAM/authorized_keys"
cp "$D/ssh_host_ed25519_key" "$RAM/ssh_host_ed25519_key"
chmod 600 "$RAM/authorized_keys" "$RAM/ssh_host_ed25519_key"

# Allow passwordless/keyless root login over USB by binding an empty root password in RAM.
if [ -r /etc/shadow ]; then
  sed 's/^root:[^:]*:/root::/' /etc/shadow > "$RAM/shadow"
  chmod 600 "$RAM/shadow"
  mount --bind "$RAM/shadow" /etc/shadow 2>/dev/null || true
fi

cat > "$RAM/sshd_config" <<'SSHCONF'
Port 2222
ListenAddress 192.168.155.1
HostKey /run/mpc-sample-ssh/ssh_host_ed25519_key
PidFile /run/mpc-sample-ssh/sshd.pid
AuthorizedKeysFile /run/mpc-sample-ssh/authorized_keys
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords yes
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

cat > "$RAM/worker.sh" <<'WORKER'
#!/bin/sh
set -eu
RAM=/run/mpc-sample-ssh
exec >> "$RAM/worker.log" 2>&1
echo 'MPC_SSH_WORKER_START'
date -u
mount -o remount,exec /media/MPC 2>/dev/null || true
mkdir -p /media/MPC/bin /media/MPC/scripts /media/MPC/webui 2>/dev/null || true

# 1. Configure /etc/profile in RAM so /media/MPC/bin and /media/MPC/scripts are in PATH
if [ -r /etc/profile ] && ! grep -q '/media/MPC/bin' /etc/profile 2>/dev/null; then
  if cp /etc/profile /run/mpc-profile 2>/dev/null; then
    cat >> /run/mpc-profile <<'PROFILE_EOF'

export PATH="/media/MPC/bin:/media/MPC/scripts:$PATH"
PROFILE_EOF
    mount --bind /run/mpc-profile /etc/profile 2>/dev/null || true
  fi
fi

# 2. Start mpc-webui on port 8080
if [ -x /media/MPC/bin/mpc-webui ] && ! pidof mpc-webui >/dev/null 2>&1; then
  /media/MPC/bin/mpc-webui 8080 0.0.0.0 >/run/mpc-webui.log 2>&1 &
fi

# 3. Run user boot hook if present
if [ -x /media/MPC/scripts/on-boot.sh ]; then
  /media/MPC/scripts/on-boot.sh || echo "WARN: on-boot.sh exited with $?"
elif [ -f /media/MPC/scripts/on-boot.sh ]; then
  /bin/sh /media/MPC/scripts/on-boot.sh || echo "WARN: on-boot.sh exited with $?"
fi

usb_wait=0
while ! grep -q '192.168.155.1' /proc/net/fib_trie 2>/dev/null; do
  if [ "$usb_wait" -ge 45 ]; then
    echo 'ERROR: USB IP absent after 45 seconds; stock MPC left running'
    exit 1
  fi
  sleep 1
  usb_wait=$((usb_wait + 1))
done
echo "USB_IP_READY=YES waited_seconds=$usb_wait"
/usr/sbin/sshd -t -f "$RAM/sshd_config"
echo 'Starting foreground sshd on USB 192.168.155.1:2222'
exec /usr/sbin/sshd -D -e -f "$RAM/sshd_config"
WORKER
chmod 700 "$RAM/worker.sh"

# --no-block queues the start job and returns without waiting for dependencies.
# The service can wait for USB independently of the stock autorun runner.
systemd-run --unit="$UNIT" --collect --no-block \
  --property=After=ac50.service --property=TimeoutStopSec=5s \
  /bin/sh "$RAM/worker.sh" > "$RAM/setup.log" 2>&1
