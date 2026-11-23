#!/usr/bin/env python3
"""End-to-end NDJSON/engine tests. Synthetic device only; no phone is accessed."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

engine = str(Path(sys.argv[1]).resolve())

def request(payload, expected=0):
    result = subprocess.run([engine, '--demo'], input=json.dumps(payload),
                            text=True, capture_output=True, timeout=30)
    assert result.returncode == expected, result.stderr + result.stdout
    events = [json.loads(line) for line in result.stdout.splitlines()]
    return events

connected = request({'operation': 'connect'})[-1]
assert connected['type'] == 'connected'
key = connected['deviceKey']
base = {'storageID': 1, 'deviceKey': key}
listed = request(dict(base, operation='list', parentID=0))[-1]
assert len(listed['entries']) == 3
assert request(dict(base, operation='list', deviceKey='wrong'), expected=1)[-1]['type'] == 'error'
fast = request(dict(base, operation='list', parentID=10, includeSizes=False))[-1]['entries']
assert len(fast) == 12 and all(row['size'] == -1 for row in fast)
size_event = request(dict(base, operation='sizes', parentID=10))[-1]
assert size_event['type'] == 'sized'
sizes = {row['id']: row['size'] for row in size_event['sizes']}
full = request(dict(base, operation='list', parentID=10, includeSizes=True))[-1]['entries']
assert {row['id']: row['size'] for row in full} == sizes
assert request(dict(base, operation='sizes', parentID=10, deviceKey='wrong'), expected=1)[-1]['type'] == 'error'

def serial_request(proc, payload):
    proc.stdin.write(json.dumps(payload) + '\n')
    proc.stdin.flush()
    events = []
    for line in proc.stdout:
        event = json.loads(line)
        events.append(event)
        if event['type'] in ('ready', 'error'):
            return events
    raise AssertionError('helper exited before serial response')

# Cooperative downloads keep one report and yield between committed files,
# allowing another storage/directory request on the same serial USB session.
with tempfile.TemporaryDirectory(prefix='ferry-queue-smoke-') as temp:
    with subprocess.Popen([engine, '--demo', '--serve'], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as proc:
        try:
            begin = dict(base, operation='download', downloadID='queued-task', downloadAction='begin',
                         objectIDs=[10, 20, 30], destination=temp)
            events = serial_request(proc, begin)
            assert [event['type'] for event in events][-2:] == ['yielded', 'ready']
            output = Path(events[-2]['output'])
            assert not list((output / 'files').rglob('*'))
            steps = 0
            while True:
                events = serial_request(proc, dict(base, operation='download', downloadID='queued-task', downloadAction='next'))
                terminal = events[-2]
                assert events[-1]['type'] == 'ready' and terminal['output'] == str(output)
                steps += 1
                committed = [path for path in (output / 'files').rglob('*') if path.is_file()]
                assert len(committed) == steps, 'A step must transfer exactly one complete file'
                assert not list((output / 'files').rglob('*.part'))
                if terminal['type'] == 'completed':
                    assert terminal['state'] == 'completed'
                    break
                assert terminal['type'] == 'yielded'
                browse = serial_request(proc, dict(base, operation='list', parentID=20))
                assert browse[-2]['type'] == 'listed' and browse[-1]['type'] == 'ready'
            assert steps == 18
            report = json.loads((output / '传输报告.json').read_text())
            assert report['state'] == 'completed'
            for item in report['items']:
                if not item['entry']['isDirectory']:
                    data = (output / 'files' / item['path']).read_bytes()
                    assert len(data) == item['entry']['size']
                    assert hashlib.sha256(data).hexdigest() == item['sha256']
            begin.update(downloadID='cancel-task', objectIDs=[10])
            events = serial_request(proc, begin)
            cancelled = Path(events[-2]['output'])
            events = serial_request(proc, dict(base, operation='download', downloadID='cancel-task', downloadAction='cancel'))
            assert events[-2]['type'] == 'completed' and events[-2]['state'] == 'cancelled'
            assert events[-1]['type'] == 'ready'
            assert json.loads((cancelled / '传输报告.json').read_text())['state'] == 'cancelled'
            assert not list((cancelled / 'files').rglob('*'))
            assert serial_request(proc, dict(base, operation='list'))[-1]['type'] == 'ready'
            begin.update(downloadID='eof-task')
            events = serial_request(proc, begin)
            interrupted = Path(events[-2]['output'])
            proc.stdin.close()
            assert proc.wait(timeout=10) == 0
            assert json.loads((interrupted / '传输报告.json').read_text())['state'] == 'cancelled'
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=10)

    # An incorrect task ID must not resume another task or read any file.
    with subprocess.Popen([engine, '--demo', '--serve'], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as proc:
        try:
            events = serial_request(proc, dict(base, operation='download', downloadID='original',
                downloadAction='begin', objectIDs=[10], destination=temp))
            rejected = Path(events[-2]['output'])
            events = serial_request(proc, dict(base, operation='download', downloadID='wrong', downloadAction='next'))
            assert events[-1]['type'] == 'error' and events[-1]['state'] == 'failed'
            assert proc.wait(timeout=10) == 1
            assert json.loads((rejected / '传输报告.json').read_text())['state'] == 'failed'
            assert not list((rejected / 'files').rglob('*'))
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=10)

# A live session accepts its selected USB route only, even in synthetic mode.
usb_target = {'busNumber': 2, 'portNumbers': [1, 3], 'vendorID': 10,
              'productID': 20, 'serialNumber': 'phone'}
for replacement in (None, dict(usb_target, portNumbers=[1, 4])):
    with subprocess.Popen([engine, '--demo', '--serve'], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as proc:
        def exchange(payload):
            proc.stdin.write(json.dumps(payload) + '\n')
            proc.stdin.flush()
            events = []
            for line in proc.stdout:
                event = json.loads(line)
                events.append(event)
                if event['type'] in ('ready', 'error'):
                    return events
            raise AssertionError('helper exited before response')
        try:
            events = exchange({'operation': 'connect', 'usbTarget': usb_target})
            assert events[-1]['type'] == 'ready'
            events = exchange(dict(base, operation='list', usbTarget=usb_target))
            assert any(event['type'] == 'listed' for event in events)
            changed = dict(base, operation='list')
            if replacement is not None:
                changed['usbTarget'] = replacement
            events = exchange(changed)
            assert events[-1]['type'] == 'error' and events[-1]['state'] == 'failed'
            assert not any(event['type'] == 'listed' for event in events)
            assert proc.wait(timeout=10) == 1
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=10)

with tempfile.TemporaryDirectory(prefix='ferry-smoke-') as temp:
    events = request(dict(base, operation='download', objectIDs=[10, 20, 30], destination=temp))
    done = events[-1]
    assert done['type'] == 'completed'
    output = Path(done['output'])
    report = json.loads((output / '传输报告.json').read_text())
    assert report['state'] == 'completed'
    files = [item for item in report['items'] if not item['entry']['isDirectory']]
    assert len(files) == 18
    for item in files:
        data = (output / 'files' / item['path']).read_bytes()
        assert len(data) == item['entry']['size']
        assert hashlib.sha256(data).hexdigest() == item['sha256']
    assert not list(output.rglob('*.part'))

    for object_id in (111, 112):
        staged = request(dict(base, operation='preview', objectIDs=[object_id], destination=temp))[-1]
        assert staged['type'] == 'completed'
        original = next(item for item in files if item['entry']['id'] == object_id)
        assert Path(staged['output']).read_bytes() == (output / 'files' / original['path']).read_bytes()
    thumbnails = request(dict(base, operation='thumbnails', objectIDs=[111, 112], destination=temp))
    ready = [event for event in thumbnails if event['type'] == 'thumbnail']
    assert [event['objectID'] for event in ready] == [111, 112]
    for event in ready:
        assert event['state'] == 'completed'
        assert Path(event['output']).read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
    assert thumbnails[-1]['type'] == 'completed'
    assert request(dict(base, operation='preview', objectIDs=[10], destination=temp), expected=1)[-1]['type'] == 'error'

    proc = subprocess.Popen([engine, '--demo'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    proc.stdin.write(json.dumps(dict(base, operation='download', objectIDs=[10], destination=temp)) + '\n')
    proc.stdin.close()
    events = []
    for line in proc.stdout:
        event = json.loads(line)
        events.append(event)
        if event['type'] == 'progress' and event.get('currentFile'):
            proc.send_signal(signal.SIGINT)
            break
    events.extend(json.loads(line) for line in proc.stdout)
    assert proc.wait(timeout=10) == 1
    assert events[-1]['state'] == 'cancelled'
    cancelled = Path(events[-1]['output'])
    assert json.loads((cancelled / '传输报告.json').read_text())['state'] == 'cancelled'
    assert not list(cancelled.rglob('*.part'))
with tempfile.TemporaryDirectory(prefix='ferry-save-layout-') as destination, \
        tempfile.TemporaryDirectory(prefix='ferry-reports-') as reports:
    selected = next(row for row in full if row['name'].endswith('.png'))
    saved = []
    archived = []
    for layout, archive in (('direct', False), ('direct', False), ('folder', False),
                            ('direct', True), ('direct', True), ('folder', True)):
        events = request(dict(base, operation='download', objectIDs=[selected['id']],
                              destination=destination, downloadLayout=layout,
                              reportDirectory=reports, usePhotoCreationDate=True,
                              archivePhotosByMonth=archive))
        terminal = events[-1]
        assert terminal['type'] == 'completed'
        output = Path(terminal['output'])
        report_path = Path(next(event['reportPath'] for event in events if event.get('reportPath')))
        assert report_path.is_relative_to(Path(reports))
        report = json.loads(report_path.read_text())
        assert report['state'] == 'completed' and report['output'] == str(output)
        item = report['items'][0]
        content = (output / item['path']).read_bytes()
        assert len(content) == item['entry']['size']
        assert hashlib.sha256(content).hexdigest() == item['sha256']
        assert not list(output.glob('.ferry-*'))
        assert not (output / '传输报告.json').exists()
        assert not (output / '任务记录.ndjson').exists()
        if archive:
            stamp = time.localtime(selected['modified'])
            assert Path(item['path']).parent == Path(f"{stamp.tm_year:04d}/{stamp.tm_mon:02d}月")
            assert item['archiveDateSource'] == 'modified' and item['sourcePath'] == selected['name']
        if layout == 'direct':
            assert output == Path(destination)
            (archived if archive else saved).append(output / item['path'])
        else:
            assert output.parent == Path(destination) and output != Path(destination)
    assert saved[0] != saved[1] and saved[0].read_bytes() == saved[1].read_bytes()
    assert archived[0] != archived[1] and archived[0].parent == archived[1].parent
    assert archived[0].read_bytes() == archived[1].read_bytes() == saved[0].read_bytes()

with tempfile.TemporaryDirectory(prefix='ferry-conflicts-') as destination, \
        tempfile.TemporaryDirectory(prefix='ferry-conflict-reports-') as reports:
    selected_rows = [row for row in full if row['id'] in (111, 112)]
    with subprocess.Popen([engine, '--demo', '--serve'], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as proc:
        try:
            for number, choice in enumerate(('keepBoth', 'skip', 'replace')):
                for row in selected_rows:
                    (Path(destination) / row['name']).write_bytes(b'old')
                begin = dict(base, operation='download', downloadID=f'conflict-{number}',
                             downloadAction='begin', objectIDs=[111, 112], destination=destination,
                             downloadLayout='direct', reportDirectory=reports, promptConflicts=True)
                events = serial_request(proc, begin)
                report_path = Path(events[-2]['reportPath'])
                events = serial_request(proc, dict(base, operation='download', downloadID=begin['downloadID'], downloadAction='next'))
                assert events[-1]['type'] == 'ready' and events[-2]['state'] == 'waiting'
                conflict = events[-2]['conflict']
                assert conflict['kind'] == 'file' and conflict['canReplace']
                assert Path(conflict['targetPath']).read_bytes() == b'old'
                assert not list(Path(destination).glob('.ferry-download-*'))
                events = serial_request(proc, dict(base, operation='download', downloadID=begin['downloadID'], downloadAction='resolve',
                    conflictDecision=dict(id=conflict['id'], choice=choice, applyToAll=True)))
                assert events[-2]['type'] == 'yielded' and events[-2]['state'] == 'running'
                events = serial_request(proc, dict(base, operation='download', downloadID=begin['downloadID'], downloadAction='next'))
                assert events[-2]['type'] == 'completed' and events[-1]['type'] == 'ready'
                if choice == 'skip':
                    progress = [event for event in events if event['type'] == 'progress'][-1]
                    assert progress['bytes'] == progress['totalBytes'] == progress['reusedBytes']
                report = json.loads(report_path.read_text())
                assert all(item['conflictAction'] == choice for item in report['items'])
                for row, item in zip(selected_rows, report['items']):
                    original = Path(destination) / row['name']
                    assert (original.read_bytes() == b'old') == (choice != 'replace')
                    assert item['state'] == ('skipped' if choice == 'skip' else 'completed')
                    if choice != 'skip':
                        assert hashlib.sha256((Path(destination) / item['path']).read_bytes()).hexdigest() == item['sha256']
                    else:
                        assert 'sha256' not in item
                assert not list(Path(destination).glob('.ferry-download-*'))

            stamp = time.localtime(selected['modified'])
            canonical = f'{stamp.tm_year:04d}/{stamp.tm_mon:02d}月'
            legacy = f'{stamp.tm_year:04d}/{stamp.tm_mon}'
            for directory in (canonical, legacy):
                folder = Path(destination) / directory
                folder.mkdir(parents=True, exist_ok=True)
                (folder / selected['name']).write_bytes(b'old-month-photo')
            begin.update(downloadID='month-choice', objectIDs=[111], archivePhotosByMonth=True)
            serial_request(proc, begin)
            events = serial_request(proc, dict(base, operation='download', downloadID='month-choice', downloadAction='next'))
            conflict = events[-2]['conflict']
            assert conflict['kind'] == 'monthDirectory' and legacy in conflict['candidates']
            events = serial_request(proc, dict(base, operation='download', downloadID='month-choice', downloadAction='resolve',
                conflictDecision=dict(id=conflict['id'], choice='directory', directory=legacy)))
            conflict = events[-2]['conflict']
            assert conflict['kind'] == 'file' and conflict['targetPath'] == str(Path(destination) / legacy / selected['name'])
            events = serial_request(proc, dict(base, operation='download', downloadID='month-choice', downloadAction='resolve',
                conflictDecision=dict(id=conflict['id'], choice='skip')))
            assert events[-2]['type'] == 'completed'
            for directory in (canonical, legacy):
                assert (Path(destination) / directory / selected['name']).read_bytes() == b'old-month-photo'

            begin.update(downloadID='cancel-conflict', archivePhotosByMonth=False)
            events = serial_request(proc, begin)
            report_path = Path(events[-2]['reportPath'])
            events = serial_request(proc, dict(base, operation='download', downloadID='cancel-conflict', downloadAction='next'))
            assert events[-2]['state'] == 'waiting'
            events = serial_request(proc, dict(base, operation='download', downloadID='cancel-conflict', downloadAction='cancel'))
            assert events[-2]['state'] == 'cancelled'
            assert json.loads(report_path.read_text())['items'][0]['state'] == 'cancelled'
            assert not list(Path(destination).glob('.ferry-download-*'))
        finally:
            proc.stdin.close()
            proc.wait(timeout=10)

print('PASS engine fast-list/sizes/connect/list/download, direct/folder/month-archive layouts, interactive keep/skip/replace policies and month aliases, separate reports, cooperative file-boundary queue/browse/cancel/EOF, identity/USB/task guards, 18 file hashes, media preview/thumbnail batches, cancel, partial cleanup')
