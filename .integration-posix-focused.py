import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CORE = (ROOT / "bin/mcp-sdk.sh").as_posix()
if ROOT.drive:
    WSL_CORE = "/mnt/" + ROOT.drive[0].lower() + ROOT.as_posix()[2:] + "/bin/mcp-sdk.sh"
else:
    WSL_CORE = CORE

SCRIPT = r'''
set -u
MCP_SDK_SOURCED=true
. "$1"
mcp_custom_method_handler() {
    case "$2" in
        fail)
            printf '%s\n' '{"jsonrpc":"2.0","id":999,"result":{"partial":true}}'
            return 42
            ;;
        succeed)
            json_response "$1" '{"ok":true}'
            ;;
        notify-fail)
            printf '%s\n' 'this notification output must be suppressed'
            return 43
            ;;
    esac
}
mcp_dispatch_single '{"jsonrpc":"1.0","method":"ping"}'
mcp_dispatch_single '{"jsonrpc":"2.0","params":{}}'
mcp_dispatch_single '{"jsonrpc":"2.0","method":42}'
mcp_dispatch_single '{"jsonrpc":"2.0","method":"notify-fail"}'
mcp_dispatch_single '{"jsonrpc":"2.0","id":"fail-é🙂","method":"fail"}'
mcp_dispatch_single '{"jsonrpc":"2.0","id":2,"method":"succeed"}'
mcp_dispatch_single '{"jsonrpc":"2.0","id":3,"method":"ping"}'
'''


def exercise(label, argv):
    completed = subprocess.run(argv + [SCRIPT, "sh", CORE if label == "git-bash" else WSL_CORE], capture_output=True, timeout=30)
    if completed.returncode != 0:
        raise AssertionError(f"{label}: exit {completed.returncode}: {completed.stderr.decode('utf-8', 'replace')}")
    try:
        lines = completed.stdout.decode("utf-8").splitlines()
        messages = [json.loads(line) for line in lines]
    except Exception as exc:
        raise AssertionError(f"{label}: invalid output {completed.stdout!r}: {exc}") from exc
    if len(messages) != 3:
        raise AssertionError(f"{label}: expected exactly three responses, got {messages!r}")
    failed, succeeded, ping = messages
    assert failed.get("id") == "fail-é🙂", (label, failed)
    assert failed.get("error", {}).get("code") == -32603, (label, failed)
    assert failed.get("error", {}).get("message") == "Internal error", (label, failed)
    assert "result" not in failed and failed.get("id") != 999, (label, failed)
    assert succeeded == {"jsonrpc": "2.0", "id": 2, "result": {"ok": True}}, (label, succeeded)
    assert ping == {"jsonrpc": "2.0", "id": 3, "result": {}}, (label, ping)
    print(f"POSIX_FOCUSED_OK {label} checks=9", flush=True)


def main():
    variants = [
        ("wsl-dash", ["wsl.exe", "-e", "dash", "-c"]),
        ("wsl-bash", ["wsl.exe", "-e", "bash", "-c"]),
    ]
    git_bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    if git_bash.exists():
        variants.append(("git-bash", [str(git_bash), "-c"]))
    failures = []
    for label, argv in variants:
        try:
            exercise(label, argv)
        except Exception as exc:
            failures.append((label, str(exc)))
            print(f"POSIX_FOCUSED_FAIL {label}: {exc}", file=sys.stderr, flush=True)
    if failures:
        return 1
    print(f"POSIX_FOCUSED_INTEGRATION_OK variants={len(variants)} checks={9 * len(variants)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
