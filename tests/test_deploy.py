import argparse
import concurrent.futures
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('deploy', Path(__file__).resolve().parents[1] / 'scripts/deploy.py')
deploy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deploy)


class DeployTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.args = argparse.Namespace(non_interactive=True, wait_timeout=1)

    def target(self, name):
        return deploy.Target(name, self.args, 'commit', '1.2.1', 6, self.root, self.root / 'cache')

    def test_blocked_phone_does_not_prevent_other_targets(self):
        phone, desktop = self.target('ios'), self.target('windows')
        def blocked():
            raise deploy.Skipped('iPhone bloqueado')
        phone.ios = blocked
        desktop.windows = lambda: desktop.result.update(verification='ok')
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda target: target.execute(), [phone, desktop]))
        self.assertEqual([row['status'] for row in results], ['skipped', 'verified'])
        self.assertEqual(json.loads((self.root / 'ios.json').read_text())['error'], 'iPhone bloqueado')

    def test_timeout_is_recorded_and_does_not_loop_forever(self):
        target = self.target('android')
        target.args.wait_timeout = 0
        def failure():
            raise deploy.DeploymentError('no autorizado')
        with self.assertRaises(deploy.Skipped):
            target.wait(failure, 'autorizar teléfono')

    def test_interactive_retry_can_be_skipped(self):
        target = self.target('ios')
        target.args.wait_timeout = 100
        def failure():
            raise deploy.DeploymentError('locked')
        with patch.object(deploy, 'retry_action', return_value='skip'):
            with self.assertRaises(deploy.Skipped):
                target.wait(failure, 'desbloquear')

    def test_artifact_cache_checks_commit_and_bytes(self):
        target = self.target('android')
        artifact = target.cache / 'app.apk'
        artifact.write_bytes(b'original')
        target.manifest(artifact)
        self.assertTrue(target.valid_cache(artifact))
        artifact.write_bytes(b'changed')
        self.assertFalse(target.valid_cache(artifact))
        artifact.write_bytes(b'original')
        target.head = 'other-commit'
        self.assertFalse(target.valid_cache(artifact))

    def test_failed_command_keeps_output_in_private_log(self):
        target = self.target('windows')
        with self.assertRaises(deploy.DeploymentError):
            target.run(['python3', '-c', 'print("failure details"); raise SystemExit(3)'])
        self.assertIn('failure details', target.log.read_text())

    def test_powershell_literals_escape_apostrophes(self):
        self.assertEqual(deploy.quote_ps("a'b"), "'a''b'")

    def android_target(self):
        target = self.target('android')
        target.args.config = str(self.root / 'settings.json')
        target.args.android = None
        target.args.android_serial = None
        return target

    def test_android_prompt_saves_verified_address_and_identity(self):
        target = self.android_target()
        target.args.non_interactive = False
        def command(args, **kwargs):
            if args[-1] == 'devices':
                return 'List of devices attached\n'
            if args[-1] == 'get-state':
                return 'device\n'
            if args[-1] == 'ro.serialno':
                return 'PHONE123\n'
            return ''
        target.run = command
        with patch.object(deploy.sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value='192.168.1.134:40321'):
            self.assertEqual(target.android_device(), '192.168.1.134:40321')
        settings = Path(target.args.config)
        self.assertEqual(json.loads(settings.read_text())['android'], {'address': '192.168.1.134:40321', 'serial': 'PHONE123'})
        self.assertEqual(settings.stat().st_mode & 0o777, 0o600)

    def test_android_saved_identity_rejects_other_phone(self):
        target = self.android_target()
        target.remember_android('192.168.1.1:12345', 'ORIGINAL')
        target.args.android = '192.168.1.2:23456'
        target.run = lambda args, **kwargs: 'device' if args[-1] == 'get-state' else 'OTHER'
        with self.assertRaisesRegex(deploy.DeploymentError, 'identidad'):
            target.android_device()
        self.assertEqual(json.loads(Path(target.args.config).read_text())['android']['serial'], 'ORIGINAL')

    def test_android_skip_propagates_without_second_prompt(self):
        target = self.android_target()
        target.args.non_interactive = False
        target.run = lambda args, **kwargs: 'List of devices attached\n' if args[-1] == 'devices' else ''
        with patch.object(deploy.sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value='s') as prompt:
            with self.assertRaises(deploy.Skipped):
                target.wait(target.android_device, 'Conectar Android')
        self.assertEqual(prompt.call_count, 1)

    def test_android_addresses_reject_invalid_ports_and_options(self):
        for value in ['192.168.1.134:40321', '[fe80::1]:40321']:
            self.assertTrue(deploy.valid_address(value))
        for value in ['--help', '192.168.1.1:0', '192.168.1.1:65536', 'a:123\nother']:
            self.assertFalse(deploy.valid_address(value))


if __name__ == '__main__':
    unittest.main()
