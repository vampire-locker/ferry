#!/usr/bin/env python3
"""Explicit read-only real-device probe. Never invoked by tests or builds."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import threading
import time

parser = argparse.ArgumentParser(description='只读验证手机目录；请先停止其他 MTP 操作')
parser.add_argument('engine', type=Path)
parser.add_argument('path', help='手机存储内的目录，例如 DCIM/Camera')
parser.add_argument('--storage', type=int, help='可选存储 ID；默认第一个存储')
args = parser.parse_args()
helper = str(args.engine.resolve())

def invoke(payload):
    started = time.monotonic()
    proc = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    timer = threading.Timer(660, proc.kill)
    timer.start()
    terminal = None
    try:
        proc.stdin.write(json.dumps(payload) + '\n')
        proc.stdin.close()
        for line in proc.stdout:
            event = json.loads(line)
            if event['type'] == 'status':
                print(f"  {time.monotonic() - started:.2f}s {event.get('message', '')}", flush=True)
            elif event['type'] in ('listed', 'connected', 'error'):
                terminal = event
        stderr = proc.stderr.read()
        result = proc.wait()
        if stderr:
            print(stderr, file=sys.stderr, end='', flush=True)
        if result or terminal is None or terminal['type'] == 'error':
            raise RuntimeError((terminal or {}).get('message', f'引擎退出码 {result}'))
        print(f"  总耗时 {time.monotonic() - started:.2f}s", flush=True)
        return terminal
    finally:
        timer.cancel()
        if proc.poll() is None:
            proc.kill()
            proc.wait()

connected = invoke({'operation': 'connect'})
storage = args.storage or connected['storages'][0]['id']
key = connected['deviceKey']
print(f"设备：{connected['deviceName']}；存储 ID：{storage}", flush=True)
request = {'operation': 'list', 'deviceKey': key, 'storageID': storage, 'parentID': 0}
listing = invoke(request)
for component in (part for part in args.path.split('/') if part):
    matches = [entry for entry in listing.get('entries', []) if entry['name'] == component and entry['isDirectory']]
    if len(matches) != 1:
        raise RuntimeError(f'无法唯一定位目录：{component}')
    request['parentID'] = matches[0]['id']
    print(f"读取目录：{component}，对象 ID：{request['parentID']}", flush=True)
    listing = invoke(request)
entries = listing.get('entries', [])
directories = sum(entry['isDirectory'] for entry in entries)
print(f"PASS {args.path}：{len(entries)} 项（{directories} 个目录、{len(entries)-directories} 个文件）", flush=True)
