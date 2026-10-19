#!/usr/bin/env python3
"""Verify the exact-byte autorun checksum without preparing keys or contacting MPC."""
import hashlib
import json
from pathlib import Path


def verify(root):
    folder = root / 'autorun'
    raw = (folder / 'autorun.json').read_bytes()
    payload = json.loads(raw)['value0']
    if len(payload['scripts']) != 1 or payload['scripts'][0]['path'] != 'autorun.sh':
        raise ValueError('Unexpected script list')
    if payload['scripts'][0]['askQuestion'] is not False or payload['files'] != []:
        raise ValueError('Unexpected prompt/files contract')
    digest = hashlib.sha256(raw + (folder / 'autorun.sh').read_bytes()
                            + b'f7bed1c9-7e90-4731-9194-c996666b4331').hexdigest()
    if (folder / 'autorun.check').read_bytes() != digest.encode('ascii'):
        raise ValueError('autorun.check mismatch (including line endings)')
    return digest


if __name__ == '__main__':
    print('PASS', verify(Path(__file__).resolve().parents[1]))
