#!/usr/bin/env python3
"""Controlled PTY workload for the opt-in, isolated real-Herdr benchmark."""
import os
import sys
import tty

tty.setraw(sys.stdin.fileno())
os.write(sys.stdout.fileno(), b'\x1b[2J\x1b[HREADY')
line = 0
while True:
    text = os.read(sys.stdin.fileno(), 1)
    if not text:
        break
    if text == b'A':
        os.write(sys.stdout.fileno(), b'\x1b[?1049h\x1b[2J\x1b[HALTERNATE')
    elif text == b'N':
        os.write(sys.stdout.fileno(), b'\x1b[?1049l')
    elif text == b'L':
        os.write(sys.stdout.fileno(), f'line {line:04d} '.encode() + bytes([65 + line % 26]) * 80 + b'\r\n')
        line += 1
    elif text == b'S':
        # One burst exercises full frames, scrollback, coalescing and queue pressure.
        for index in range(2000):
            os.write(sys.stdout.fileno(), f'line {index:04d} '.encode() + b'.' * 200 + b'\r\n')
        os.write(sys.stdout.fileno(), b'SCROLL_DONE')
    else:
        os.write(sys.stdout.fileno(), b'\x1b[2J\x1b[H' + text)
