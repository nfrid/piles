#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/scripts/benchmark.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/piles-benchmark-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Record AppleScript calls without opening or closing real Terminal windows.
osascript() {
    local script
    script=$(cat)
    if [[ "$script" == *"close every window"* || "$script" == *"close front window"* ]]; then
        echo "FAIL: benchmark tried to close an unrelated Terminal window" >&2
        return 1
    fi
    if [[ $# -eq 2 ]]; then
        printf '%s\n' "$script" > "$tmp/open.applescript"
        local id
        read -r id < "$tmp/next-id"
        printf '%s\n' "$((id + 1))" > "$tmp/next-id"
        printf '%s\n' "$id"
    elif [[ $# -eq 3 ]]; then
        [[ "$3" == "$WINDOW_MARKER" ]] || return 1
        printf '%s\n' "$script" > "$tmp/close.applescript"
        printf '%s\n' "$2" >> "$tmp/closed"
    else
        return 1
    fi
}
sleep() { :; }

printf '41\n' > "$tmp/next-id"
TRACKED_WINDOWS="$tmp/windows"
WINDOW_MARKER="piles-benchmark-test"
WORKLOAD_PID=""
open_windows 2
[[ $(tr '\n' ' ' < "$TRACKED_WINDOWS") == "41 42 " ]] || {
    echo "FAIL: benchmark did not record its created windows" >&2
    exit 1
}
cleanup_benchmark
[[ $(tr '\n' ' ' < "$tmp/closed") == "41 42 " ]] || {
    echo "FAIL: cleanup did not target only recorded windows" >&2
    exit 1
}
[[ ! -e "$tmp/windows" ]] || { echo "FAIL: cleanup left its tracking file" >&2; exit 1; }
cleanup_benchmark
[[ $(wc -l < "$tmp/closed" | tr -d ' ') == 2 ]] || {
    echo "FAIL: repeated cleanup closed windows again" >&2
    exit 1
}
# Compile, but never execute, the scripts against Terminal's scripting dictionary.
osacompile -o "$tmp/open.scpt" "$tmp/open.applescript" >/dev/null
osacompile -o "$tmp/close.scpt" "$tmp/close.applescript" >/dev/null
printf 'benchmark script tests passed\n'
