# -*- coding: utf-8 -*-
"""Mutation-test the new page-contract assertions in tests/smoke-webui.ps1.

Each mutation breaks exactly one invariant the new block asserts, runs the
smoke test, and expects the test to FAIL naming that invariant. The page is
restored byte-for-byte from a backup after every case.
"""
import io, os, shutil, subprocess, sys

PAGE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'web-ui.html')
BAK = PAGE + '.mutbak'

with io.open(PAGE, 'rb') as f:
    original = f.read()

# (label, old bytes, new bytes) -- every `old` must appear exactly once.
MUTATIONS = [
    ('theme token only in dark',
     b'    --selected:                rgba(45, 212, 191, .10);',
     b''),
    ('thead leaves the scroller',
     b'            <div class="skills-scroll" id="skills-scroll">\n',
     b''),
    ('thead stops sticking',
     b'    position: sticky; top: 0; z-index: 3;\n',
     b''),
    ('drops the light-theme scrolled rule',
     b'  html[data-theme="light"] .skills-thead.scrolled {',
     b'  html[data-theme="light"] .skills-thead.scrolledX {'),
    ('drops the dark scrolled rule',
     b'  .skills-thead.scrolled {',
     b'  .skills-thead.scrolledX {'),
    ('scroll listener moves off the scroller',
     b"    var scroller = $('skills-scroll');",
     b"    var scroller = $('skills-list');"),
    ('group bar loses its offset',
     b'top: var(--thead-h);',
     b'top: 0;'),
    ('narrow layout keeps the hidden sort button',
     b'.cell-mod, .th-mod { display: none; }',
     b'.cell-mod { display: none; }'),
    ('icon painter names a slot the page has no',
     b"'btn-theme': 'Sun'",
     b"'btn-themee': 'Sun'"),
    ('sort button loses its icon slot',
     b'<span class="th-ic" id="th-ic-size"></span>',
     b'<span id="th-ic-size"></span>'),
]


def run_smoke():
    root = os.path.dirname(PAGE).replace(chr(92), '/')
    cmd = ('cd %s && powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke-webui.ps1'
           % root)
    p = subprocess.run(['bash', '-lc', cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = p.stdout.decode('utf-8', 'replace')
    for line in out.splitlines():
        if 'FAIL:' in line:
            return 'FAIL-CAUGHT', line.strip()
    return ('PASS' if p.returncode == 0 else 'ERROR rc=%d' % p.returncode), out.strip().splitlines()[-1]


def restore():
    with io.open(PAGE, 'wb') as f:
        f.write(original)
    with io.open(PAGE, 'rb') as f:
        assert f.read() == original, 'restore did not reproduce the original bytes'


def main():
    with io.open(BAK, 'wb') as f:
        f.write(original)
    bad = 0
    try:
        for label, old, new in MUTATIONS:
            with io.open(PAGE, 'rb') as f:
                cur = f.read()
            if cur.count(old) != 1:
                print('%-46s SKIP (anchor found %d times)' % (label, cur.count(old)))
                bad += 1
                continue
            with io.open(PAGE, 'wb') as f:
                f.write(cur.replace(old, new, 1))
            verdict, detail = run_smoke()
            restore()
            ok = verdict == 'FAIL-CAUGHT'
            if not ok:
                bad += 1
            print('%-46s %-11s %s' % (label, verdict, detail[:150]))
    finally:
        restore()
        if os.path.exists(BAK):
            os.remove(BAK)
    with io.open(PAGE, 'rb') as f:
        tail = f.read()
    print('final page bytes identical to original:', tail == original)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
