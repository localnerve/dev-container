#!/usr/bin/env bash
# =============================================================================
# update-chrome-seccomp.sh
#
# Merges Chromium zygote/sandbox syscalls into a Docker default seccomp
# profile, producing chrome.json with deny-by-default (SCMP_ACT_ERRNO).
#
# Does not automatically update the local copy of seccomp docker defaults.
# To do this manually:
#   curl -fsSL https://raw.githubusercontent.com/moby/profiles/refs/heads/main/seccomp/default.json -o ./seccomp/docker-default.json
#
# The Github action `update-seccomp-profile.yml` updates the local copy of
# the docker default seccomp automatically if the remote changes or forced from the workflow dispatch button.
#
# Usage:
#   ./update-chrome-seccomp.sh [--input <file>] [--out <file>] [--dry-run]
#
# Options:
#   --input <file>  Path to Docker default seccomp profile JSON.
#                   If omitted, downloads from moby/profiles automatically.
#   --out <file>    Output path for merged chrome.json (default: chrome.json)
#   --dry-run       Preview changes without writing output file
# =============================================================================
set -euo pipefail

INPUT_FILE=""
OUTPUT="chrome.json"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input)   INPUT_FILE="$2"; shift 2 ;;
        --out)     OUTPUT="$2";           shift 2 ;;
        --dry-run) DRY_RUN=true;          shift ;;
        *)         echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is required (stdlib json module only, no pip needed)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Obtain the Docker default seccomp profile
# ---------------------------------------------------------------------------
TMPFILE=""
CREATED_TMPFILE=false

cleanup() { 
    # Only delete if we actually created a temporary file ourselves.
    # Never delete files passed via --input (they belong to the repo).
    if $CREATED_TMPFILE && [ -n "$TMPFILE" ]; then 
        rm -f "$TMPFILE"
    fi
}
trap cleanup EXIT

if [[ -n "$INPUT_FILE" ]]; then
    if [[ ! -f "$INPUT_FILE" ]]; then
        echo "ERROR: Input file not found: $INPUT_FILE" >&2
        exit 1
    fi
    TMPFILE="$INPUT_FILE"
    echo "→ Using local Docker default profile: $INPUT_FILE"
else
    # Download from moby/profiles
    PROFILE_URL="https://raw.githubusercontent.com/moby/profiles/refs/heads/main/seccomp/default.json"
    TMPFILE=$(mktemp /tmp/docker-default-seccomp.XXXXXX.json)
    CREATED_TMPFILE=true
    
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        echo "ERROR: curl or wget is required to download the default profile" >&2
        exit 1
    fi
    
    echo "→ Downloading Docker default seccomp profile from moby/profiles ..."
    if command -v curl &>/dev/null; then
        curl -fsSL "$PROFILE_URL" -o "$TMPFILE"
    else
        wget -q "$PROFILE_URL" -O "$TMPFILE"
    fi
    
    # Validate it's valid JSON
    python3 -c "import json, sys; json.load(sys.stdin)" < "$TMPFILE" || {
        echo "ERROR: Downloaded file is not valid JSON" >&2
        exit 1
    }
    
    echo "✓ Downloaded and validated default profile"
fi

# ---------------------------------------------------------------------------
# Chromium zygote / sandbox syscalls that Docker blocks by default.
#
# These are the calls Chromium's multi-process architecture needs for:
#   - Zygote process spawning (clone, clone3, unshare)
#   - Namespace isolation between browser processes (setns, unshare)
#   - Sandbox enforcement via eBPF on Linux (bpf)
#   - File system monitoring for sandbox policy (fanotify_*)
#   - PID-based signaling without /proc (pidfd_*)
#
# Sources:
#   https://chromium.googlesource.com/chromium/src/+/HEAD/docs/linux/suid_sandbox设计与实现.md
#   https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/browser_main_loop.cc
#   https://docs.docker.com/engine/security/seccomp/ (Docker default blocks list)
# ---------------------------------------------------------------------------
CHROMIUM_SYSCALLS='[
    "clone",
    "clone3",
    "unshare",
    "setns",
    "bpf",
    "fanotify_init",
    "fanotify_mark",
    "pidfd_open",
    "pidfd_send_signal"
]'

# ---------------------------------------------------------------------------
# Merge: start from Docker defaults, add Chromium exceptions
# ---------------------------------------------------------------------------
MERGED=$(python3 - "$TMPFILE" "$CHROMIUM_SYSCALLS" <<'PYTHON'
import json
import sys

default_profile_path = sys.argv[1]
chromium_syscalls_json = sys.argv[2]

with open(default_profile_path) as f:
    profile = json.load(f)

# Parse the Chromium syscall list
chromium_calls = set(json.loads(chromium_syscalls_json))

# Collect existing allowed syscall names from Docker's default
existing_names = set()
for entry in profile.get("syscalls", []):
    if isinstance(entry, dict):
        name = entry.get("name")
        action = entry.get("action")
        if name and action == "SCMP_ACT_ALLOW":
            existing_names.add(name)

# Track what we're adding vs already present
already_present = chromium_calls & existing_names
to_add = chromium_calls - existing_names

if already_present:
    print(f"ℹ  {len(already_present)} Chromium syscall(s) already allowed by Docker defaults:", file=sys.stderr)
    for s in sorted(already_present):
        print(f"     • {s}", file=sys.stderr)

if to_add:
    print(f"→ Adding {len(to_add)} Chromium zygote/sandbox syscall(s):", file=sys.stderr)
    for s in sorted(to_add):
        print(f"   + {s}", file=sys.stderr)
else:
    print("ℹ  All Chromium syscalls already allowed by Docker defaults — no changes needed", file=sys.stderr)

# Add the new entries (idempotent — won't duplicate if run twice)
for name in sorted(to_add):
    profile["syscalls"].append({
        "name": name,
        "action": "SCMP_ACT_ALLOW",
        "args": []
    })

# Ensure defaultAction is SCMP_ACT_ERRNO (deny by default)
profile["defaultAction"] = "SCMP_ACT_ERRNO"

# Pretty-print with 4-space indent for readability
print(json.dumps(profile, indent=4))
PYTHON
)

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
if $DRY_RUN; then
    echo ""
    echo "--- DRY RUN: would write to $OUTPUT ---"
    echo "$MERGED" | head -20
    echo "..."
    TOTAL=$(echo "$MERGED" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('syscalls',[])))")
    echo ""
    echo "Total allowed syscalls: $TOTAL"
else
    echo "$MERGED" > "$OUTPUT"
    TOTAL=$(python3 -c "import json; d=json.load(open('$OUTPUT')); print(len(d.get('syscalls',[])))")
    BLOCKED_TOTAL=370  # approximate total Linux syscalls on x86_64 as of kernel 6.x
    BLOCKED=$((BLOCKED_TOTAL - TOTAL))
    
    echo ""
    echo "✓ Wrote merged profile to $OUTPUT"
    echo "  Allowed: $TOTAL syscalls"
    echo "  Blocked: ~$BLOCKED syscalls (deny-by-default)"
    echo ""
    echo "To use in docker-compose.yml:"
    echo "  security_opt:"
    echo "    - seccomp=$OUTPUT"
fi