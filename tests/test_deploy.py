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


if __name__ == '__main__':
    unittest.main()
