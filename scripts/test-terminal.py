#!/usr/bin/env python3
# Created by Sébastien DAGUIN
"""Exercise the real CLI in a pseudo-terminal without loading MLX."""
import fcntl
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time

executable = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/NoctisCLI").resolve()


def exercise(no_color):
    with tempfile.TemporaryDirectory(prefix="noctis-terminal-") as temporary:
        root = Path(temporary).resolve()
        other = root / "other"
        other.mkdir()
        primary, secondary = os.openpty()
        initial = termios.tcgetattr(secondary)
        fcntl.ioctl(secondary, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 36, 0, 0))
        environment = dict(os.environ, TERM="xterm-256color")
        environment.pop("NO_COLOR", None)
        if no_color:
            environment["NO_COLOR"] = ""
        child = subprocess.Popen([str(executable)], cwd=root, env=environment,
                                 stdin=secondary, stdout=secondary, stderr=secondary, start_new_session=True)
        output = bytearray()

        def receive(marker, start=0):
            deadline = time.monotonic() + 10
            while marker not in output[start:]:
                assert child.poll() is None, bytes(output).decode(errors="replace")
                assert time.monotonic() < deadline, bytes(output).decode(errors="replace")
                readable, _, _ = select.select([primary], [], [], 0.1)
                if readable:
                    output.extend(os.read(primary, 65536))

        def send(value, marker=b"\r\n  \xe2\x80\xba "):
            start = len(output)
            os.write(primary, value)
            receive(marker, start)
            if marker != b"\r\n  \xe2\x80\xba ":
                end = output.index(marker, start) + len(marker)
                receive(b"\r\n  \xe2\x80\xba ", end)

        try:
            receive(b"  \xe2\x80\xba ")
            # No question in these scenarios: /model and every other command must remain lazy.
            model = b"mlx-community/Ministral-3-14B-Instruct-2512-4bit"
            send(b"/model\n", model)
            send(b"\x1b[A\n", model)
            send("/modelé".encode() + b"\x7f\n", model)
            send(b"discard this\x15/model\n", model)
            send(b"draft\x03")
            send(("/workspace " + str(other) + "\n").encode(), b"[n]")
            send(b"n\n")
            send(b"/workspace\n", str(root).encode())
            send(("/workspace " + str(other) + "\n").encode(), b"[n]")
            send(b"y\n", str(other).encode())
            send(b"/workspace\n", str(other).encode())
            # Wait for raw input before testing Ctrl+D, rather than racing the preceding command.
            deadline = time.monotonic() + 5
            while termios.tcgetattr(secondary)[3] & termios.ICANON:
                assert time.monotonic() < deadline
                time.sleep(0.01)
            os.write(primary, b"\x04")
            assert child.wait(timeout=10) == 0
            restored = termios.tcgetattr(secondary)
            # PENDIN is maintained by the kernel when canonical input is re-enabled.
            restored[3] &= ~termios.PENDIN
            initial[3] &= ~termios.PENDIN
            assert restored == initial, "Terminal mode was not restored"
            assert output.count(model) >= 4
            assert b"Getting ready for our conversation" not in output
            assert "Je me prépare".encode() not in output
            assert (b"\x1b[1;33m" in output) != no_color
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            os.close(primary)
            os.close(secondary)


def exercise_redirected():
    child = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT)
    output = bytearray()
    try:
        deadline = time.monotonic() + 10
        while b"exit" not in output:
            assert time.monotonic() < deadline, "Redirected welcome was not flushed"
            readable, _, _ = select.select([child.stdout], [], [], 0.1)
            if readable:
                chunk = os.read(child.stdout.fileno(), 4096)
                assert chunk, bytes(output)
                output.extend(chunk)
        child.stdin.write(b"/model\n")
        child.stdin.flush()
        model = b"mlx-community/Ministral-3-14B-Instruct-2512-4bit"
        while model not in output:
            assert time.monotonic() < deadline, "Redirected command output was not flushed"
            readable, _, _ = select.select([child.stdout], [], [], 0.1)
            if readable:
                output.extend(os.read(child.stdout.fileno(), 4096))
        remaining, _ = child.communicate(input=b"/exit\n", timeout=10)
        output.extend(remaining)
        assert child.returncode == 0
        assert b"\x1b" not in output
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()


exercise_redirected()
exercise(no_color=False)
exercise(no_color=True)
print("Terminal: history, UTF-8 editing, Ctrl+C/Ctrl+D, confirmations, width and NO_COLOR: OK")
