"""Offline shell integration tests: no real device/service is contacted."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mpc-cold-boot-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sd = self.root / 'SD card'
        self.sd.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.ram = self.root / 'ram'
        self.fib = self.root / 'fib_trie'
        self.fib.write_text('')
        mounts = self.root / 'mounts'
        mounts.write_text('tmpfs /run tmpfs rw 0 0\n')
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        QA_ROOT=str(self.root), QA_ACTIVE='0', QA_SYSTEMD_FAIL='0',
                        QA_WORKER='absent', QA_CONFIG_FAIL='0')
        self.stub('id', 'printf "0\\n"\n')
        self.stub('systemctl', '[ "$QA_ACTIVE" = 1 ]\n')
        self.stub('systemd-run', 'printf "%s\\n" "$@" > "$QA_ROOT/systemd-args"\n'
                               '[ "$QA_SYSTEMD_FAIL" = 0 ]\n')
        self.stub('sync', 'touch "$QA_ROOT/UNEXPECTED_SYNC"\nexit 1\n')
        self.python_stub('sleep', """
p = Path(os.environ['QA_ROOT'])
c = p / 'sleep-count'
n = int(c.read_text()) + 1 if c.exists() else 1
c.write_text(str(n))
if os.environ['QA_WORKER'] == 'delayed' and n == 2:
    (p / 'fib_trie').write_text('192.168.155.1\\n')
""")
        self.python_stub('sshd', """
p = Path(os.environ['QA_ROOT'])
if '-t' in sys.argv:
    sys.exit(int(os.environ['QA_CONFIG_FAIL']))
assert '192.168.155.1' in (p / 'fib_trie').read_text()
(p / 'sshd-args').write_text(' '.join(sys.argv[1:]))
""")
        self.stub('readlink', 'printf "%s\\n" "$QA_ROOT/bin/sshd"\n')
        for name in ('authorized_keys', 'ssh_host_ed25519_key'):
            (self.sd / name).write_text('test fixture only\n')
        code = (ROOT / 'autorun/autorun.sh').read_text()
        replacements = {
            '/run/mpc-sample-ssh': str(self.ram),
            '/run/sshd': str(self.root / 'sshd-runtime'),
            '/usr/sbin/sshd': str(self.bin / 'sshd'),
            '/proc/mounts': str(mounts),
            '/proc/net/fib_trie': str(self.fib),
        }
        for old, new in replacements.items():
            code = code.replace(old, new)
        self.launcher = self.sd / 'autorun.sh'
        self.launcher.write_text(code)

    def stub(self, name, code):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + code)
        path.chmod(0o700)

    def python_stub(self, name, code):
        path = self.bin / name
        path.write_text('#!' + sys.executable + '\n'
                        'import os, sys\nfrom pathlib import Path\n' + code)
        path.chmod(0o700)

    def launch(self):
        return subprocess.run(['sh', str(self.launcher)], env=self.env,
                              capture_output=True, text=True, timeout=3)

    def worker(self):
        return subprocess.run(['sh', str(self.ram / 'worker.sh')], env=self.env,
                              capture_output=True, text=True, timeout=5)

    def test_handoff_never_waits_for_usb_or_writes_sd_logs(self):
        before = {p.name for p in self.sd.iterdir()}
        self.assertEqual(self.launch().returncode, 0)
        args = (self.root / 'systemd-args').read_text()
        self.assertIn('--no-block', args)
        self.assertIn('--property=After=ac50.service', args)
        self.assertEqual(before, {p.name for p in self.sd.iterdir()})
        self.assertFalse((self.root / 'sleep-count').exists())
        self.assertFalse((self.root / 'UNEXPECTED_SYNC').exists())
        self.assertFalse((self.root / 'sshd-args').exists())

    def test_existing_service_does_not_replace_credentials(self):
        self.ram.mkdir()
        key = self.ram / 'authorized_keys'
        key.write_text('active credentials\n')
        self.env['QA_ACTIVE'] = '1'
        self.assertEqual(self.launch().returncode, 0)
        self.assertEqual(key.read_text(), 'active credentials\n')
        self.assertFalse((self.root / 'systemd-args').exists())

    def test_existing_legacy_sshd_does_not_get_replaced(self):
        self.ram.mkdir()
        (self.ram / 'sshd.pid').write_text(str(os.getpid()))
        self.assertEqual(self.launch().returncode, 0)
        self.assertFalse((self.root / 'systemd-args').exists())

    def test_missing_key_aborts_before_start(self):
        (self.sd / 'authorized_keys').unlink()
        self.assertNotEqual(self.launch().returncode, 0)
        self.assertFalse((self.root / 'systemd-args').exists())

    def test_systemd_failure_is_reported(self):
        self.env['QA_SYSTEMD_FAIL'] = '1'
        self.assertNotEqual(self.launch().returncode, 0)

    def test_worker_waits_independently_then_starts_foreground_sshd(self):
        self.assertEqual(self.launch().returncode, 0)
        self.env['QA_WORKER'] = 'delayed'
        self.assertEqual(self.worker().returncode, 0)
        self.assertIn('waited_seconds=2', (self.ram / 'worker.log').read_text())
        self.assertIn('-D -e -f', (self.root / 'sshd-args').read_text())

    def test_worker_timeout_never_starts_sshd(self):
        self.assertEqual(self.launch().returncode, 0)
        self.assertNotEqual(self.worker().returncode, 0)
        self.assertEqual((self.root / 'sleep-count').read_text(), '45')
        self.assertFalse((self.root / 'sshd-args').exists())

    def test_bad_sshd_config_never_starts_server(self):
        self.assertEqual(self.launch().returncode, 0)
        self.fib.write_text('192.168.155.1\n')
        self.env['QA_CONFIG_FAIL'] = '1'
        self.assertNotEqual(self.worker().returncode, 0)
        self.assertFalse((self.root / 'sshd-args').exists())

    def test_cold_boot_manifest_and_checksum(self):
        folder = ROOT / 'autorun'
        manifest = (folder / 'autorun.json').read_bytes()
        doc = json.loads(manifest)['value0']
        self.assertIs(doc['scripts'][0]['askQuestion'], False)
        self.assertEqual(doc['files'], [])
        expected = hashlib.sha256(manifest + (folder / 'autorun.sh').read_bytes()
                                  + b'f7bed1c9-7e90-4731-9194-c996666b4331').hexdigest()
        self.assertEqual((folder / 'autorun.check').read_bytes(), expected.encode())


if __name__ == '__main__':
    unittest.main()
