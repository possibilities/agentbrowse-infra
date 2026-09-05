#!/usr/bin/python3
"""Explicit loopback TCP relay for the owned Apple container service."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import threading
import ipaddress

LABEL = 'dev.agentbrowse.apple-relay'
ROOT = Path(os.environ.get('AGENTBROWSE_INFRA_ROOT', str(Path.home() / 'Library/Application Support/agentbrowse-infra')))
CONTAINER = os.environ.get('CONTAINER_BIN', '/usr/local/bin/container')

def owned():
    if (ROOT / 'OWNED').read_text().strip() != 'agentbrowse-infra-owned-v1':
        raise RuntimeError('Apple infrastructure ownership marker is missing')

def main():
    owned()
    domain = 'gui/' + str(os.getuid())
    action = sys.argv[1] if len(sys.argv) == 2 else ''
    if action == 'enable':
        plist = ROOT / 'relay.plist'
        plist.write_bytes(plistlib.dumps({'Label': LABEL,
            'ProgramArguments': ['/usr/bin/python3', str(Path(__file__).resolve()), 'serve'],
            'EnvironmentVariables': {'AGENTBROWSE_INFRA_ROOT': str(ROOT), 'CONTAINER_BIN': CONTAINER},
            'RunAtLoad': True, 'KeepAlive': False,
            'StandardOutPath': str(ROOT / 'relay.log'), 'StandardErrorPath': str(ROOT / 'relay.log')}))
        probe = subprocess.run(['launchctl', 'print', domain + '/' + LABEL], capture_output=True)
        subprocess.run(['launchctl', 'bootstrap', domain, str(plist)] if probe.returncode else ['launchctl', 'kickstart', domain + '/' + LABEL], check=True)
    elif action == 'disable':
        probe = subprocess.run(['launchctl', 'print', domain + '/' + LABEL], capture_output=True)
        if probe.returncode == 0:
            subprocess.run(['launchctl', 'bootout', domain + '/' + LABEL], check=True)
    elif action == 'serve':
        spec = importlib.util.spec_from_file_location('forward', Path(__file__).with_name('hypeman-relay.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        forwards = {}
        stopped = threading.Event()
        signal.signal(signal.SIGTERM, lambda *_: stopped.set())
        signal.signal(signal.SIGINT, lambda *_: stopped.set())
        try:
            while not stopped.is_set():
                try:
                    owned()
                    status = subprocess.run([CONTAINER, 'system', 'status'], capture_output=True, text=True, check=True, timeout=5).stdout
                    actual = next((line.split(': ', 1)[1].rstrip('/') for line in status.splitlines() if line.startswith('application data root: ')), '')
                    if actual != str(ROOT.resolve() / 'runtime'):
                        raise RuntimeError('Apple service is outside the owned application root')
                    result = subprocess.run([CONTAINER, 'list', '--format', 'json'], capture_output=True, text=True, check=True, timeout=5)
                    wanted = {}
                    for row in json.loads(result.stdout):
                        cfg = row['configuration']
                        tags = cfg.get('labels', {})
                        if row['status'] != 'running' or tags.get('dev.agentbrowse.managed') != 'true' or tags.get('dev.agentbrowse.role') != 'kernel-browser':
                            continue
                        slot = int(tags['dev.agentbrowse.slot'])
                        if not 0 <= slot <= 999:
                            raise RuntimeError('invalid owned browser slot')
                        ip = str(ipaddress.IPv4Interface(row['networks'][0]['ipv4Address']).ip)
                        for port, guest in [(9222 + slot, 9222), (18080 + slot, 8080)]:
                            if port in wanted:
                                raise RuntimeError('duplicate Apple relay port')
                            wanted[port] = (ip, guest, cfg['id'])
                    for port, (entry, forward) in list(forwards.items()):
                        if wanted.get(port) != entry:
                            forward.close()
                            del forwards[port]
                    for port, entry in wanted.items():
                        if port not in forwards:
                            forwards[port] = (entry, module.Forward(port, entry[0], entry[1]))
                except (OSError, ValueError, KeyError, IndexError, RuntimeError, subprocess.SubprocessError) as error:
                    for _, forward in forwards.values():
                        forward.close()
                    forwards.clear()
                    print(str(error), file=sys.stderr, flush=True)
                stopped.wait(1)
        finally:
            for _, forward in forwards.values():
                forward.close()
    else:
        raise RuntimeError('usage: agentbrowse-infra relay enable|disable')

if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
