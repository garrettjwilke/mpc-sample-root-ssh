#!/usr/bin/env python3
"""Package a fixed allowlist only. Personal keys/logs are never packaged."""
import hashlib
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile
from check_autorun import verify

ROOT = Path(__file__).resolve().parents[1]
FILES = (
    'README.md', 'mpc.sh', 'setup_unix.sh', 'setup_windows.ps1',
    'keys/mpc_sample_ed25519', 'keys/mpc_sample_ed25519.pub',
    'autorun/autorun.json', 'autorun/autorun.sh', 'autorun/autorun.check',
    'autorun/authorized_keys', 'autorun/ssh_host_ed25519_key', 'autorun/ssh_host_ed25519_key.pub',
    'webui/index.html',
    'tools/check_autorun.py', 'tools/build_release.py',
    'tools/mpc-memdump/mpc-memdump.c', 'tools/mpc-memdump/mpc-memdump',
    'tools/mpc-webui/mpc-webui.c', 'tools/mpc-webui/mpc-webui',
    '.gitignore', '.gitattributes',
)


def main():
    verify(ROOT)
    contents = {}
    for name in FILES:
        path = ROOT / name
        if path.is_symlink():
            raise ValueError('Refusing symlink: ' + name)
        data = path.read_bytes()
        contents[name] = data
    sums = ''.join(hashlib.sha256(data).hexdigest() + '  ' + name + '\n'
                   for name, data in sorted(contents.items())).encode('ascii')
    out = ROOT / 'dist'
    out.mkdir(exist_ok=True)
    archive = out / 'mpc-sample-root-ssh-v1.2.0.zip'
    with ZipFile(archive, 'w', ZIP_DEFLATED) as zipped:
        for name, data in contents.items():
            zipped.writestr('mpc-sample-root-ssh/' + name, data)
        zipped.writestr('mpc-sample-root-ssh/SHA256SUMS', sums)
    with ZipFile(archive) as zipped:
        if zipped.testzip() is not None:
            raise ValueError('ZIP verification failed')
    print(archive)
    print('SHA256', hashlib.sha256(archive.read_bytes()).hexdigest())


if __name__ == '__main__':
    main()
