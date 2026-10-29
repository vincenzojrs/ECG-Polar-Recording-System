#!/usr/bin/env python3
"""Read-only, independent validation of a PolarPAP session. No network/dependencies.

Usage: python3 Tests/validate_session.py /path/to/session [--live] [--report output.json]
"""
import argparse
import csv
import datetime
import io
import json
import math
import pathlib
import statistics


def validate(path, live=False):
    metadata = json.loads((path / 'session.json').read_text())
    errors, warnings, streams = [], [], {}
    summary = {'session': path.name, 'status': metadata['status'], 'synthetic': metadata['synthetic']}
    for name in ('ecg', 'rr', 'hr', 'hrv', 'events', 'clock'):
        rows, nulls, malformed = [], 0, 0
        for file in sorted(path.glob('*_' + name + '.csv')):
            data = file.read_bytes()
            nulls += data.count(b'\0')
            if live:
                data = data[:data.rfind(b'\n') + 1]
            # Count/report NULs but allow validation of early prototype files
            # whose firmware string included the sensor's C-string terminator.
            reader = csv.DictReader(io.StringIO(data.replace(b'\0', b'').decode('utf-8')))
            for row in reader:
                if None in row or None in row.values():
                    malformed += 1
                else:
                    rows.append(row)
        streams[name] = rows
        summary[name + '_rows'] = len(rows)
        if nulls:
            warnings.append(f'{name}: {nulls} NUL bytes (firmware terminator fixed in final build)')
        if malformed:
            errors.append(f'{name}: {malformed} malformed rows')
    ecg = streams['ecg']
    if ecg:
        times = [int(r['timestamp_unix_ns']) for r in ecg]
        deltas = [b-a for a, b in zip(times, times[1:])]
        if any(x <= 0 for x in deltas):
            warnings.append('ECG non-increasing time; review clock reset/reconnect events')
        if deltas:
            summary.update(ecg_span_s=(times[-1]-times[0])/1e9,
                           ecg_effective_rate_hz=(len(times)-1)*1e9/(times[-1]-times[0]),
                           ecg_median_step_ms=statistics.median(deltas)/1e6,
                           ecg_gaps_over_15ms=sum(d > 15_000_000 for d in deltas),
                           ecg_nonpositive_steps=sum(d <= 0 for d in deltas))
        for row in ecg:
            if abs(int(row['ecg_uv'])/1000-float(row['ecg_mv'])) > 1e-6:
                errors.append('ECG unit conversion mismatch'); break
        summary['first_ecg_utc'] = ecg[0]['timestamp_utc']
        summary['last_ecg_utc'] = ecg[-1]['timestamp_utc']
        early = sum(t < int(metadata['start_unix_ns']) for t in times)
        if early:
            warnings.append(f'{early} ECG preview-tail samples before Record start (trimmed in final build)')
    else:
        warnings.append('No ECG samples')
    rr = streams['rr']
    for row in rr:
        if abs(int(row['rr_raw_1_1024_s'])*1000/1024-float(row['rr_ms'])) > 1e-6:
            errors.append('RR unit conversion mismatch'); break
    summary['screen_accepted_rr'] = sum(r['screen_accepted'] == 'true' for r in rr)
    summary['event_types'] = sorted(set(r['event'] for r in streams['events']))
    summary['hrv_complete_windows'] = sum(r['complete_window'] == 'true' for r in streams['hrv'])
    summary['hrv_usable_windows'] = sum(r['usable_heuristic'] == 'true' for r in streams['hrv'])
    for w in streams['hrv']:
        start, end = int(w['window_start_unix_ns']), int(w['window_end_unix_ns'])
        beats = [r for r in rr if start <= int(r['timestamp_unix_ns']) < end]
        if len(beats) != int(w['rr_count']):
            warnings.append('HRV RR count differs from raw-time window selection; check late RR events')
            continue
        values = [float(r['rr_ms']) for r in beats]
        if len(values) > 1:
            actual = float(w['sdrr_ms'])
            if abs(actual-statistics.stdev(values)) > 1e-5:
                errors.append('HRV SDRR does not match independent sample SD')
        diffs = []
        for a, b in zip(beats, beats[1:]):
            duration = float(b['rr_ms'])
            if a['connection_segment'] == b['connection_segment'] and abs((int(b['timestamp_unix_ns'])-int(a['timestamp_unix_ns']))/1e6-duration) < max(25, duration*.05):
                diffs.append(float(b['rr_ms'])-float(a['rr_ms']))
        if diffs:
            expected = math.sqrt(sum(x*x for x in diffs)/len(diffs))
            if abs(float(w['rmssd_rr_ms'])-expected) > 1e-5:
                errors.append('HRV RMSSD does not match independent calculation')
        if w['nn_verified'] != 'false':
            errors.append('Unexpected claim of verified NN intervals')
        if w['complete_window'] == 'false' and w['usable_heuristic'] != 'false':
            errors.append('Partial HRV window incorrectly qualified')
    summary.update(errors=errors, warnings=warnings, checked_at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(), live_snapshot=live)
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('session', type=pathlib.Path)
    parser.add_argument('--live', action='store_true')
    parser.add_argument('--report', type=pathlib.Path)
    args = parser.parse_args()
    result = validate(args.session, args.live)
    text = json.dumps(result, indent=2)
    if args.report:
        args.report.write_text(text + '\n')
    print(text)
    raise SystemExit(bool(result['errors']))
