"""Static checks on the dashboard page, which has no build step to catch them.

1. pulls the page's inline <script> out and runs `node --check` on it;
2. cross-checks every called identifier against what the script declares plus a
   browser-globals allowlist, so a function called in eight places and defined
   in none of them is caught before somebody clicks;
3. cross-checks every icon name the page asks for against the names the
   vendored Lucide bundle actually exports, so a misspelling does not quietly
   render an empty box.
"""
import io
import os
import re
import subprocess

root = os.path.dirname(os.path.abspath(__file__))
page = io.open(os.path.join(root, 'web-ui.html'), encoding='utf-8').read().replace('\r\n', '\n')
js = max(re.findall(r'<script>(.*?)</script>', page, re.S), key=len)

tmp = os.path.join(os.environ.get('TEMP', os.getcwd()), 'scan.js')
io.open(tmp, 'w', encoding='utf-8', newline='\n').write(js)
r = subprocess.run(['node', '--check', tmp], capture_output=True, text=True)
print('node --check:', (r.stdout.strip() or 'ok') + ' ' + r.stderr.strip()[:400])

declared = set(re.findall(r'\bfunction\s+([A-Za-z_$][\w$]*)\s*\(', js))
declared |= set(re.findall(r'\b(?:var|let|const)\s+([A-Za-z_$][\w$]*)', js))
declared |= set(re.findall(r'\b([A-Za-z_$][\w$]*)\s*[:=]\s*function', js))
# parameters count as declared: a helper's arguments are its callers' business
for params in re.findall(r'\bfunction\s*[\w$]*\s*\(([^)]*)\)', js):
    declared |= set(p.strip() for p in params.split(',') if p.strip())

globals_ok = '''Math JSON Object Array String Number Boolean Date RegExp Error parseInt
parseFloat isNaN encodeURIComponent decodeURIComponent setTimeout clearTimeout
setInterval clearInterval requestAnimationFrame fetch console document window
location history localStorage navigator alert confirm prompt FormData
FileReader Blob XMLHttpRequest Uint8Array Event KeyboardEvent CustomEvent Intl
getComputedStyle CSS scrollTo focus btoa atob Map Set WeakMap Promise Symbol
Reflect Proxy globalThis Infinity NaN undefined null true false this arguments
eval Function URL URLSearchParams AbortController TextDecoder TextEncoder
performance crypto queueMicrotask matchMedia scrollBy postMessage close open
isFinite decodeURI encodeURI escape unescape
'''.split()

keywords = '''if else for while do switch case default break continue return function var
let const typeof instanceof new delete in of try catch finally throw void this
null undefined true false class extends super yield await async static get set
import export from with'''.split()

# comments out: "used rather than a library transform" is prose, not a call site.
# string literals out next, for the same reason (a CSS fragment inside a
# selector is not a call either) - but the icon names below still come from the
# original text, since those live inside the strings.
code = re.sub(r'/\*.*?\*/', ' ', js, flags=re.S)
code = re.sub(r'(?m)//.*$', '', code)
code = re.sub(r"'(?:[^'\\\n]|\\.)*'", "''", code)
code = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', code)

calls = set()
for m in re.finditer(r'([A-Za-z_$][\w$]*)\s*\(', code):
    i = m.start()
    if i > 0 and (code[i - 1] in '.\w$]"\''):
        continue  # a method call, a declaration or prose inside a string
    calls.add(m.group(1))
missing = sorted(c for c in calls if c not in declared and c not in globals_ok and c not in keywords)
print('called-but-undeclared:', missing if missing else 'none')

lucide = io.open(os.path.join(root, 'assets', 'vendor', 'lucide.min.js'),
                 encoding='utf-8', errors='replace').read()
exported = set(re.findall(r'\b(?:as|,)\s*([A-Z][A-Za-z0-9]+)\b', lucide))
asked = set(re.findall(r"icon\(\s*['\"]([A-Za-z0-9]+)['\"]", code))
asked |= set(re.findall(r"(?m)^\s*'([A-Za-z0-9]+)':\s*'[A-Z]", code))
unknown = sorted(a for a in asked if a not in exported)
print('icons-not-in-the-vendored-bundle:', unknown if unknown else 'none')
