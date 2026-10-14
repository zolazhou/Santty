#!/usr/bin/env python3
"""Exercise the SSH stdio boundary against an isolated Herdr socket fixture."""
import os
from pathlib import Path
import socket
import sys
import threading

arguments = sys.argv[1:]
assert "-T" in arguments and "-C" in arguments
assert "BatchMode=yes" in arguments and "StrictHostKeyChecking=yes" in arguments
target, command = arguments[-2:]
assert "remote-client-bridge" in command or "remote-api-bridge" in command
path = Path(target)
if "remote-client-bridge" in command:
    path = path.with_name(path.stem + "-client.sock")

with socket.socket(socket.AF_UNIX) as stream:
    stream.connect(str(path))
    os.write(1, b"remote login banner\r\nherdr-remote-output-ready:1\r\n")

    def upload():
        try:
            while data := os.read(0, 65536):
                stream.sendall(data)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            try:
                stream.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    threading.Thread(target=upload, daemon=True).start()
    try:
        while data := stream.recv(65536):
            while data:
                data = data[os.write(1, data):]
    except (BrokenPipeError, ConnectionResetError):
        pass
