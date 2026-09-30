# -*- coding: utf-8 -*-
"""Mutation-test the new page-contract assertions in tests/smoke-webui.ps1.

Each mutation breaks exactly one invariant the new block asserts, runs the smoke
test, and expects that assertion to fail by name. The page is restored from an
in-memory copy of its bytes after every case and once more on the way out.

Two things keep the verdict honest. The harness first runs the suite against
the untouched page and refuses to go on unless it passes, so a dead server
(busy port, missing node, a fixture that stopped matching the machine) cannot
be misread as ten caught mutations. And a mutation only counts as caught when
the failure names one of the new assertions: the suite also prints older,
unrelated "FAIL: the web UI never answered"-style messages, and crediting one of
those would report a catch this block never made.
"""
import io, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGE = os.path.join(ROOT, 'web-ui.html')
SMOKE = os.path.join(ROOT, 'tests', 'smoke-webui.ps1')

with io.open(PAGE, 'rb') as f:
    original = f.read()

# Every message the new block in the smoke test can throw, reduced to one
# ASCII-only substring. ASCII on purpose: the harness runs PowerShell through a
# pipe whose code page mangles the single non-ASCII message in that block, and a
# needle that can be mangled silently stops matching. The harness refuses to
# start if one of these has drifted out of the smoke script, so editing a message
# fails loudly here instead of quietly matching nothing.
EXPECTED = [
    'do not answer the same names',
    'no #skills-scroll',
    '.skills-thead does not stick',
    '#skills-thead is not inside #skills-scroll',
    'the row list does not follow the header',
    'of the two themes style the header',
    'nothing reads #skills-scroll',
    'the header height is not a named value',
    'do not park under the column header',
    'but not its sort button',
    'paintStaticIcons lists only',
    'which the page does not ship',
    'the skill table header has only',
    'sort buttons against',
]

# (label, old bytes, new bytes) -- every `old` must appear exactly once.
MUTATIONS = [
    ('theme token only in light',
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


def flat(text):
    """Collapse whitespace, so a wrapped or '+'-continued message still matches."""
    return ' '.join(text.split())


def run_smoke():
    root = ROOT.replace(chr(92), '/')
    cmd = ('cd %s && powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke-webui.ps1'
           % root)
    p = subprocess.run(['bash', '-lc', cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.returncode, p.stdout.decode('utf-8', 'replace')


def caught_by(out):
    """Which of the new assertions this run's failure names."""
    text = flat(out)
    return [n for n in EXPECTED if n in text]


def restore():
    with io.open(PAGE, 'wb') as f:
        f.write(original)
    with io.open(PAGE, 'rb') as f:
        assert f.read() == original, 'restore did not reproduce the original bytes'


def control():
    """The untouched page must pass; otherwise every result below is noise."""
    rc, out = run_smoke()
    if rc == 0 and not caught_by(out):
        return True
    print('BASELINE FAILED - the suite does not pass on the untouched page, '
          'so a caught mutation below would prove nothing.')
    print('exit code: %d' % rc)
    for line in out.splitlines():
        if 'FAIL' in line or 'rror' in line:
            print('  ' + line.strip()[:200])
    return False


def last_line(out):
    lines = [l.strip() for l in out.splitlines() if l.strip()]
    return lines[-1][:120] if lines else '(no output)'


def main():
    with io.open(SMOKE, encoding='utf-8') as f:
        smoke_src = flat(f.read())
    missing = [n for n in EXPECTED if n not in smoke_src]
    if missing:
        print('This harness is out of date - the smoke test no longer throws these:')
        for n in missing:
            print('  ' + n)
        return 3
    if not control():
        return 2
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
            rc, out = run_smoke()
            restore()
            hits = caught_by(out)
            ok = bool(hits) and rc != 0
            if not ok:
                bad += 1
            print('%-46s %-8s %s' % (label, 'CAUGHT' if ok else 'ESCAPED',
                                     hits[0] if hits else last_line(out)))
    finally:
        restore()
    with io.open(PAGE, 'rb') as f:
        tail = f.read()
    print('final page bytes identical to original:', tail == original)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
