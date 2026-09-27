import io, os, re, subprocess

root = os.path.dirname(os.path.abspath(__file__))
page = io.open(os.path.join(root, 'web-ui.html'), encoding='utf-8').read().replace('\r\n', '\n')

# the page's inline script (the last <script> block)
blocks = re.findall(r'<script>(.*?)</script>', page, re.S)
js = max(blocks, key=len)
io.open(os.path.join(os.environ['TEMP'], 'scan.js'), 'w', encoding='utf-8', newline='\n').write(js)
r = subprocess.run(['node', '--check', os.path.join(os.environ['TEMP'], 'scan.js')],
                   capture_output=True, text=True)
print('node --check:', r.stdout.strip() or 'ok', r.stderr.strip()[:400])

# every identifier that is CALLED, minus the ones that are declared here or are
# browser/library globals: an undefined call site is a ReferenceError at runtime.
declared = set(re.findall(r'\bfunction\s+([A-Za-z_$][\w$]*)\s*\(', js))
declared |= set(re.findall(r'\bvar\s+([A-Za-z_$][\w$]*)', js))
declared |= set(re.findall(r'\b(?:const|let)\s+([A-Za-z_$][\w$]*)', js))
declared |= set(re.findall(r'\b([A-Za-z_$][\w$]*)\s*[:=]\s*function', js))

globals_ok = set('''
Math JSON Object Array String Number Boolean Date RegExp Error parseInt parseFloat isNaN
encodeURIComponent decodeURIComponent setTimeout clearTimeout setInterval requestAnimationFrame
fetch console document window location history localStorage navigator alert confirm prompt
FormData FileReader Blob XMLHttpRequest Uint8Array Event KeyboardEvent CustomEvent Intl
structuredClone getComputedStyle CSS scrollTo focus btoa atob Map Set WeakMap Promise
Symbol Reflect Proxy globalThis Infinity NaN undefined null true false this arguments
eval Function String Object URL URLSearchParams AbortController TextDecoder TextEncoder
performance crypto queueMicrotask matchMedia scrollBy postMessage close open
'''.split())

calls = set()
for m in re.finditer(r'([A-Za-z_$][\w$]*)\s*\(', js):
    i = m.start()
    if i > 0 and (js[i - 1] in '.\w$]"\''):
        continue
    calls.add(m.group(1))
missing = sorted(c for c in calls if c not in declared and c not in globals_ok)
print('called-but-undeclared:', missing if missing else 'none')

# and every bare identifier reference that is never declared anywhere
used = set(re.findall(r'(?<![\.\w$"\'])\b([A-Za-z_$][\w$]*)\b', js))
missing2 = sorted(c for c in used if c not in declared and c not in globals_ok
                  and not re.match(r'^(if|else|for|while|switch|case|break|continue|return|function|var|let|const|typeof|instanceof|new|delete|in|of|try|catch|finally|throw|void|do|this|null|undefined|true|false)$', c))
print('referenced-but-undeclared (filtered by hand):', missing2)
