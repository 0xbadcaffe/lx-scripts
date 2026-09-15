"""Offline regression tests; privileged commands are replaced with recording stubs."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'


class ScriptsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='lx-scripts-test-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        self.log = self.work / 'commands'
        self.env = dict(os.environ, HOME=str(self.work),
                        PATH=f'{self.bin}:/usr/bin:/bin', LOG=str(self.log),
                        GIT_CONFIG_GLOBAL=str(self.work / 'gitconfig'),
                        GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0')
        for key in list(self.env):
            if key.startswith(('GIT_CONFIG_KEY_', 'GIT_CONFIG_VALUE_')) or key in (
                'GIT_CONFIG_COUNT', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'):
                self.env.pop(key)

    def run_cmd(self, *args, status=0):
        result = subprocess.run([str(a) for a in args], cwd=self.work,
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def script(self, name, *args, status=0):
        return self.run_cmd('bash', SCRIPTS / name, *args, status=status)

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o755)

    def test_shell_syntax(self):
        for path in [ROOT / 'settings.sh', *SCRIPTS.glob('*.sh')]:
            with self.subTest(script=path.name):
                self.run_cmd('bash', '-n', path)
                if path.parent == SCRIPTS:
                    self.assertTrue(os.access(path, os.X_OK), path.name)

    def test_help(self):
        for path in SCRIPTS.glob('*.sh'):
            with self.subTest(script=path.name):
                self.assertIn('usage:', self.script(path.name, '--help').lower())

    def test_settings_from_another_directory_and_repeated_source(self):
        out = self.run_cmd('bash', '-eu', '-c',
                           'source "$1"; source "$1"; printf "%s\\n" "$LX_SCRIPT_LOC" "$PATH"',
                           'bash', ROOT / 'settings.sh')
        self.assertEqual(out.splitlines()[-2], str(ROOT))
        self.assertEqual(out.splitlines()[-1].split(':').count(str(SCRIPTS)), 1)
        out = self.run_cmd('dash', '-c', '. "$1"', 'dash', ROOT / 'settings.sh', status=1)
        self.assertIn('must be sourced from Bash', out)
        self.assertNotIn('not found', out)

    def test_catalog_and_selection(self):
        rows = [line.split('|') for line in (SCRIPTS / 'data/yocto-repositories.txt').read_text().splitlines()]
        ids = [row[0] for row in rows]
        self.assertEqual(len(ids), len(set(ids)))
        for name in ('lx-clone-yocto-world.sh', 'lx-init-yocto-world.sh'):
            out = self.script(name, '--list')
            self.assertEqual([line.split()[0] for line in out.splitlines()[1:]], ids)
        out = self.script('lx-clone-yocto-world.sh', '--only', 'poky,openbmc', '--root', 'absent')
        self.assertIn('PLAN ONLY', out)
        self.assertNotIn('meta-qt6', out)
        self.assertFalse((self.work / 'absent').exists())
        for value in ('unknown', 'poky,unknown', 'poky,', ',poky', 'poky,,openbmc'):
            self.script('lx-clone-yocto-world.sh', '--only', value, '--apply', '--root', 'absent', status=1)
        self.assertFalse((self.work / 'absent').exists())

    def test_missing_arguments(self):
        for flag in ('--root', '--only'):
            self.script('lx-clone-yocto-world.sh', flag, status=1)
            self.script('lx-clone-yocto-world.sh', flag, '--apply', status=1)
        for flag in ('--id', '--root', '--machine', '--distro', '--project', '--build-dir',
                     '--branch', '--manifest', '--jobs', '-j'):
            self.script('lx-init-yocto-world.sh', flag, status=7)
            self.script('lx-init-yocto-world.sh', flag, '--apply', status=7)

    def test_init_exit_codes(self):
        for name, status in [('unknown', 7), ('poky', 3), ('meta-arm', 6),
                             ('petalinux-manifest', 5), ('ti-sdk', 5)]:
            self.script('lx-init-yocto-world.sh', '--id', name, status=status)

    def test_existing_manifest_workspace_without_sync(self):
        self.stub('repo', 'printf "%s\\n" "$*" >> "$LOG"')
        for name, setup in [('openstlinux', 'layers/meta-st/scripts/envsetup.sh'),
                            ('nxp-imx', 'imx-setup-release.sh'),
                            ('analog-lnxdsp', 'setup-environment'),
                            ('variscite', 'setup-environment')]:
            with self.subTest(project=name):
                (self.work / name).mkdir()
                workspace = self.work / 'workspaces' / name
                (workspace / '.repo').mkdir(parents=True)
                setup_path = workspace / setup
                setup_path.parent.mkdir(parents=True, exist_ok=True)
                setup_path.write_text('exit 99\n')  # Preview must never source this.
                args = ('--root', '.', '--id', name, '--machine', 'board', '--distro', 'distro')
                out = self.script('lx-init-yocto-world.sh', *args)
                self.assertIn('CHECK PASSED', out)
                self.assertFalse(self.log.exists())
                self.script('lx-init-yocto-world.sh', *args, '--sync', '--jobs', '3')
                self.assertEqual(self.log.read_text(), 'sync -j3\n')
                self.log.unlink()

    def test_clone_and_update_real_local_git(self):
        source = self.work / 'upstream'
        self.run_cmd('git', 'init', '-b', 'main', source)
        self.run_cmd('git', '-C', source, 'config', 'user.name', 'Test')
        self.run_cmd('git', '-C', source, 'config', 'user.email', 'test@example.invalid')
        tracked = source / 'README'
        tracked.write_text('first\n')
        self.run_cmd('git', '-C', source, 'add', 'README')
        self.run_cmd('git', '-C', source, '-c', 'commit.gpgsign=false', 'commit', '-m', 'first')
        self.run_cmd('git', 'config', '--global', f'url.{source}.insteadOf', 'https://git.yoctoproject.org/poky')
        target = self.work / 'checkout with spaces'
        args = ('--only', 'poky', '--root', target, '--apply')
        self.script('lx-clone-yocto-world.sh', *args)
        tracked.write_text('second\n')
        self.run_cmd('git', '-C', source, '-c', 'commit.gpgsign=false', 'commit', '-am', 'second')
        self.script('lx-clone-yocto-world.sh', *args, '--update')
        checkout = target / 'poky'
        self.assertEqual((checkout / 'README').read_text(), 'second\n')
        (checkout / 'README').write_text('local changes\n')
        self.assertIn('SKIP dirty', self.script('lx-clone-yocto-world.sh', *args, '--update'))
        self.assertEqual((checkout / 'README').read_text(), 'local changes\n')
        self.run_cmd('git', '-C', checkout, 'checkout', '--', 'README')
        self.run_cmd('git', '-C', checkout, 'remote', 'set-url', 'origin', self.work / 'missing')
        self.script('lx-clone-yocto-world.sh', *args, '--update', status=128)

    def test_settings_reject_execution(self):
        out = self.run_cmd('bash', ROOT / 'settings.sh', status=1)
        self.assertIn('source ./settings.sh', out)

    def test_settings_cleans_path(self):
        self.env['PATH'] = f'/usr/bin::{SCRIPTS}/:.:./:/bin:{SCRIPTS}'
        out = self.run_cmd('bash', '-c',
                           'source "$1"; printf "%s\\n" "$PATH"',
                           'bash', ROOT / 'settings.sh')
        self.assertEqual(out.splitlines()[-1], f'{SCRIPTS}:/usr/bin:/bin')

    def test_manifest_requires_sync(self):
        self.stub('repo', 'exit 99')
        (self.work / 'openstlinux').mkdir()
        self.script('lx-init-yocto-world.sh', '--id', 'openstlinux', '--root', '.', status=4)
        self.assertFalse((self.work / 'workspaces').exists())


if __name__ == '__main__':
    unittest.main()
