#!/usr/bin/env python3
"""The DMG's build kit (Resources/build) from community/build-metal: our code only, no game code.

    python3 -I tools/dmg/kit.py <build dir> <kit dir>

lift/  xboxrecomp's Python lifter (tools/ without outputs and tests, templates/runtime), community tools/regen.sh,
       config/seed_functions.json and src/recomp_manual.c (regen reads it to skip manual functions)
py/    capstone (BSD) from the work/ venv: the lifter runs on the CLT's /usr/bin/python3 (3.9)
lib/   the runtime objects of nfsu2_recomp (main, manual overrides, apple host...) and the xboxrecomp
       static libraries + link.txt (the build's link line without the lifted chunks, paths as
       @KIT@ / @FW@ = the app's Frameworks)
build_game.sh lifts the player's default.xbe into gen/*.c, compiles it with CLT clang and links.
"""
import os
import re
import shlex
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
COM = os.path.join(ROOT, 'community')
VENV_CAPSTONE = os.path.join(ROOT, 'work', 'nfsu2-venv', 'lib', 'python3.9', 'site-packages', 'capstone')
build, kit = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
shutil.rmtree(kit, ignore_errors=True)
for d in ('lift', 'py', 'lib'):
    os.makedirs(os.path.join(kit, d))

ign = shutil.ignore_patterns('output', 'tests', 'conformance', '*.xbe', '__pycache__', '*.pyc', '.pytest_cache')
shutil.copytree(os.path.join(COM, 'xboxrecomp', 'tools'), os.path.join(kit, 'lift', 'tools'), ignore=ign)
shutil.copytree(os.path.join(COM, 'xboxrecomp', 'templates'), os.path.join(kit, 'lift', 'templates'), ignore=ign)
for rel in ('tools/regen.sh', 'config/seed_functions.json', 'src/recomp_manual.c'):
    dst = os.path.join(kit, 'lift', 'com', rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(os.path.join(COM, rel), dst)
shutil.copytree(VENV_CAPSTONE, os.path.join(kit, 'py', 'capstone'), ignore=ign)
lic = os.path.join(os.path.dirname(VENV_CAPSTONE), 'capstone-5.0.9.dist-info', 'LICENSE.TXT')
if os.path.exists(lic):
    shutil.copy2(lic, os.path.join(kit, 'py', 'capstone', 'LICENSE.TXT'))

cmd = subprocess.run(['ninja', '-C', build, '-t', 'commands', 'nfsu2_recomp'], capture_output=True,
                     text=True, check=True).stdout.strip().splitlines()[-1]
link = shlex.split(cmd.split('&&')[1])
args = link[link.index('-o') + 2:]
out, objs, seen = [], [], {}
for a in link[1:link.index('-o')] + args:
    if a.endswith('.o'):
        if '/gen/' in a:
            continue                      # the lifted chunks: built on the player's Mac
        name = a.split('nfsu2_recomp.dir/')[-1].replace('/', '_')
        shutil.copy2(os.path.join(build, a), os.path.join(kit, 'lib', name))
        objs.append('@KIT@/lib/' + name)
        continue
    if a.startswith('-Wl,-rpath') or a in ('-O2', '-O3', '-g', '-DNDEBUG', '-arch', 'arm64') \
            or a.startswith(('-mmacosx-version-min', '-Wl,-search_paths_first', '-Wl,-headerpad')):
        continue
    m = re.match(r'(-Wl,-force_load,)?(.+\.a)$', a)
    if m:
        p = m.group(2) if os.path.isabs(m.group(2)) else os.path.join(build, m.group(2))
        name = os.path.basename(p)
        if name not in seen:
            seen[name] = p
            shutil.copy2(p, os.path.join(kit, 'lib', name))
        a = (m.group(1) or '') + '@KIT@/lib/' + name
    elif a.endswith('.dylib'):
        a = '@FW@/' + os.path.basename(a)
    out.append(a)
open(os.path.join(kit, 'lib', 'link.txt'), 'w').write('\n'.join(objs + out) + '\n')
# no debug info: the objects' paths would name this Mac's folders
for f in os.listdir(os.path.join(kit, 'lib')):
    if f.endswith(('.a', '.o')):
        subprocess.run(['strip', '-S', os.path.join(kit, 'lib', f)], check=True, capture_output=True)
print(f'kit: {kit}: {len(objs)} objects, {len(seen)} libraries, {len(out)} link args')
