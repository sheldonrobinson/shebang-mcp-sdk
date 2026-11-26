import json
import os
import socket
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MAX_BODY = 4096
CHECKS = 0


def check(condition, message):
    global CHECKS
    CHECKS += 1
    if not condition:
        raise AssertionError(message)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def rpc(method, ident="__absent__", params=None):
    value = {"jsonrpc": "2.0", "method": method}
    if ident != "__absent__":
        value["id"] = ident
    if params is not None:
        value["params"] = params
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def raw_request(port, method="POST", body=b"", headers=None, path="/mcp", declared_length=None, extra_headers=None, shutdown=False, omit_content_length=False):
    header_lines = [f"{method} {path} HTTP/1.1", "Host: 127.0.0.1", "Connection: close"]
    supplied = dict(headers or {})
    if method == "POST":
        header_lines.append("Content-Type: application/json")
        if not omit_content_length:
            header_lines.append(f"Content-Length: {len(body) if declared_length is None else declared_length}")
    for name, value in supplied.items():
        header_lines.append(f"{name}: {value}")
    if extra_headers:
        header_lines.extend(extra_headers)
    wire = ("\r\n".join(header_lines) + "\r\n\r\n").encode("ascii") + body
    with socket.create_connection(("127.0.0.1", port), timeout=10) as sock:
        sock.settimeout(15)
        sock.sendall(wire)
        if shutdown:
            sock.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            try:
                chunk = sock.recv(65536)
            except ConnectionResetError:
                break
            if not chunk:
                break
            chunks.append(chunk)
    raw = b"".join(chunks)
    if os.environ.get("HTTP_TRACE"):
        print(f"RAW_TRACE {method} declared_length={declared_length!r} extra_headers={extra_headers!r} shutdown={shutdown!r} -> {raw!r}", flush=True)
    if not raw:
        return 0, {}, b"", raw
    head, separator, response_body = raw.partition(b"\r\n\r\n")
    if not separator:
        return 0, {}, b"", raw
    lines = head.split(b"\r\n")
    try:
        status = int(lines[0].split()[1])
    except Exception:
        return 0, {}, b"", raw
    response_headers = {}
    for line in lines[1:]:
        name, colon, value = line.partition(b":")
        if colon:
            response_headers[name.decode("ascii", "replace").lower()] = value.strip().decode("utf-8", "replace")
    return status, response_headers, response_body, raw


def post(port, body, session=None, accept="application/json", origin=None):
    headers = {"Accept": accept}
    if session is not None:
        headers["Mcp-Session-Id"] = session
    if origin is not None:
        headers["Origin"] = origin
    response = raw_request(port, body=body, headers=headers)
    if os.environ.get("HTTP_TRACE"):
        print(f"HTTP_TRACE {body!r} -> status={response[0]} body={response[2]!r}", flush=True)
    return response


def response_json(response):
    status, headers, body, raw = response
    try:
        return json.loads(body.decode("utf-8"))
    except Exception as exc:
        raise AssertionError(f"status={status} headers={headers} invalid JSON body={body!r} raw={raw!r}") from exc


def expect_rpc(response, status, ident, error=None, result="__absent__"):
    check(response[0] == status, f"expected HTTP {status}, got {response[0]} body={response[2]!r}")
    message = response_json(response)
    check(message.get("id") == ident, f"expected id {ident!r}, got {message!r}")
    if error is not None:
        check(message.get("error", {}).get("code") == error, f"expected error {error}, got {message!r}")
    if result != "__absent__":
        check(message.get("result") == result and "error" not in message, f"expected result {result!r}, got {message!r}")
    return message


class LiveServer:
    def __init__(self, label, argv, wrapper, port):
        self.label = label
        self.argv = [str(item) for item in argv]
        self.wrapper = wrapper
        self.port = port
        self.output = []
        self.errors = []
        self.proc = subprocess.Popen(self.argv, cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        threading.Thread(target=self._read, args=(self.proc.stdout, self.output), daemon=True).start()
        threading.Thread(target=self._read, args=(self.proc.stderr, self.errors), daemon=True).start()

    def _read(self, stream, target):
        try:
            for line in iter(stream.readline, b""):
                target.append(line)
        except Exception:
            pass

    def wait_ready(self):
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise AssertionError(f"{self.label}: server exited {self.proc.returncode}: {self.diagnostics()}")
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.25):
                    return
            except OSError:
                time.sleep(0.1)
        raise AssertionError(f"{self.label}: listener did not start: {self.diagnostics()}")

    def diagnostics(self):
        return (b"".join(self.output) + b"".join(self.errors)).decode("utf-8", "replace")

    def close(self):
        if self.proc.poll() is None:
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(self.proc.pid), "/T", "/F"], capture_output=True, timeout=10)
            else:
                self.proc.kill()
        try:
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()
        if os.environ.get("HTTP_KEEP_WRAPPERS"):
            print(f"HTTP_WRAPPER {self.label} {self.wrapper}", flush=True)
        else:
            try:
                self.wrapper.unlink()
            except OSError:
                pass


def powershell_wrapper(exe, port):
    token = uuid.uuid4().hex
    path = ROOT / f".http-live-{token}.ps1"
    module = str(ROOT / "bin/mcp-sdk.psm1").replace("'", "''")
    path.write_text(f'''param([int]$Port)
$ErrorActionPreference = 'Stop'
Import-Module '{module}' -Force -DisableNameChecking
function Invoke-McpCustomMethod {{
    param($Id, [string]$Method, $Params, [bool]$IsNotification)
    switch -CaseSensitive ($Method) {{
        'succeed' {{ return json-response -Id $Id -Result '{{}}' }}
        'result-false' {{ return json-response -Id $Id -Result $false }}
        'result-zero' {{ return json-response -Id $Id -Result 0 }}
        'result-null' {{ return json-response -Id $Id -Result 'null' }}
        'result-array' {{ return json-response -Id $Id -Result '[]' }}
        'fail' {{ Write-Output 'partial-output-that-must-be-discarded'; throw 'consumer failure' }}
        'fail-notify' {{ Write-Output 'partial-notification-output'; throw 'notification failure' }}
        default {{ return json-response -Id $Id -Error (mcp-error -Code -32601 -Message "Method not found: $Method") }}
    }}
}}
Start-McpServer -Transport 'streamable-http' -HostName '127.0.0.1' -Port $Port -Endpoint '/mcp' -MaxBodyBytes {MAX_BODY}
''', encoding="utf-8")
    argv = [exe, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path, "-Port", port]
    return LiveServer(f"{exe}-http", argv, path, port)


def posix_wrapper(shell, port):
    token = uuid.uuid4().hex
    path = ROOT / f".http-live-{token}.sh"
    wsl_root = "/mnt/" + ROOT.drive[0].lower() + ROOT.as_posix()[2:]
    wsl_path = wsl_root + "/" + path.name
    core = wsl_root + "/bin/mcp-sdk.sh"
    path.write_text(f'''#!/usr/bin/env sh
set -u
MCP_SDK_SOURCED=true
. '{core}'
mcp_custom_method_handler() {{
    case "$2" in
        succeed) json_response "$1" '{{}}' ;;
        result-false) json_response "$1" 'false' ;;
        result-zero) json_response "$1" '0' ;;
        result-null) json_response "$1" 'null' ;;
        result-array) json_response "$1" '[]' ;;
        fail) printf '%s\\n' 'partial-output-that-must-be-discarded'; return 42 ;;
        exit) printf '%s\\n' 'partial-output-before-exit'; exit 23 ;;
        fail-notify) printf '%s\\n' 'partial-notification-output'; return 43 ;;
        *) json_response "$1" '' "$(mcp_error -32601 "Method not found: $2")" ;;
    esac
}}
if [ "${{1:-}}" = '--http-worker' ]; then
    handle_http_request_stream
    exit 0
fi
export MCP_HTTP_MAX_BODY_BYTES={MAX_BODY}
mcp_streamable_http_server '{port}' '127.0.0.1'
''', encoding="utf-8", newline="\n")
    argv = ["wsl.exe", "-e", shell, wsl_path]
    return LiveServer(f"wsl-{shell}-http", argv, path, port)


def initialize(port):
    params = {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "socket-test", "version": "1.0"}}
    response = post(port, rpc("initialize", 1, params))
    message = expect_rpc(response, 200, 1)
    check(message.get("result", {}).get("protocolVersion") == "2025-03-26", f"initialize failed: {message}")
    session = response[1].get("mcp-session-id", "")
    check(bool(session), f"initialize returned no Mcp-Session-Id: {response[1]!r}")
    accepted = post(port, rpc("notifications/initialized"), session)
    check(accepted[0] == 202 and accepted[2] == b"", f"initialized notification was not empty 202: {accepted[:3]}")
    return session


def exercise(server):
    label = server.label
    port = server.port
    is_posix = label.startswith("wsl-")
    is_powershell = not is_posix
    session = initialize(port)
    session_header = {"Mcp-Session-Id": session}

    expect_rpc(post(port, rpc("ping", "p-é🙂"), session), 200, "p-é🙂", result={})
    for method, expected in (("result-false", False), ("result-zero", 0), ("result-null", None), ("result-array", []), ("succeed", {})):
        expect_rpc(post(port, rpc(method, method), session), 200, method, result=expected)

    huge = 987654321012345678901234567890
    failed = post(port, rpc("fail", huge), session)
    expect_rpc(failed, 200, huge, error=-32603)
    check(b"partial-output" not in failed[2] and failed[2].count(b'"jsonrpc"') == 1, f"failed consumer leaked/duplicated output: {failed[2]!r}")
    expect_rpc(post(port, rpc("succeed", "after-return"), session), 200, "after-return", result={})
    if is_posix:
        exited = post(port, rpc("exit", "exit-é"), session)
        expect_rpc(exited, 200, "exit-é", error=-32603)
        check(b"partial-output" not in exited[2] and exited[2].count(b'"jsonrpc"') == 1, f"exit leaked output: {exited[2]!r}")
        expect_rpc(post(port, rpc("ping", "after-exit"), session), 200, "after-exit", result={})

    failed_notification = post(port, rpc("fail-notify"), session)
    check(failed_notification[0] == 202 and failed_notification[2] == b"", f"failed notification response: {failed_notification[:3]}")
    expect_rpc(post(port, rpc("ping", "after-notification"), session), 200, "after-notification", result={})

    notification_request = post(port, rpc("notifications/initialized", 66), session)
    notification_message = response_json(notification_request)
    check(notification_request[0] == 200 and notification_message.get("id") == 66, f"ID-bearing notification route failed: {notification_request[:3]}")
    check(notification_message.get("error", {}).get("code") in (-32600, -32601), f"unexpected notification route error: {notification_message}")

    stale_request = post(port, rpc("ping", "stale-é"), "stale-session")
    expect_rpc(stale_request, 404, "stale-é", error=-32600)
    stale_notification = post(port, rpc("notifications/initialized"), "stale-session")
    check(stale_notification[0] == 404 and stale_notification[2] == b"", f"stale notification response: {stale_notification[:3]}")

    forbidden = post(port, rpc("ping", "forbidden"), session, origin="https://evil.example")
    check(forbidden[0] == 403, f"forbidden Origin was accepted: {forbidden[:3]}")
    expect_rpc(post(port, rpc("ping", "allowed"), session, origin=f"http://127.0.0.1:{port}"), 200, "allowed", result={})

    trailing = rpc("ping", "trailing-lf") + b"\n"
    expect_rpc(post(port, trailing, session), 200, "trailing-lf", result={})
    malformed = b'{"jsonrpc":"2.0","id":"\xe9","method":"ping"}'
    malformed_response = post(port, malformed, session)
    expect_rpc(malformed_response, 400, None, error=-32700)
    expect_rpc(post(port, rpc("ping", "after-malformed"), session), 200, "after-malformed", result={})

    get_sse = raw_request(port, "GET", headers={"Accept": "text/event-stream", **session_header})
    check(get_sse[0] == 200 and get_sse[1].get("content-type", "").startswith("text/event-stream") and b"stream open" in get_sse[2], f"GET SSE failed: {get_sse[:3]}")
    get_plain = raw_request(port, "GET", headers={"Accept": "application/json", **session_header})
    check(get_plain[0] == 405, f"plain GET was not rejected: {get_plain[:3]}")
    post_sse = post(port, rpc("ping", "sse-post"), session, accept="text/event-stream")
    check(post_sse[0] == 200 and post_sse[1].get("content-type", "").startswith("text/event-stream") and b'data: {"jsonrpc":"2.0"' in post_sse[2], f"POST SSE failed: {post_sse[:3]}")

    exact = rpc("ping", "exact-limit")
    exact += b" " * (MAX_BODY - len(exact))
    expect_rpc(post(port, exact, session), 200, "exact-limit", result={})
    oversize = raw_request(port, body=b"", headers={"Accept": "application/json", **session_header}, declared_length=MAX_BODY + 1)
    check(oversize[0] == 413, f"oversize declaration was not rejected: {oversize[:3]}")

    duplicate_body = rpc("ping", "duplicate")
    duplicate = raw_request(port, body=duplicate_body, headers={"Accept": "application/json", **session_header}, extra_headers=[f"Content-Length: {len(duplicate_body)}"])
    if is_powershell and duplicate[0] == 200:
        # Windows HTTP.sys may normalize repeated identical Content-Length fields
        # into one valid value before HttpListener exposes the request (RFC 9110
        # permits that normalization). Conflicting values must still be rejected.
        expect_rpc(duplicate, 200, "duplicate", result={})
    else:
        check(duplicate[0] == 400, f"duplicate Content-Length was accepted: {duplicate[:3]}")
    conflicting = raw_request(port, body=duplicate_body, headers={"Accept": "application/json", **session_header}, extra_headers=[f"Content-Length: {len(duplicate_body) + 1}"], shutdown=True)
    check(conflicting[0] == 400, f"conflicting Content-Length values were accepted: {conflicting[:3]}")

    truncated_body = rpc("ping", "truncated")
    truncated = raw_request(port, body=truncated_body, headers={"Accept": "application/json", **session_header}, declared_length=len(truncated_body) + 10, shutdown=True)
    check(truncated[0] == 400, f"truncated body was accepted: {truncated[:3]}")
    expect_rpc(post(port, rpc("ping", "after-framing"), session), 200, "after-framing", result={})

    if is_powershell:
        chunk_body = rpc("ping", "chunked")
        chunk_wire = f"{len(chunk_body):X}\r\n".encode("ascii") + chunk_body + b"\r\n0\r\n\r\n"
        chunked = raw_request(port, body=chunk_wire, headers={"Accept": "application/json", "Transfer-Encoding": "chunked", **session_header}, omit_content_length=True)
        expect_rpc(chunked, 200, "chunked", result={})
        ambiguous_body = rpc("ping", "ambiguous-chunked")
        ambiguous_wire = f"{len(ambiguous_body):X}\r\n".encode("ascii") + ambiguous_body + b"\r\n0\r\n\r\n"
        ambiguous = raw_request(port, body=ambiguous_wire, headers={"Accept": "application/json", "Transfer-Encoding": "chunked", **session_header})
        check(ambiguous[0] == 400, f"ambiguous Content-Length plus Transfer-Encoding was accepted: {ambiguous[:3]}")
        second = initialize(port)
        expect_rpc(post(port, rpc("ping", "session-a"), session), 200, "session-a", result={})
        expect_rpc(post(port, rpc("ping", "session-b"), second), 200, "session-b", result={})
        deleted_second = raw_request(port, "DELETE", headers={"Mcp-Session-Id": second})
        check(deleted_second[0] == 200, f"DELETE second session failed: {deleted_second[:3]}")
        expect_rpc(post(port, rpc("ping", "deleted-b"), second), 404, "deleted-b", error=-32600)
        expect_rpc(post(port, rpc("ping", "surviving-a"), session), 200, "surviving-a", result={})

    deleted = raw_request(port, "DELETE", headers={"Mcp-Session-Id": session})
    check(deleted[0] == 200, f"DELETE failed: {deleted[:3]}")
    expect_rpc(post(port, rpc("ping", "after-delete"), session), 404, "after-delete", error=-32600)
    check(server.proc.poll() is None, f"listener exited during matrix: {server.diagnostics()}")
    print(f"HTTP_LIVE_OK {label} checks={CHECKS}", flush=True)


def main():
    global CHECKS
    failures = []
    variants = []
    for exe in ("powershell", "pwsh"):
        port = free_port()
        try:
            variants.append(powershell_wrapper(exe, port))
        except Exception as exc:
            failures.append((f"{exe}-http-start", str(exc)))
    for shell in ("dash", "bash"):
        port = free_port()
        try:
            variants.append(posix_wrapper(shell, port))
        except Exception as exc:
            failures.append((f"wsl-{shell}-http-start", str(exc)))
    for server in variants:
        if os.environ.get("HTTP_ONLY") and os.environ["HTTP_ONLY"] not in server.label:
            server.close()
            continue
        CHECKS = 0
        try:
            server.wait_ready()
            exercise(server)
        except Exception as exc:
            failures.append((server.label, str(exc)))
            print(f"HTTP_LIVE_FAIL {server.label}: {exc}\n{server.diagnostics()}", file=sys.stderr, flush=True)
        finally:
            server.close()
    if failures:
        print(json.dumps(failures, indent=2), file=sys.stderr)
        return 1
    print(f"HTTP_LIVE_INTEGRATION_OK variants={len(variants)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
