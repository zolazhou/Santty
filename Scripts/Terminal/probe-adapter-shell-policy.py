#!/usr/bin/env python3
"""Independent owned shell controls; no inherited environment or user profile."""
import subprocess

original = r'''if [ -z \"${SANTTY_CONTROL_SOCKET+x}\" ]; then printf ABSENT; else printf PRESENT; fi'''
correct = r'''if [ -z "${SANTTY_CONTROL_SOCKET+x}" ]; then printf ABSENT; else printf PRESENT; fi'''

def run(command, present=False):
    environment = {"PATH": "/usr/bin:/bin"}
    if present:
        environment["SANTTY_CONTROL_SOCKET"] = "/tmp/santty-owned-literal-control.sock"
    return subprocess.check_output(["/bin/sh", "-c", command], env=environment, text=True)

assert run(original) == "PRESENT"  # Original false premise: escaped quotes are literals.
assert run(correct) == "ABSENT"
assert run(correct, present=True) == "PRESENT"
print("ORIGINAL escaped-quote check: absent variable falsely reported PRESENT")
print("Proper shell quoting: absent=ABSENT present=PRESENT")
