"""Exercise build failure paths without compiling or modifying the working app."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class BuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        for name in ('build.sh', 'scripts', 'Resources', 'src'):
            source = ROOT / name
            if source.is_dir():
                shutil.copytree(source, self.root / name)
            else:
                shutil.copy2(source, self.root / name)
        tools = self.root / 'tools'
        tools.mkdir()
        stubs = {
            'xcrun': 'if [[ "$1" == "--find" ]]; then exit 1; fi; echo /fake-sdk',
            'swiftc': '''out=; arch=
while (($#)); do
 case "$1" in -o) out="$2"; shift;; -target) arch="${2%%-*}"; shift;; esac
 shift
done
echo "$arch" >> "$BUILD_TEST_LOG"
[[ "$arch" != "${FAIL_ARCH:-}" ]] || exit 1
printf '%s\\n' "$arch" > "$out"
chmod +x "$out"''',
            'lipo': '''if [[ "$1" == "-archs" ]]; then cat "$2"; exit; fi
if [[ "$1" == "-create" ]]; then cat "$4" "$5" | tr '\\n' ' ' > "$3"; exit; fi
exit 1''',
            'codesign': '[[ "${FAIL_SIGN:-0}" != 1 ]]',
        }
        for name, body in stubs.items():
            path = tools / name
            path.write_text('#!/bin/bash\nset -eu\n' + body + '\n')
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'],
                        BUILD_TEST_LOG=str(self.root / 'compiles.log'))

    def run_script(self, *args, **env):
        return subprocess.run(['bash', *args], cwd=self.root,
                              env=dict(self.env, **env), capture_output=True, text=True)

    def test_universal_must_fail_when_intel_compilation_fails(self):
        result = self.run_script('build.sh', '--target', 'universal', FAIL_ARCH='x86_64')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unknown_target_is_rejected(self):
        result = self.run_script('build.sh', '--target', 'typo')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.root / 'compiles.log').exists())

    def test_signing_failure_is_fatal(self):
        result = self.run_script('build.sh', '--target', 'arm64', FAIL_SIGN='1')
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_all_compiles_each_architecture_once(self):
        result = self.run_script('build.sh', '--target', 'all')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertCountEqual((self.root / 'compiles.log').read_text().splitlines(), ['arm64', 'x86_64'])
        for arch, expected in [('arm64', {'arm64'}), ('x86_64', {'x86_64'}),
                               ('universal', {'arm64', 'x86_64'})]:
            binary = self.root / 'build' / arch / '输入法锁定.app/Contents/MacOS/InputSourceLock'
            self.assertTrue(binary.exists(), str(binary))
            self.assertEqual(set(binary.read_text().split()), expected)

    def test_release_version_mismatch_fails_before_compiling(self):
        result = self.run_script('scripts/build_dmg.sh', '999.0.0', 'arm64')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'compiles.log').exists(), 'Version mismatch must fail before build')

if __name__ == '__main__':
    unittest.main()
