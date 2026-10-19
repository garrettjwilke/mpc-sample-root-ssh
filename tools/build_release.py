#!/usr/bin/env python3
"""Package a fixed allowlist only. Personal keys/logs are never packaged."""
import hashlib
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile
from check_autorun import verify

ROOT = Path(__file__).resolve().parents[1]
FILES = (
    'README.md', 'setup_unix.sh', 'setup_windows.ps1',
    'autorun/autorun.json', 'autorun/autorun.sh', 'autorun/autorun.check',
    'tools/check_autorun.py', 'tools/build_release.py', '.gitignore', '.gitattributes',
)


def main():
    verify(ROOT)
    private_markers = (b'-----BEGIN OPENSSH PRIVATE KEY-----', b'-----BEGIN RSA PRIVATE KEY-----')
    contents = {}
    for name in FILES:
        path = ROOT / name
        if path.is_symlink():
            raise ValueError('Refusing symlink: ' + name)
        data = path.read_bytes()
        if any(data.startswith(marker) or b'\n' + marker in data for marker in private_markers):
            raise ValueError('Private key detected: ' + name)
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
