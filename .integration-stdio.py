import json
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CHECKS = 0


def check(condition, message):
    global CHECKS
    CHECKS += 1
    if not condition:
        raise AssertionError(message)


class Server:
    def __init__(self, label, argv):
        self.label = label
        self.argv = [str(a) for a in argv]
        self.lines = queue.Queue()
        self.stderr = []
        self.proc = subprocess.Popen(
            self.argv,
            cwd=ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self.reader = threading.Thread(target=self._read_stdout, daemon=True)
        self.reader.start()
        self.errors = threading.Thread(target=self._read_stderr, daemon=True)
        self.errors.start()

    def _read_stdout(self):
        try:
            for line in iter(self.proc.stdout.readline, b""):
                self.lines.put(line)
        except Exception as exc:
            self.lines.put(exc)

    def _read_stderr(self):
        try:
            for line in iter(self.proc.stderr.readline, b""):
                self.stderr.append(line)
        except Exception:
            pass

    def send(self, value):
        payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
        self.proc.stdin.write(payload)
        self.proc.stdin.flush()

    def receive(self, expected_id, timeout=12):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(
                    f"{self.label}: timed out waiting for id={expected_id!r} while stdin is open; "
                    f"exit={self.proc.poll()} stderr={b''.join(self.stderr).decode('utf-8', 'replace')}"
                )
            try:
                line = self.lines.get(timeout=min(remaining, 0.25))
            except queue.Empty:
                if self.proc.poll() is not None and self.lines.empty():
                    raise AssertionError(
                        f"{self.label}: server exited {self.proc.returncode}; "
                        f"stderr={b''.join(self.stderr).decode('utf-8', 'replace')}"
                    )
                continue
            if isinstance(line, Exception):
                raise AssertionError(f"{self.label}: stdout reader failed: {line}")
            if not line.strip():
                continue
            try:
                message = json.loads(line.decode("utf-8"))
            except Exception as exc:
                raise AssertionError(f"{self.label}: non-JSON/invalid UTF-8 stdout {line!r}: {exc}")
            if message.get("id") != expected_id:
                raise AssertionError(f"{self.label}: expected id {expected_id!r}, got {message!r}")
            return message

    def close(self):
        if self.proc.poll() is None:
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(self.proc.pid), "/T", "/F"], capture_output=True)
            else:
                self.proc.kill()
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        self.proc.wait(timeout=10)


def request(method, ident, params=None):
    value = {"jsonrpc": "2.0", "id": ident, "method": method}
    if params is not None:
        value["params"] = params
    return value


def exercise(label, argv):
    server = Server(label, argv)
    try:
        server.send(request("initialize", 1, {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "stdio-integration", "version": "1.0"},
        }))
        init = server.receive(1)
        check(init.get("jsonrpc") == "2.0" and "result" in init, f"{label}: initialize failed: {init}")
        check(server.proc.poll() is None, f"{label}: exited after initialize")

        server.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        server.send(request("ping", 2))
        ping = server.receive(2)
        check(ping.get("result") == {}, f"{label}: notification was not silent or ping failed: {ping}")

        server.send(request("tools/list", 3, {}))
        listed = server.receive(3)
        check(listed.get("result", {}).get("tools") == [], f"{label}: tools/list failed: {listed}")

        server.send(request("tools/call", "工具-🚀", {"name": "missing-工具-🚀", "arguments": {}}))
        called = server.receive("工具-🚀")
        check(called.get("error", {}).get("code") == -32601, f"{label}: tools/call error failed: {called}")
        check("missing-工具-🚀" in called.get("error", {}).get("message", ""), f"{label}: UTF-8 tool name corrupted: {called}")

        huge = 123456789012345678901234567890
        server.send(request("ping", huge))
        check(server.receive(huge).get("id") == huge, f"{label}: large numeric ID was not preserved")

        server.send(request("PING", 5))
        check(server.receive(5).get("error", {}).get("code") == -32601, f"{label}: method dispatch is not case-sensitive")

        server.send(request("ping", 6))
        check(server.receive(6).get("result") == {}, f"{label}: server did not survive prior requests")
        check(server.proc.poll() is None, f"{label}: server exited before stdin EOF")
        print(f"STDIO_OK {label} checks={CHECKS}", flush=True)
    finally:
        server.close()


def main():
    variants = []
    for exe in ("powershell", "pwsh"):
        base = [exe, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass"]
        variants.append((f"{exe}-direct", base + ["-File", ROOT / "bin/shebang-mcp-sdk.ps1", "--stdio"]))
        runner = "script-runner.ps1"
        variants.append((f"{exe}-{runner}", base + ["-File", ROOT / "bin" / runner, "--use-pwsh", "shebang-mcp-sdk", "--stdio"]))
    git_bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    if git_bash.exists():
        direct_sh = (ROOT / "bin/shebang-mcp-sdk.sh").as_posix()
        runner = (ROOT / "bin/script-runner").as_posix()
        runner_sh = (ROOT / "bin/script-runner.sh").as_posix()
        for exe in ("powershell", "pwsh"):
            variants.append((f"{exe}-runner-posix-handoff", [
                exe, "-NoLogo", "-NoProfile", "-File", ROOT / "bin/script-runner.ps1",
                "--use-sh", "shebang-mcp-sdk", "--stdio",
            ]))
        variants.extend([
            ("git-bash-direct", [git_bash, direct_sh, "--stdio"]),
            ("git-bash-runner", [git_bash, runner, "--use-sh", "shebang-mcp-sdk", "--stdio"]),
            ("git-bash-runner.sh", [git_bash, runner_sh, "--use-sh", "shebang-mcp-sdk", "--stdio"]),
            ("cmd-runner-pwsh", ["cmd.exe", "/d", "/c", ROOT / "bin/script-runner.cmd", "--use-pwsh", "shebang-mcp-sdk", "--stdio"]),
            ("cmd-runner-sh", ["cmd.exe", "/d", "/c", ROOT / "bin/script-runner.cmd", "--use-sh", "shebang-mcp-sdk", "--stdio"]),
        ])

    # Exercise a native POSIX runtime as well as Git Bash's Windows emulation.
    wsl_probe = subprocess.run(
        ["wsl.exe", "-e", "sh", "-lc", "command -v jq >/dev/null 2>&1"],
        capture_output=True,
        timeout=15,
    )
    if wsl_probe.returncode == 0 and ROOT.drive:
        wsl_root = "/mnt/" + ROOT.drive[0].lower() + ROOT.as_posix()[2:]
        for shell_name in ("sh", "bash"):
            variants.append((f"wsl-{shell_name}-direct", [
                "wsl.exe", "-e", shell_name, wsl_root + "/bin/shebang-mcp-sdk.sh", "--stdio",
            ]))
            variants.append((f"wsl-{shell_name}-runner", [
                "wsl.exe", "-e", shell_name, wsl_root + "/bin/script-runner",
                "--use-sh", "shebang-mcp-sdk", "--stdio",
            ]))
        wsl_pwsh = subprocess.run(
            ["wsl.exe", "-e", "sh", "-lc", "command -v pwsh >/dev/null 2>&1"],
            capture_output=True,
            timeout=15,
        )
        if wsl_pwsh.returncode == 0:
            variants.append(("wsl-sh-runner-pwsh-handoff", [
                "wsl.exe", "-e", "sh", wsl_root + "/bin/script-runner.sh",
                "--use-pwsh", "shebang-mcp-sdk", "--stdio",
            ]))

    failures = []
    for label, argv in variants:
        try:
            exercise(label, argv)
        except Exception as exc:
            failures.append((label, str(exc)))
            print(f"STDIO_FAIL {label}: {exc}", file=sys.stderr, flush=True)
    if failures:
        print(json.dumps(failures, indent=2), file=sys.stderr)
        return 1
    print(f"STDIO_INTEGRATION_OK variants={len(variants)} checks={CHECKS}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
