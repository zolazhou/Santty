#!/usr/bin/env python3
"""Owned headless nvim: file existence is not a writefile-completion ACK.
No PTY/Santty/Herdr, delays, edited wire bytes or existing editor instances.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

executable = shutil.which("nvim")
if not executable:
    raise SystemExit("nvim is required for this independent observation")
observed = {"empty_at_existence": 0, "complete_at_existence": 0}
with tempfile.TemporaryDirectory(prefix="santty-nvim-writefile-") as directory:
    root = Path(directory)
    environment = {key: value for key, value in os.environ.items() if key in {"PATH", "LANG", "LC_ALL", "LC_CTYPE"}}
    environment.update({"HOME": directory, "XDG_CONFIG_HOME": directory, "XDG_STATE_HOME": directory, "XDG_DATA_HOME": directory})
    for i in range(64):
        result = root / f"result-{i}"
        command = "call writefile(['command-executed'], '" + str(result).replace("'", "''") + "')"
        process = subprocess.Popen([executable, "--clean", "--headless", "-c", command, "-c", "qa!"],
                                   env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 5
            while not result.exists():
                if time.monotonic() > deadline:
                    raise RuntimeError("owned nvim did not create its result")
            first = result.read_bytes()
            if first == b"": observed["empty_at_existence"] += 1
            elif first == b"command-executed\n": observed["complete_at_existence"] += 1
            else: raise RuntimeError(f"unexpected result bytes: {first!r}")
            if process.wait(timeout=5) != 0 or result.read_bytes() != b"command-executed\n":
                raise RuntimeError("owned command failed to complete exactly")
        finally:
            if process.poll() is None:
                process.terminate()  # Popen-owned live child, never a cached external PID
                process.wait(timeout=5)
print(observed)
print("Required ACK: exact result contents; existence alone can precede write completion.")
