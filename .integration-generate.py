import json
import os
import shlex
import shutil
import subprocess
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent
WORK = ROOT / ".verify-generate"
GIT_BASH = Path(r"C:\Program Files\Git\bin\bash.exe")
CHECKS = 0
VARIANTS = 0


def check(condition, message):
    global CHECKS
    CHECKS += 1
    if not condition:
        raise AssertionError(message)


def run(argv, timeout=60, input_bytes=None):
    return subprocess.run(
        [str(value) for value in argv],
        cwd=ROOT,
        input=input_bytes,
        capture_output=True,
        timeout=timeout,
    )


def decode(data):
    return data.decode("utf-8", "replace")


def windows_bash_path(path):
    resolved = Path(path).resolve()
    return "/" + resolved.drive[0].lower() + resolved.as_posix()[2:]


def wsl_path(path):
    return windows_bash_path(path).replace("/f/", "/mnt/f/", 1)


def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")


def generate_powershell(runtime, language, output):
    runner = WORK / "generate.ps1"
    completed = run([
        runtime,
        "-NoProfile",
        "-File",
        runner,
        "-SchemaPath",
        WORK / "schema.json",
        "-Language",
        language,
        "-OutputPath",
        output,
    ])
    check(
        completed.returncode == 0 and output.is_file() and output.stat().st_size > 0,
        f"{runtime} generator {language} failed: {decode(completed.stdout)} {decode(completed.stderr)}",
    )


def generate_posix(label, argv, root_path, language, output, windows_output):
    runner = PurePosixPath(output).parent / "generate-posix.sh"
    if not (WORK / "generate-posix.sh").exists():
        write(
            WORK / "generate-posix.sh",
            """#!/usr/bin/env sh
set -eu
root=$1
schema=$2
language=$3
output=$4
export PLUGIN_ROOT="$root"
export MCP_SDK_SOURCED=true
. "$root/bin/sdk-utils.sh"
sdk_generate_handler "$(cat "$schema")" "$language" > "$output"
""",
        )
    schema = PurePosixPath(output).parent / "schema.json"
    completed = run(argv + [runner, root_path, schema, language, output])
    check(
        completed.returncode == 0 and windows_output.is_file() and windows_output.stat().st_size > 0,
        f"{label} generator {language} failed: {decode(completed.stdout)} {decode(completed.stderr)}",
    )


def make_powershell_wrapper(handler):
    wrapper = WORK / "consumer.ps1"
    write(
        wrapper,
        """#Requires -Version 5.1
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$SdkArgs)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = $env:SHEBANG_TEST_ROOT
Import-Module (Join-Path $root 'bin/mcp-sdk.psm1') -Force -DisableNameChecking
. $env:SHEBANG_TEST_HANDLER
& (Join-Path $root 'bin/shebang-mcp-sdk.ps1') @SdkArgs
exit $LASTEXITCODE
""",
    )
    return wrapper


def make_posix_wrapper(handler, root, runtime):
    wrapper = WORK / f"consumer-{runtime}.sh"
    write(
        wrapper,
        f"""#!/usr/bin/env bash
set -eu
export PLUGIN_ROOT={shlex.quote(str(root))}
export MCP_SDK_SOURCED=true
. "$PLUGIN_ROOT/bin/shebang-mcp-sdk.sh"
. {shlex.quote(str(handler))}
case "${{1:-}}" in
    --stdio)
        export MCP_TRANSPORT=stdio
        mcp_main
        ;;
    --cli)
        shift
        case "${{1:-}}" in
            --list-tools) cli_list_tools ;;
            --call-tool) shift; cli_call_tool "$@" ;;
            *) printf 'invalid test CLI command\n' >&2; exit 2 ;;
        esac
        ;;
    *) printf 'invalid test mode\n' >&2; exit 2 ;;
esac
""",
    )
    return wrapper


REQUESTS = [
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "generated-test", "version": "1.0"},
        },
    },
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {
            "name": "echo_tool",
            "arguments": {"input": "héllo 世界", "flag": False, "count": 0, "empty": ""},
        },
    },
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "echo_tool", "arguments": {}}},
    {
        "jsonrpc": "2.0",
        "id": 5,
        "method": "tools/call",
        "params": {"name": "echo_tool", "arguments": {"input": None, "flag": False, "count": 0, "empty": ""}},
    },
    {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "echo_tool", "arguments": []}},
    {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "missing_tool", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "ECHO_TOOL", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 9, "method": "ping", "params": {}},
]


def exercise_stdio(label, argv, env):
    payload = b"".join(
        json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
        for request in REQUESTS
    )
    completed = run(argv + ["--stdio"], timeout=90, input_bytes=payload)
    check(
        completed.returncode == 0,
        f"{label} stdio exited {completed.returncode}: {decode(completed.stderr)}",
    )
    lines = [line for line in decode(completed.stdout).splitlines() if line.strip()]
    check(len(lines) == 9, f"{label} expected 9 responses, got {len(lines)}: {lines!r}; {decode(completed.stderr)}")
    messages = [json.loads(line) for line in lines]
    by_id = {message.get("id"): message for message in messages}
    check(set(by_id) == set(range(1, 10)), f"{label} response IDs differ: {by_id.keys()}")
    check(all(message.get("jsonrpc") == "2.0" for message in messages), f"{label} invalid JSON-RPC version")
    check("tools" in by_id[1].get("result", {}).get("capabilities", {}), f"{label} missing tools capability")
    check("resources" not in by_id[1]["result"]["capabilities"], f"{label} unexpectedly advertised resources")
    check("prompts" not in by_id[1]["result"]["capabilities"], f"{label} unexpectedly advertised prompts")

    tools = by_id[2].get("result", {}).get("tools", [])
    check([tool.get("name") for tool in tools] == ["echo_tool", "quote_tool"], f"{label} wrong catalog: {tools}")
    check(tools[0].get("description") == "Process café 世界 and user's data", f"{label} Unicode/apostrophe description changed")
    schema = tools[0].get("inputSchema", {})
    check(schema.get("type") == "object", f"{label} invalid input schema")
    check(schema.get("properties", {}).get("count", {}).get("type") == "number", f"{label} integer mapping changed")
    check(schema.get("properties", {}).get("flag", {}).get("type") == "boolean", f"{label} boolean mapping changed")
    check(set(schema.get("required", [])) == {"input", "flag", "count", "empty"}, f"{label} required list changed: {schema}")
    check(tools[1].get("description") == "MCP tool", f"{label} default description changed")

    success = by_id[3].get("result", {})
    check(success.get("isError") is False, f"{label} valid false/zero/empty arguments rejected: {by_id[3]}")
    check(success.get("content", [{}])[0].get("text") == "Tool echo_tool executed successfully", f"{label} success result changed")
    for request_id in (4, 5, 6):
        check(by_id[request_id].get("error", {}).get("code") == -32602, f"{label} id={request_id} expected -32602: {by_id[request_id]}")
    check("input" in by_id[4]["error"]["message"], f"{label} missing required name omitted")
    for request_id in (7, 8):
        check(by_id[request_id].get("error", {}).get("code") == -32601, f"{label} id={request_id} expected case-sensitive -32601")
    check(by_id[9].get("result") == {}, f"{label} recovery ping failed: {by_id[9]}")


def exercise_cli(label, argv, env, powershell):
    list_command = "--ListTools" if powershell else "--list-tools"
    call_command = "--CallTool" if powershell else "--call-tool"
    listed = run(argv + ["--cli", list_command], timeout=60)
    check(listed.returncode == 0, f"{label} CLI list failed: {decode(listed.stdout)} {decode(listed.stderr)}")
    list_output = decode(listed.stdout)
    check("echo_tool" in list_output and "quote_tool" in list_output, f"{label} CLI catalog missing: {list_output}")
    check("café 世界" in list_output and "user's data" in list_output, f"{label} CLI Unicode/apostrophe changed: {list_output}")

    arguments = json.dumps({"input": "héllo 世界", "flag": False, "count": 0, "empty": ""}, ensure_ascii=False)
    called = run(argv + ["--cli", call_command, "echo_tool", arguments], timeout=60)
    check(called.returncode == 0, f"{label} CLI call failed: {decode(called.stdout)} {decode(called.stderr)}")
    response = json.loads(decode(called.stdout))
    check(response.get("id") == 4 and response.get("result", {}).get("isError") is False, f"{label} invalid CLI call response: {response}")

    missing = run(argv + ["--cli", call_command, "echo_tool", "{}"], timeout=60)
    check(missing.returncode != 0, f"{label} CLI missing-required call unexpectedly succeeded")
    check("missing required" in (decode(missing.stdout) + decode(missing.stderr)).lower(), f"{label} CLI error was not actionable")
    invalid = run(argv + ["--cli", call_command, "echo_tool", "[1]"], timeout=60)
    check(invalid.returncode != 0, f"{label} CLI non-object arguments unexpectedly succeeded")


def exercise_generated_ps(handler, source_label):
    global VARIANTS
    for runtime in ("powershell", "pwsh"):
        label = f"{source_label}->{runtime}"
        wrapper = make_powershell_wrapper(handler)
        env = os.environ.copy()
        env["SHEBANG_TEST_ROOT"] = str(ROOT)
        env["SHEBANG_TEST_HANDLER"] = str(handler)
        argv = [runtime, "-NoProfile", "-File", wrapper]
        old_env = os.environ.copy()
        os.environ.update(env)
        try:
            exercise_stdio(label, argv, env)
            exercise_cli(label, argv, env, True)
        finally:
            os.environ.clear()
            os.environ.update(old_env)
        VARIANTS += 1
        print(f"GENERATED_CONSUMER_OK {label} checks={CHECKS}", flush=True)


def exercise_generated_bash(handler, source_label):
    global VARIANTS
    variants = [
        ("wsl-bash", ["wsl", "bash"], wsl_path(ROOT), wsl_path(handler)),
        ("git-bash", [GIT_BASH], windows_bash_path(ROOT), windows_bash_path(handler)),
    ]
    for runtime_label, prefix, root, bash_handler in variants:
        if runtime_label == "git-bash" and not GIT_BASH.is_file():
            continue
        label = f"{source_label}->{runtime_label}"
        wrapper = make_posix_wrapper(bash_handler, root, runtime_label)
        argv = prefix + ([wsl_path(wrapper)] if runtime_label == "wsl-bash" else [windows_bash_path(wrapper)])
        exercise_stdio(label, argv, os.environ.copy())
        exercise_cli(label, argv, os.environ.copy(), False)
        VARIANTS += 1
        print(f"GENERATED_CONSUMER_OK {label} checks={CHECKS}", flush=True)


def main():
    global VARIANTS
    if WORK.exists():
        shutil.rmtree(WORK)
    WORK.mkdir()
    schema = {
        "server": {"name": "generated-test", "version": "1.0"},
        "tools": [
            {
                "name": "echo_tool",
                "description": "Process café 世界 and user's data",
                "parameters": [
                    {"name": "input", "type": "string", "required": True},
                    {"name": "flag", "type": "boolean", "required": True},
                    {"name": "count", "type": "integer", "required": True},
                    {"name": "empty", "type": "string", "required": True},
                ],
            },
            {"name": "quote_tool"},
        ],
    }
    write(WORK / "schema.json", json.dumps(schema, ensure_ascii=False, indent=2))
    write(
        WORK / "generate.ps1",
        """#Requires -Version 5.1
param([string]$SchemaPath, [string]$Language, [string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'bin/sdk-utils.psm1') -Force -DisableNameChecking
$schema = [System.IO.File]::ReadAllText($SchemaPath, [System.Text.Encoding]::UTF8)
$source = sdk-generate-handler -Schema $schema -Language $Language
[System.IO.File]::WriteAllText($OutputPath, [string]$source, (New-Object System.Text.UTF8Encoding($false)))
""",
    )

    generated = []
    for runtime in ("powershell", "pwsh"):
        for language in ("pwsh", "bash"):
            output = WORK / f"{runtime}-{language}.{ 'ps1' if language == 'pwsh' else 'sh' }"
            generate_powershell(runtime, language, output)
            generated.append((f"{runtime}-generator", language, output))
            print(f"GENERATE_OK {runtime} {language}", flush=True)

    posix_generators = [
        ("wsl-dash", ["wsl", "dash"], PurePosixPath(wsl_path(ROOT)), PurePosixPath(wsl_path(WORK))),
        ("wsl-bash", ["wsl", "bash"], PurePosixPath(wsl_path(ROOT)), PurePosixPath(wsl_path(WORK))),
        ("git-bash", [GIT_BASH], PurePosixPath(windows_bash_path(ROOT)), PurePosixPath(windows_bash_path(WORK))),
    ]
    for label, argv, root, work in posix_generators:
        if label == "git-bash" and not GIT_BASH.is_file():
            continue
        for language in ("pwsh", "bash"):
            windows_output = WORK / f"{label}-{language}.{ 'ps1' if language == 'pwsh' else 'sh' }"
            output = work / windows_output.name
            generate_posix(label, argv, root, language, output, windows_output)
            generated.append((f"{label}-generator", language, windows_output))
            print(f"GENERATE_OK {label} {language}", flush=True)

    single = json.dumps({"name": "my_tool", "description": "Processes data"})
    write(WORK / "single.json", single)
    rejected = run([
        "powershell", "-NoProfile", "-File", WORK / "generate.ps1",
        "-SchemaPath", WORK / "single.json", "-Language", "pwsh", "-OutputPath", WORK / "invalid.ps1"
    ])
    check(rejected.returncode != 0 and not (WORK / "invalid.ps1").exists(), "PowerShell generator accepted a single tool object")
    command = f". {shlex.quote(wsl_path(ROOT / 'bin' / 'sdk-utils.sh'))}; sdk_generate_handler {shlex.quote(single)} bash"
    rejected = run(["wsl", "dash", "-c", command])
    check(rejected.returncode != 0, "POSIX generator accepted a single tool object")
    print("GENERATE_SCHEMA_VALIDATION_OK single-tool-object rejected by both implementations", flush=True)

    for source_label, language, output in generated:
        if language == "pwsh":
            exercise_generated_ps(output, source_label)
        else:
            exercise_generated_bash(output, source_label)

    shutil.rmtree(WORK)
    print(f"GENERATED_CONSUMER_INTEGRATION_OK variants={VARIANTS} checks={CHECKS}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"GENERATED_CONSUMER_FAIL {type(exc).__name__}: {exc}", flush=True)
        raise
