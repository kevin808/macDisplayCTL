"""Exercise native lock waiting and isolated launch-agent installation; no displays change."""
import fcntl
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]
helper = root / 'build/macDisplayCtl.app/Contents/Resources/macDisplayCtl'
with tempfile.TemporaryDirectory(prefix='macDisplayCtl-guard-') as directory:
    sandbox = Path(directory)
    lock_path = sandbox / 'guard.lock'
    command = [str(helper), '--wait-guard-lock', str(lock_path)]
    subprocess.run(command, check=True)
    with lock_path.open('a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        waiting = subprocess.Popen(command)
        time.sleep(0.25)
        assert waiting.poll() is None, 'Must wait for the previous watcher'
        fcntl.flock(lock, fcntl.LOCK_UN)
        assert waiting.wait(timeout=3) == 0
        fcntl.flock(lock, fcntl.LOCK_EX)
        result = subprocess.run(command, capture_output=True, text=True, timeout=8,
                                env=dict(os.environ, MACDISPLAYCTL_LANGUAGE='en'))
        assert result.returncode == 1 and 'previous monitor has not stopped' in result.stderr
    result = subprocess.run([str(helper), '--wait-guard-lock', str(sandbox / 'missing/lock')],
                            capture_output=True, timeout=2)
    assert result.returncode == 1

    # Keep the real home and launchd untouched; redirect only this script fixture's paths.
    home = sandbox / 'User & <display> " test'
    home.mkdir()
    script = sandbox / 'macDisplayCtl-guard'
    script.write_text((root / 'macDisplayCtl-guard').read_text().replace('$HOME', '$TEST_HOME'))
    script.chmod(0o755)
    stub = sandbox / 'macDisplayCtl'
    stub.write_text('#!/bin/sh\ncase "$1" in\nlanguage) echo en;;\nwatch) exit 0;;\n--wait-guard-lock) exec "$REAL_HELPER" "$@";;\n*) exit 2;;\nesac\n')
    stub.chmod(0o755)
    commands = sandbox / 'bin'
    commands.mkdir()
    # Python is deliberately unavailable on the installer's command search path.
    for name in ['dirname', 'id', 'mkdir', 'cp', 'chmod', 'mv', 'plutil']:
        (commands / name).symlink_to(shutil.which(name))
    launchctl = commands / 'launchctl'
    launchctl.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_CALLS"\ncase "$1" in print) exit 1;; esac\n')
    launchctl.chmod(0o755)
    calls = sandbox / 'calls'
    env = dict(os.environ, PATH=str(commands), TEST_HOME=str(home), TEST_CALLS=str(calls),
               REAL_HELPER=str(helper))
    subprocess.run(['/bin/sh', str(script), 'start'], env=env, check=True, capture_output=True)
    plist = home / 'Library/LaunchAgents/local.macDisplayCtl.guard.plist'
    data = plistlib.loads(plist.read_bytes())
    assert data['ProgramArguments'] == [str(home / 'Library/Application Support/macDisplayCtl/macDisplayCtl'), 'watch']
    assert data['AssociatedBundleIdentifiers'] == ['com.github.kevin808.macDisplayCtl']
    assert data['RunAtLoad'] is True and data['KeepAlive'] is True
    assert data['ThrottleInterval'] == 30
    assert data['StandardOutPath'] == data['StandardErrorPath'] == str(home / 'Library/Logs/macDisplayCtl-guard.log')
    assert plist.stat().st_mode & 0o777 == 0o600
    assert 'bootstrap gui/' in calls.read_text()
    assert all('local.macDisplayCtl.guard' in line for line in calls.read_text().splitlines()), 'Installer must only manage the current service'
    subprocess.run(['/bin/sh', str(script), 'start'], env=env, check=True, capture_output=True)
    assert Path(str(plist) + '.backup').exists()
print('Native lock release/timeout/errors and Python-free installer with escaped paths passed.')
