#!/usr/bin/env python3
"""Exact-match replace in a source file, preserving its CRLF/LF line endings.

usage: crlf_edit.py FILE OLD_FILE NEW_FILE   (OLD/NEW given as LF text files)
"""
import sys
path, old_p, new_p = sys.argv[1:4]
raw = open(path, newline='').read()
crlf = '\r\n' in raw
text = raw.replace('\r\n', '\n')
old = open(old_p).read()
new = open(new_p).read()
n = text.count(old)
if n != 1:
    sys.exit(f"{path}: expected 1 match, found {n}")
text = text.replace(old, new)
if crlf:
    text = text.replace('\n', '\r\n')
open(path, 'w', newline='').write(text)
print(f"{path}: replaced ({'CRLF' if crlf else 'LF'})")
