#!/usr/bin/env python3
"""check_chunk.py NN : validate work/loc/uk_NN.tsv against chunk_NN.tsv (tokens, ^, %, charset, length)."""
import sys, re, os
here = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'work', 'loc')
n = sys.argv[1]
src = [l.rstrip('\n').split('\t', 2) for l in open(os.path.join(here, 'chunk_%s.tsv' % n), encoding='utf-8')]
out_path = os.path.join(here, 'uk_%s.tsv' % n)
if not os.path.exists(out_path): print('missing', out_path); sys.exit(1)
uk = {}
bad = []
for i, l in enumerate(open(out_path, encoding='utf-8')):
    l = l.rstrip('\n')
    if not l: continue
    p = l.split('\t', 1)
    if len(p) != 2 or not p[0].isdigit(): bad.append('line %d: not id<TAB>text' % (i + 1)); continue
    if p[0] in uk: bad.append('id %s twice' % p[0])
    uk[p[0]] = p[1]
ok = set('АБВГҐДЕЄЖЗИІЇЙКЛМНОПРСТУФХЦЧШЩЬЮЯабвгґдеєжзиіїйклмнопрстуфхцчшщьюя’—«»™®©…')
def toks(s): return re.findall(r'\$[A-Za-z0-9_]+\$|%[-0-9.]*[a-zA-Z]', s)
for k, lab, en in src:
    if k not in uk: bad.append('id %s missing' % k); continue
    u = uk[k]
    en_c = re.sub(r'[\x80-\x9f]|Â', '', en)
    if toks(en) != toks(u): bad.append('id %s tokens differ: %s vs %s' % (k, toks(en), toks(u)))
    if en.count('^') != u.count('^'): bad.append('id %s ^ count %d vs %d' % (k, en.count('^'), u.count('^')))
    for c in u:
        if not (32 <= ord(c) < 127 or c in ok): bad.append('id %s bad char %r' % (k, c)); break
    if re.search('[ёыэъЁЫЭЪ]', u): bad.append('id %s has ё/ы/э/ъ' % k)
    if len(en_c) <= 30 and len(u) > max(len(en_c) * 1.25, len(en_c) + 4):
        bad.append('id %s too long (%d vs %d): %s' % (k, len(u), len(en_c), u))
extra = set(uk) - {k for k, _, _ in src}
if extra: bad.append('unknown ids: %s' % sorted(extra)[:10])
if bad:
    print('%d problems' % len(bad)); print('\n'.join(bad[:80])); sys.exit(1)
print('OK %d' % len(uk))
