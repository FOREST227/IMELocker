import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class ReleaseTests(unittest.TestCase):
    def run_release(self, mode, fail_upload=False):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            (root / 'build').mkdir()
            (root / 'docs/releases').mkdir(parents=True)
            (root / 'docs/releases/v0.0.3.md').write_text('Release notes\n')
            for arch in ('arm64', 'x86_64', 'universal'):
                (root / f'build/IMELocker-v0.0.3-{arch}.dmg').write_text('fixture')
            shutil.copytree(ROOT / 'scripts', root / 'scripts')
            gh = root / 'gh'
            gh.write_text('''#!/bin/bash
set -eu
echo "$*" >> "$RELEASE_TEST_LOG"
case "$2" in
 view)
   case "$RELEASE_TEST_MODE" in
     published) echo false;;
     draft) echo true;;
     missing) exit 1;;
   esac;;
 upload) [[ "$FAIL_UPLOAD" == 0 ]];;
esac
''')
            gh.chmod(0o755)
            log = root / 'calls.log'
            result = subprocess.run(['bash', 'scripts/publish_release.sh', 'v0.0.3'],
                                    cwd=root, capture_output=True, text=True,
                                    env=dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'],
                                             RELEASE_TEST_LOG=str(log), RELEASE_TEST_MODE=mode,
                                             FAIL_UPLOAD=str(int(fail_upload))))
            calls = log.read_text() if log.exists() else ''
            return result, calls

    def test_published_release_is_never_overwritten(self):
        result, calls = self.run_release('published')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('upload', calls)
        self.assertNotIn('edit', calls)
        self.assertNotIn('delete', calls)

    def test_failed_upload_stays_draft(self):
        result, calls = self.run_release('draft', fail_upload=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('upload', calls)
        self.assertNotIn('edit', calls)

    def test_new_release_publishes_only_after_upload(self):
        result, calls = self.run_release('missing')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--draft --verify-tag', calls)
        self.assertLess(calls.index('upload'), calls.index('edit'))
        self.assertNotIn('delete', calls)
