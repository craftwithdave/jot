#!/usr/bin/env python3
# Packs <dir>/icon_<px>.png into ../../Resources/AppIcon.icns.  Usage: python3 mkicns.py [dir]
# dir defaults to alt/paper (the chosen design, from alt.js); png = render.js (linked notes, not used).
# macOS reads PNG data inside .icns directly, so no iconutil (Mac-only) is needed.
import os, struct, sys

D = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(D, sys.argv[1] if len(sys.argv) > 1 else 'alt/paper')
OUT = os.path.join(D, '..', '..', 'Resources', 'AppIcon.icns')
# icns type -> pixel size (16/32/128/256/512 pt at 1x and 2x)
TYPES = [('icp4', 16), ('icp5', 32), ('icp6', 64), ('ic07', 128), ('ic08', 256), ('ic09', 512),
         ('ic10', 1024), ('ic11', 32), ('ic12', 64), ('ic13', 256), ('ic14', 512)]

chunks = b''
for t, px in TYPES:
    png = open(os.path.join(SRC, f'icon_{px}.png'), 'rb').read()
    w, h = struct.unpack('>II', png[16:24])
    assert png[:8] == b'\x89PNG\r\n\x1a\n' and (w, h) == (px, px), f'{t}: bad png {w}x{h}'
    chunks += t.encode() + struct.pack('>I', 8 + len(png)) + png
open(OUT, 'wb').write(b'icns' + struct.pack('>I', 8 + len(chunks)) + chunks)
print(f'wrote {os.path.normpath(OUT)} ({8 + len(chunks)} bytes, {len(TYPES)} sizes)')
