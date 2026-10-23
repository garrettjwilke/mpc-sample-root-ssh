#!/bin/sh
# ==============================================================================
# mpc.sh — All-in-one macOS/Linux host wrapper for Akai MPC Sample (AC50/AZ07)
# ==============================================================================
# Edit the default variables below to match your setup, or override them via
# environment variables or command-line flags (--ip, --port, --key, --sd, etc.).
# ==============================================================================

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# --- User-Adjustable Configuration (Defaults) ---------------------------------
MPC_IP="${MPC_IP:-192.168.155.1}"
MPC_PORT="${MPC_PORT:-2222}"
MPC_USER="${MPC_USER:-root}"
MPC_KEY="${MPC_KEY:-$SCRIPT_DIR/keys/mpc_sample_ed25519}"
MPC_REMOTE_SD="${MPC_REMOTE_SD:-/media/MPC}"
MPC_LOCAL_SD="${MPC_LOCAL_SD:-/Volumes/MPC}"
MPC_ALPINE_MIRROR="${MPC_ALPINE_MIRROR:-http://dl-cdn.alpinelinux.org/alpine/v3.20/main/aarch64}"
MPC_CACHE_DIR="${MPC_CACHE_DIR:-$SCRIPT_DIR/.mpc-cache}"

# Internal paths
AUTORUN_DIR="$SCRIPT_DIR/autorun"
AUTORUN_SALT="f7bed1c9-7e90-4731-9194-c996666b4331"

# --- Usage / Help -------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <command> [args...]

Host wrapper for setting up, connecting to, transferring files, and installing
ARM64 utilities on the Akai MPC Sample over USB networking.

Configurable Options (or set via top-of-script / environment variables):
  -i, --key PATH         SSH private key (default: $MPC_KEY)
  -H, --ip ADDRESS       MPC USB IP address (default: $MPC_IP)
  -p, --port PORT        MPC SSH port (default: $MPC_PORT)
  -u, --user USER        MPC SSH user (default: $MPC_USER)
  -d, --sd PATH          Local SD card mount path on Mac/Linux (default: $MPC_LOCAL_SD)
  -r, --remote-sd PATH   Remote SD card mount path on MPC (default: $MPC_REMOTE_SD)
  -h, --help             Show this help message

Setup & Boot Commands:
  setup [--sd PATH]      1) Verify/sign autorun, generate SSH keys if missing,
                            build on-boot.sh + ARM64 toolkit, and optionally copy
                            to a locally mounted SD card (or deploy via SSH).
  sign                   Recalculate autorun/autorun.check after editing autorun.sh
  toolkit [--deploy]     Download & build the exFAT-safe ARM64 Linux toolkit
                         (file, vim, nano, rsync, htop, strace, lsof, tree, jq,
                         xxd, curl, bash, gawk, gfind, less, busybox-full)
                         and optionally deploy it straight to the MPC over SSH.
  unlock                 Remount $MPC_REMOTE_SD with 'exec' and activate PATH on MPC

Connection & File Transfer Commands:
  ssh [cmd...]           Open an interactive root shell (or run a command with
                         $MPC_REMOTE_SD/bin & $MPC_REMOTE_SD/scripts in PATH)
  status                 Show MPC system info, SD mount flags, and installed tools
  push <local> [remote]  Upload file/folder to MPC (relative paths go to $MPC_REMOTE_SD/)
  pull <remote> [local]  Download file/folder from MPC (relative paths from $MPC_REMOTE_SD/)
  sync <src> <dst>       Fast rsync between Mac and MPC (prefix MPC side with 'mpc:')

RAM Investigation Commands (runs mpc-memdump on live MPC):
  ram maps [filter]              List live memory regions of 'MPC Sample' (filters:
                                 all, app, heap, rw, stack, anon, or substring)
  ram search <pattern> [filter]  Search live RAM for ASCII string or hex (0x...)
  ram dump [filter] [out_dir]    Dump live RAM regions from MPC directly to your Mac
                                 (default filter: heap; default dir: ./dumps/<timestamp>)
  ram range <addr_hex> <size>    Dump exact virtual memory range (e.g. 0xaaaaaaaa0000 4096)

Examples:
  ./mpc.sh setup                        # Prepare keys, boot scripts & ARM64 toolkit
  ./mpc.sh ssh                          # Log into the MPC
  ./mpc.sh ram maps app                 # Show 'MPC Sample' code/data/heap regions
  ./mpc.sh ram search "1.3.0.12" app    # Search live app+heap RAM for a string or 0xHEX
  ./mpc.sh ram dump heap                # Dump live [heap] (~115 MB) straight to your Mac
  ./mpc.sh ram range 0xaaaaaaaa0000 256 | xxd
EOF
}

# --- Parse Global Flags -------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -i|--key)       MPC_KEY="$2"; shift 2 ;;
    -H|--ip)        MPC_IP="$2"; shift 2 ;;
    -p|--port)      MPC_PORT="$2"; shift 2 ;;
    -u|--user)      MPC_USER="$2"; shift 2 ;;
    -d|--sd)        MPC_LOCAL_SD="$2"; shift 2 ;;
    -r|--remote-sd) MPC_REMOTE_SD="$2"; shift 2 ;;
    -h|--help|help) usage; exit 0 ;;
    --)             shift; break ;;
    -*)             echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)              break ;;
  esac
done

if [ $# -eq 0 ]; then
  usage
  exit 0
fi

CMD="$1"
shift

# --- SSH Helper Functions -----------------------------------------------------
ssh_key_args() {
  if [ -n "$MPC_KEY" ] && [ -f "$MPC_KEY" ]; then
    chmod 600 "$MPC_KEY" 2>/dev/null || true
    printf '%s' "-i $MPC_KEY"
  fi
}

ssh_base_cmd() {
  if [ -n "$MPC_KEY" ] && [ -f "$MPC_KEY" ]; then
    chmod 600 "$MPC_KEY" 2>/dev/null || true
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=5 \
        -p "$MPC_PORT" \
        -i "$MPC_KEY" \
        "$MPC_USER@$MPC_IP" "$@"
  else
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=5 \
        -p "$MPC_PORT" \
        "$MPC_USER@$MPC_IP" "$@"
  fi
}

require_client_key() {
  if [ -n "$MPC_KEY" ] && [ -f "$MPC_KEY" ]; then
    chmod 600 "$MPC_KEY" 2>/dev/null || true
  fi
}

# --- Command: sign (Compute autorun.check) ------------------------------------
cmd_sign() {
  if [ ! -f "$AUTORUN_DIR/autorun.json" ] || [ ! -f "$AUTORUN_DIR/autorun.sh" ]; then
    echo "ERROR: $AUTORUN_DIR/autorun.json or autorun.sh not found" >&2
    exit 1
  fi
  if command -v shasum >/dev/null 2>&1; then
    DIGEST=$({ cat "$AUTORUN_DIR/autorun.json" "$AUTORUN_DIR/autorun.sh"; printf '%s' "$AUTORUN_SALT"; } | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    DIGEST=$({ cat "$AUTORUN_DIR/autorun.json" "$AUTORUN_DIR/autorun.sh"; printf '%s' "$AUTORUN_SALT"; } | sha256sum | awk '{print $1}')
  else
    echo "ERROR: shasum or sha256sum is required" >&2
    exit 1
  fi
  printf '%s' "$DIGEST" > "$AUTORUN_DIR/autorun.check"
  echo "Signed autorun/autorun.check: $DIGEST"
}

# --- Helper: Generate default scripts/on-boot.sh ------------------------------
generate_on_boot_script() {
  OUT_SCRIPTS_DIR="$1"
  mkdir -p "$OUT_SCRIPTS_DIR"
  cat > "$OUT_SCRIPTS_DIR/on-boot.sh" <<EOF
#!/bin/sh
# Custom boot hook executed automatically by autorun worker after SD remount,exec.
# Edit this file freely -- no autorun.check recalculation is required!

mkdir -p "$MPC_REMOTE_SD/bin" "$MPC_REMOTE_SD/scripts"

# Bind-mount a custom /etc/profile in RAM so interactive SSH sessions
# automatically include $MPC_REMOTE_SD/bin and $MPC_REMOTE_SD/scripts in PATH.
if ! grep -q '$MPC_REMOTE_SD/bin' /etc/profile 2>/dev/null; then
  cp /etc/profile /run/mpc-profile
  cat >> /run/mpc-profile <<'PROFILE_EOF'

# Added by $MPC_REMOTE_SD/scripts/on-boot.sh
export PATH="$MPC_REMOTE_SD/bin:$MPC_REMOTE_SD/scripts:\$PATH"
PROFILE_EOF
  mount --bind /run/mpc-profile /etc/profile 2>/dev/null || true
fi
EOF
  chmod +x "$OUT_SCRIPTS_DIR/on-boot.sh"
}

# --- Command: toolkit (Download & Build ARM64 Utilities) ----------------------
cmd_toolkit() {
  DEPLOY_SSH=0
  COPY_SD=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --deploy) DEPLOY_SSH=1; shift ;;
      --sd)     COPY_SD="$2"; shift 2 ;;
      *)        echo "ERROR: Unknown toolkit flag: $1" >&2; exit 1 ;;
    esac
  done

  echo "==> Building ARM64 (aarch64) toolkit in $MPC_CACHE_DIR/sdcard ..."
  python3 - "$MPC_ALPINE_MIRROR" "$MPC_CACHE_DIR" "$MPC_REMOTE_SD" <<'PYEOF'
import io, os, shutil, sys, tarfile, urllib.request
from pathlib import Path

mirror = sys.argv[1].rstrip("/") + "/"
cache_dir = Path(sys.argv[2])
remote_sd = sys.argv[3].rstrip("/")

apk_cache = cache_dir / "apks"
stage = cache_dir / "stage"
out = cache_dir / "sdcard"

apk_cache.mkdir(parents=True, exist_ok=True)
if stage.exists():
    shutil.rmtree(stage)
stage.mkdir(parents=True)

for sub in ("bin", "toolkit"):
    if (out / sub).exists():
        shutil.rmtree(out / sub)

print(f"Fetching package index from {mirror}APKINDEX.tar.gz ...")
idx_bytes = urllib.request.urlopen(mirror + "APKINDEX.tar.gz", timeout=20).read()
with tarfile.open(fileobj=io.BytesIO(idx_bytes), mode="r:gz") as tf:
    idx_text = tf.extractfile("APKINDEX").read().decode("utf-8", errors="ignore")

pkgs = {}
for block in idx_text.split("\n\n"):
    info = {}
    for line in block.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            info[k] = v
    if "P" in info:
        pkgs[info["P"]] = info
        for p in info.get("p", "").split():
            name = p.split("=")[0]
            if name not in pkgs:
                pkgs[name] = info

wanted = [
    "musl", "busybox-static", "file", "rsync", "vim", "nano",
    "strace", "htop", "tree", "lsof", "bash", "jq", "xxd",
    "ncurses-terminfo-base", "curl", "less", "grep", "sed", "gawk", "findutils"
]
skip_pkgs = {"yash", "yash-binsh", "busybox", "busybox-binsh"}

resolved = {}
queue = list(wanted)
while queue:
    name = queue.pop(0)
    if name in skip_pkgs or name in resolved or name not in pkgs:
        continue
    info = pkgs[name]
    real_name = info["P"]
    if real_name in skip_pkgs or real_name in resolved:
        continue
    resolved[real_name] = f"{real_name}-{info['V']}.apk"
    for dep in info.get("D", "").split():
        if dep.startswith("!"):
            continue
        dep_name = dep.split("=")[0].split("<")[0].split(">")[0].split("~")[0]
        if dep_name not in resolved and dep_name not in skip_pkgs:
            queue.append(dep_name)

for name, apk in sorted(resolved.items()):
    apk_path = apk_cache / apk
    if not apk_path.exists():
        print(f"  Downloading {apk} ...")
        apk_path.write_bytes(urllib.request.urlopen(mirror + apk, timeout=30).read())
    os.system(f"tar -xzf '{apk_path}' -C '{stage}' 2>/dev/null")

bin_dir = out / "bin"
real_bin = out / "toolkit" / "bin"
real_lib = out / "toolkit" / "lib"
real_share = out / "toolkit" / "share"
for d in (bin_dir, real_bin, real_lib, real_share):
    d.mkdir(parents=True, exist_ok=True)

# 1. Copy needed SONAME shared libraries (dereferencing symlinks for exFAT)
for lib_src in (stage / "lib", stage / "usr" / "lib"):
    if not lib_src.exists():
        continue
    for item in lib_src.iterdir():
        if item.is_dir():
            continue
        if item.is_symlink() or item.name.count(".") == 2 or item.name.startswith("ld-musl"):
            target = item.resolve()
            if target.exists() and target.is_file():
                shutil.copy2(target, real_lib / item.name)

# 2. Copy runtime data (magic.mgc, terminfo, trimmed vim runtime)
magic_src = stage / "usr" / "share" / "misc" / "magic.mgc"
if magic_src.exists():
    (real_share / "misc").mkdir(parents=True, exist_ok=True)
    shutil.copy2(magic_src, real_share / "misc" / "magic.mgc")

for t_src in (stage / "etc" / "terminfo", stage / "usr" / "share" / "terminfo"):
    if t_src.exists():
        shutil.copytree(t_src, real_share / "terminfo", symlinks=False)
        break

vim_src = stage / "usr" / "share" / "vim"
if vim_src.exists():
    shutil.copytree(vim_src, real_share / "vim", symlinks=False)
    for vim_ver in (real_share / "vim").iterdir():
        if vim_ver.is_dir():
            for sub in ("doc", "tutor", "spell", "lang"):
                if (vim_ver / sub).exists():
                    shutil.rmtree(vim_ver / sub)

# 3. Static busybox
bb_src = stage / "bin" / "busybox.static"
if bb_src.exists():
    shutil.copy2(bb_src, bin_dir / "busybox-full")
    (bin_dir / "busybox-full").chmod(0o755)

# 4. Create exFAT-safe launcher wrappers in bin/
tools = [
    ("usr/bin/file",   "file",   f'export MAGIC="{remote_sd}/toolkit/share/misc/magic.mgc"\n'),
    ("usr/bin/rsync",  "rsync",  ""),
    ("usr/bin/vim",    "vim",    f'export VIMRUNTIME="{remote_sd}/toolkit/share/vim/vim91"\nexport TERMINFO="{remote_sd}/toolkit/share/terminfo"\n'),
    ("usr/bin/nano",   "nano",   f'export TERMINFO="{remote_sd}/toolkit/share/terminfo"\n'),
    ("usr/bin/htop",   "htop",   f'export TERMINFO="{remote_sd}/toolkit/share/terminfo"\n'),
    ("usr/bin/strace", "strace", ""),
    ("usr/bin/lsof",   "lsof",   ""),
    ("usr/bin/tree",   "tree",   ""),
    ("usr/bin/jq",     "jq",     ""),
    ("usr/bin/xxd",    "xxd",    ""),
    ("usr/bin/curl",   "curl",   ""),
    ("usr/bin/less",   "less",   f'export TERMINFO="{remote_sd}/toolkit/share/terminfo"\n'),
    ("usr/bin/find",   "gfind",  ""),
    ("usr/bin/gawk",   "gawk",   ""),
    ("bin/bash",       "bash",   f'export TERMINFO="{remote_sd}/toolkit/share/terminfo"\n'),
]

for rel_path, name, extra_env in tools:
    src = (stage / rel_path).resolve()
    shutil.copy2(src, real_bin / name)
    wrapper = bin_dir / name
    wrapper.write_text(
        "#!/bin/sh\n"
        f"{extra_env}"
        f'exec "{remote_sd}/toolkit/lib/ld-musl-aarch64.so.1" --library-path "{remote_sd}/toolkit/lib" "{remote_sd}/toolkit/bin/{name}" "$@"\n'
    )
    wrapper.chmod(0o755)

shutil.rmtree(stage)
print("Toolkit ready at:", out)
PYEOF

  generate_on_boot_script "$MPC_CACHE_DIR/sdcard/scripts"
  if [ -f "$SCRIPT_DIR/tools/mpc-memdump/mpc-memdump" ]; then
    cp "$SCRIPT_DIR/tools/mpc-memdump/mpc-memdump" "$MPC_CACHE_DIR/sdcard/bin/mpc-memdump"
    chmod +x "$MPC_CACHE_DIR/sdcard/bin/mpc-memdump"
  fi

  if [ -n "$COPY_SD" ]; then
    if [ ! -d "$COPY_SD" ]; then
      echo "ERROR: Local SD card path not found: $COPY_SD" >&2
      exit 1
    fi
    echo "==> Copying bin/, toolkit/, and scripts/on-boot.sh to $COPY_SD ..."
    cp -R "$MPC_CACHE_DIR/sdcard/bin" "$MPC_CACHE_DIR/sdcard/toolkit" "$MPC_CACHE_DIR/sdcard/scripts" "$COPY_SD/"
    echo "Copied toolkit to $COPY_SD"
  fi

  if [ "$DEPLOY_SSH" = 1 ]; then
    require_client_key
    echo "==> Deploying toolkit & scripts/on-boot.sh over SSH to $MPC_USER@$MPC_IP:$MPC_REMOTE_SD ..."
    COPYFILE_DISABLE=1 tar -czf - -C "$MPC_CACHE_DIR/sdcard" bin toolkit scripts | \
      ssh_base_cmd "mount -o remount,exec '$MPC_REMOTE_SD' 2>/dev/null || true; tar -xzf - -C '$MPC_REMOTE_SD' && '$MPC_REMOTE_SD/scripts/on-boot.sh'"
    echo "==> Deployed and activated on MPC!"
  fi
}

# --- Command: setup (Complete End-to-End Setup) -------------------------------
cmd_setup() {
  TARGET_SD="$MPC_LOCAL_SD"
  DEPLOY_SSH=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --sd)     TARGET_SD="$2"; shift 2 ;;
      --no-sd)  TARGET_SD=""; shift ;;
      --deploy) DEPLOY_SSH=1; shift ;;
      *)        echo "ERROR: Unknown setup flag: $1" >&2; exit 1 ;;
    esac
  done

  echo "==> Step 1: Verifying and signing autorun/autorun.check ..."
  cmd_sign

  echo "==> Step 2: Building ARM64 toolkit, boot hooks, and Web UI ..."
  cmd_toolkit

  STAGE_SD="$MPC_CACHE_DIR/sdcard"
  mkdir -p "$STAGE_SD/bin" "$STAGE_SD/scripts" "$STAGE_SD/webui"

  if [ -f "$SCRIPT_DIR/tools/mpc-webui/mpc-webui" ]; then
    cp "$SCRIPT_DIR/tools/mpc-webui/mpc-webui" "$STAGE_SD/bin/mpc-webui"
    chmod +x "$STAGE_SD/bin/mpc-webui"
  fi
  if [ -f "$SCRIPT_DIR/tools/mpc-memdump/mpc-memdump" ]; then
    cp "$SCRIPT_DIR/tools/mpc-memdump/mpc-memdump" "$STAGE_SD/bin/mpc-memdump"
    chmod +x "$STAGE_SD/bin/mpc-memdump"
  fi
  if [ -f "$SCRIPT_DIR/webui/index.html" ]; then
    cp "$SCRIPT_DIR/webui/index.html" "$STAGE_SD/webui/index.html"
  fi

  if [ "$DEPLOY_SSH" = 1 ]; then
    echo "==> Step 3: Pushing autorun/, bin/, toolkit/, scripts/, and webui/ to live MPC over SSH ..."
    COPYFILE_DISABLE=1 tar -czf - -C "$SCRIPT_DIR" autorun | \
      ssh_base_cmd "mount -o remount,exec '$MPC_REMOTE_SD' 2>/dev/null || true; tar -xzf - -C '$MPC_REMOTE_SD'"
    COPYFILE_DISABLE=1 tar -czf - -C "$STAGE_SD" bin toolkit scripts webui | \
      ssh_base_cmd "tar -xzf - -C '$MPC_REMOTE_SD' && chmod +x '$MPC_REMOTE_SD/bin/'* '$MPC_REMOTE_SD/scripts/'* 2>/dev/null || true"
    ssh_base_cmd "
      killall mpc-webui 2>/dev/null || true
      '$MPC_REMOTE_SD/bin/mpc-webui' 8080 0.0.0.0 >/run/mpc-webui.log 2>&1 &
    "
    echo "==> Deployed! Open http://$MPC_IP:8080/ in your browser!"
  elif [ -n "$TARGET_SD" ] && [ -d "$TARGET_SD" ]; then
    echo "==> Step 3: Installing autorun/, bin/, toolkit/, scripts/, and webui/ to $TARGET_SD ..."
    cp -R "$AUTORUN_DIR" "$TARGET_SD/"
    cp -R "$STAGE_SD/bin" "$STAGE_SD/toolkit" "$STAGE_SD/scripts" "$STAGE_SD/webui" "$TARGET_SD/"
    dot_clean -m "$TARGET_SD" 2>/dev/null || true
    echo "==> SD card at $TARGET_SD is ready! After booting MPC, open http://$MPC_IP:8080/ or run ./$(basename "$0") ssh"
  else
    echo ""
    echo "==> Setup staged locally in $STAGE_SD!"
    echo "    - Mount your SD card at $MPC_LOCAL_SD and re-run: ./$(basename "$0") setup"
    echo "    - Or deploy directly to a booted MPC over USB:   ./$(basename "$0") setup --deploy"
    echo "    - Then open http://$MPC_IP:8080/ in your browser or run ./$(basename "$0") ssh"
  fi
}

# --- Command: ssh (Connect or Run Command with Toolkit PATH) ------------------
cmd_ssh() {
  require_client_key
  if [ $# -eq 0 ]; then
    if [ -n "$MPC_KEY" ] && [ -f "$MPC_KEY" ]; then
      exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
               -p "$MPC_PORT" -i "$MPC_KEY" "$MPC_USER@$MPC_IP"
    else
      exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
               -p "$MPC_PORT" "$MPC_USER@$MPC_IP"
    fi
  else
    REMOTE_CMD="$*"
    ssh_base_cmd "export PATH='$MPC_REMOTE_SD/bin:$MPC_REMOTE_SD/scripts:'\$PATH; $REMOTE_CMD"
  fi
}

# --- Command: unlock (Remount SD exec + run on-boot.sh) -----------------------
cmd_unlock() {
  require_client_key
  ssh_base_cmd "mount -o remount,exec '$MPC_REMOTE_SD' && ( [ -x '$MPC_REMOTE_SD/scripts/on-boot.sh' ] && '$MPC_REMOTE_SD/scripts/on-boot.sh' || true ) && mount | grep '$MPC_REMOTE_SD'"
}

# --- Command: status (Check MPC health, SD mount, and toolkit) ----------------
cmd_status() {
  require_client_key
  ssh_base_cmd "export PATH='$MPC_REMOTE_SD/bin:$MPC_REMOTE_SD/scripts:'\$PATH
    echo '=== System ==='
    uname -a
    echo '=== SD Card Mount ==='
    mount | grep '$MPC_REMOTE_SD' || echo 'SD card not mounted'
    df -h '$MPC_REMOTE_SD' 2>/dev/null || true
    echo '=== Available Tools in $MPC_REMOTE_SD/bin ==='
    ls '$MPC_REMOTE_SD/bin' 2>/dev/null | tr '\n' ' '; echo ''
    echo '=== Available Scripts in $MPC_REMOTE_SD/scripts ==='
    ls '$MPC_REMOTE_SD/scripts' 2>/dev/null | tr '\n' ' '; echo ''
  "
}

# ---Helper: Normalize Remote Path (relative -> $MPC_REMOTE_SD/<path>) ---------
resolve_remote_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$MPC_REMOTE_SD" "$1" ;;
  esac
}

# --- Command: push (Upload file or directory to MPC) --------------------------
cmd_push() {
  require_client_key
  if [ $# -lt 1 ]; then
    echo "Usage: $(basename "$0") push <local_path> [remote_path]" >&2
    exit 1
  fi
  LOCAL_SRC="$1"
  RAW_DST="${2:-$(basename -- "$LOCAL_SRC")}"
  REMOTE_DST=$(resolve_remote_path "$RAW_DST")

  SSH_RSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p $MPC_PORT $(ssh_key_args)"
  if ssh_base_cmd "test -x '$MPC_REMOTE_SD/bin/rsync'" 2>/dev/null && command -v rsync >/dev/null 2>&1; then
    rsync -rtvz --no-owner --no-group --no-perms --rsync-path="$MPC_REMOTE_SD/bin/rsync" \
      -e "$SSH_RSH" \
      "$LOCAL_SRC" "$MPC_USER@$MPC_IP:$REMOTE_DST"
  else
    # shellcheck disable=SC2046
    scp -O -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$MPC_PORT" $(ssh_key_args) "$LOCAL_SRC" "$MPC_USER@$MPC_IP:$REMOTE_DST"
  fi
}

# --- Command: pull (Download file or directory from MPC) ----------------------
cmd_pull() {
  require_client_key
  if [ $# -lt 1 ]; then
    echo "Usage: $(basename "$0") pull <remote_path> [local_path]" >&2
    exit 1
  fi
  REMOTE_SRC=$(resolve_remote_path "$1")
  LOCAL_DST="${2:-.}"

  SSH_RSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p $MPC_PORT $(ssh_key_args)"
  if ssh_base_cmd "test -x '$MPC_REMOTE_SD/bin/rsync'" 2>/dev/null && command -v rsync >/dev/null 2>&1; then
    rsync -rtvz --no-owner --no-group --no-perms --rsync-path="$MPC_REMOTE_SD/bin/rsync" \
      -e "$SSH_RSH" \
      "$MPC_USER@$MPC_IP:$REMOTE_SRC" "$LOCAL_DST"
  else
    # shellcheck disable=SC2046
    scp -O -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$MPC_PORT" $(ssh_key_args) "$MPC_USER@$MPC_IP:$REMOTE_SRC" "$LOCAL_DST"
  fi
}

# --- Command: sync (Direct rsync wrapper with 'mpc:' prefix support) ----------
cmd_sync() {
  require_client_key
  if [ $# -lt 2 ]; then
    echo "Usage: $(basename "$0") sync <src> <dst>   (use 'mpc:path' for the MPC side)" >&2
    exit 1
  fi
  ARGS=""
  for arg in "$@"; do
    case "$arg" in
      mpc:/*) ARGS="$ARGS $MPC_USER@$MPC_IP:${arg#mpc:}" ;;
      mpc:*)  ARGS="$ARGS $MPC_USER@$MPC_IP:$MPC_REMOTE_SD/${arg#mpc:}" ;;
      *)      ARGS="$ARGS $arg" ;;
    esac
  done
  SSH_RSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p $MPC_PORT $(ssh_key_args)"
  # shellcheck disable=SC2086
  rsync -rtvz --no-owner --no-group --no-perms --rsync-path="$MPC_REMOTE_SD/bin/rsync" \
    -e "$SSH_RSH" \
    $ARGS
}

# --- Command: ram (Live RAM inspection, search, and streaming dump to Mac) ----
ensure_remote_memdump() {
  if ! ssh_base_cmd "test -x '$MPC_REMOTE_SD/bin/mpc-memdump'" 2>/dev/null; then
    if [ -f "$SCRIPT_DIR/tools/mpc-memdump/mpc-memdump" ]; then
      echo "==> Installing mpc-memdump to $MPC_REMOTE_SD/bin/mpc-memdump ..." >&2
      cmd_push "$SCRIPT_DIR/tools/mpc-memdump/mpc-memdump" "bin/mpc-memdump" >/dev/null
      ssh_base_cmd "chmod +x '$MPC_REMOTE_SD/bin/mpc-memdump'"
    else
      echo "ERROR: mpc-memdump binary not found at $SCRIPT_DIR/tools/mpc-memdump/mpc-memdump" >&2
      exit 1
    fi
  fi
}

cmd_ram() {
  require_client_key
  ensure_remote_memdump
  SUB="${1:-maps}"
  if [ $# -gt 0 ]; then
    shift
  fi

  case "$SUB" in
    maps)
      FILTER="${1:-all}"
      ssh_base_cmd "'$MPC_REMOTE_SD/bin/mpc-memdump' maps '$FILTER'"
      ;;
    search)
      if [ $# -lt 1 ]; then
        echo "Usage: $(basename "$0") ram search <ascii_or_0xHEX> [filter]" >&2
        exit 1
      fi
      PATTERN="$1"
      FILTER="${2:-app}"
      ssh_base_cmd "'$MPC_REMOTE_SD/bin/mpc-memdump' search -f '$FILTER' '$PATTERN'"
      ;;
    range)
      if [ $# -lt 2 ]; then
        echo "Usage: $(basename "$0") ram range <start_hex> <size_bytes>" >&2
        exit 1
      fi
      START_HEX="$1"
      SIZE_BYTES="$2"
      ssh_base_cmd "'$MPC_REMOTE_SD/bin/mpc-memdump' range '$START_HEX' '$SIZE_BYTES'"
      ;;
    dump)
      FILTER="${1:-heap}"
      STAMP=$(date +"%Y%m%d_%H%M%S")
      LOCAL_OUT="${2:-$SCRIPT_DIR/dumps/ram_${FILTER}_${STAMP}}"
      mkdir -p "$LOCAL_OUT"
      REMOTE_STAGE="$MPC_REMOTE_SD/.ram_dump_tmp_$$"
      echo "==> Dumping live MPC RAM (filter='$FILTER') and streaming to $LOCAL_OUT ..."
      ssh_base_cmd "mkdir -p '$REMOTE_STAGE' && '$MPC_REMOTE_SD/bin/mpc-memdump' dump -f '$FILTER' -o '$REMOTE_STAGE' && tar -cf - -C '$REMOTE_STAGE' . && rm -rf '$REMOTE_STAGE'" | \
        tar -xf - -C "$LOCAL_OUT"
      echo "==> Dump complete! Files saved in: $LOCAL_OUT"
      ls -lh "$LOCAL_OUT"
      ;;
    *)
      echo "ERROR: Unknown ram subcommand '$SUB' (expected: maps, search, dump, range)" >&2
      exit 1
      ;;
  esac
}

# --- Dispatch Command ---------------------------------------------------------
case "$CMD" in
  setup)   cmd_setup "$@" ;;
  sign)    cmd_sign "$@" ;;
  toolkit) cmd_toolkit "$@" ;;
  unlock)  cmd_unlock "$@" ;;
  ssh)     cmd_ssh "$@" ;;
  status)  cmd_status "$@" ;;
  push)    cmd_push "$@" ;;
  pull)    cmd_pull "$@" ;;
  sync)    cmd_sync "$@" ;;
  ram)     cmd_ram "$@" ;;
  *)
    echo "ERROR: Unknown command '$CMD'" >&2
    usage >&2
    exit 1
    ;;
esac
