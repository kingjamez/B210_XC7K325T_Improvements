#!/usr/bin/env python3
"""Generate black-box stubs for vendor primitives so Icarus can elaborate the
full design (connectivity / port-name check only, not simulation).

usage: gen_stubs.py OUT.v MODULE [MODULE ...] -- SOURCE.v [SOURCE.v ...]
"""
import re, sys
args = sys.argv[1:]
out, rest = args[0], args[1:]
sep = rest.index('--')
mods, srcs = rest[:sep], rest[sep + 1:]
text = ''
for f in srcs:
    text += re.sub(r'//[^\n]*', '', open(f, errors='replace').read())
text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
with open(out, 'w') as fo:
    fo.write('// Auto-generated black-box stubs. Do not use for simulation.\n')
    for m in mods:
        params, ports = set(), set()
        for inst in re.finditer(r'\b%s\b\s*(#\s*\((.*?)\)\s*)?\w+\s*\((.*?)\)\s*;' % re.escape(m), text, re.S):
            params |= set(re.findall(r'\.(\w+)\s*\(', inst.group(2) or ''))
            ports |= set(re.findall(r'\.(\w+)\s*\(', inst.group(3)))
        fo.write('module %s %s(%s);\n' % (
            m, ('#(' + ', '.join('parameter %s = 0' % p for p in sorted(params)) + ') ') if params else '',
            ', '.join(sorted(ports))))
        for p in sorted(ports):
            fo.write('  input [511:0] %s;\n' % p)
        fo.write('endmodule\n\n')
