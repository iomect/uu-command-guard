#!/usr/bin/env python3
"""Verify an installed bundle launch/exit and unchanged legacy log files.
Run only after the user has authorized replacing/restarting this tool.
Never changes UU, permissions, network config or posts input events.
"""
from pathlib import Path
import json
import os
import signal
import subprocess
import time

project = Path(__file__).resolve().parents[1]
app = Path('/Applications/UU 修补工具.app')
exe = app / 'Contents/MacOS/UUCommandGuard'
logs = Path.home() / 'Library/Application Support/UUCommandGuard/logs'

def pids():
    r = subprocess.run(['/usr/sbin/lsof', '-t', '--', str(exe)], capture_output=True, text=True)
    return list(set(int(x) for x in r.stdout.split()))

def stop():
    for pid in pids(): os.kill(pid, signal.SIGTERM)
    limit = time.monotonic() + 3
    while pids() and time.monotonic() < limit: time.sleep(.1)
    assert not pids(), 'tool did not exit after SIGTERM'

def inventory():
    if not logs.exists(): return {}
    return {str(p.relative_to(logs)): (p.stat().st_size, p.stat().st_mtime_ns)
            for p in logs.rglob('*') if p.is_file()}

stop()
backup = project / 'dist/previous-installed-app'
if not backup.exists():
    subprocess.run(['/usr/bin/ditto', str(app), str(backup)], check=True)
staged = app.with_name('UU 修补工具.update.app')
assert not staged.exists(), 'staging path already exists'
subprocess.run(['/usr/bin/ditto', str(project / 'dist/UU 修补工具.app'), str(staged)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(staged)], check=True)
# Only replace the bundle whose identifier was verified before running this test.
identifier = subprocess.check_output(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleIdentifier', str(app/'Contents/Info.plist')], text=True).strip()
assert identifier == 'local.uu-command-guard'
import shutil
shutil.rmtree(app)
staged.rename(app)
subprocess.run([str(exe), '--self-test'], check=True)
version = subprocess.check_output([str(exe), '--version'], text=True).strip()
before = inventory()
subprocess.run(['/usr/bin/open', str(app)], check=True)
time.sleep(3)
assert len(pids()) == 1, 'LaunchServices startup must leave exactly one live app'
first = pids()[0]
subprocess.run(['/usr/bin/open', str(app)], check=True)
time.sleep(1)
assert pids() == [first], 'repeat open must keep a single instance'
time.sleep(7)
assert inventory() == before, 'normal app launch modified legacy disk logs'
stop()
subprocess.run(['/usr/bin/open', str(app)], check=True)
time.sleep(3)
assert len(pids()) == 1, 'app restart failed'
assert inventory() == before, 'restart modified legacy logs'
report = {'version': version, 'bundle_self_test': 'passed', 'launchservices_start': 'passed',
          'single_instance_open': 'passed', 'sigterm_exit': 'passed', 'restart': 'passed',
          'legacy_logs_unchanged_14_seconds': True,
          'scope': 'No permission changes, synthetic/posted input, UU restarts or peer configuration; live input path not asserted'}
(project/'validation').mkdir(exist_ok=True)
(project/'validation/mac-startup.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(report,ensure_ascii=False,indent=2))
