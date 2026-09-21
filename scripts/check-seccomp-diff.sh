#!/usr/bin/env bash
# =============================================================================
# check-seccomp-diff.sh
#
# Compares upstream Docker seccomp profile against local copy and reports
# differences. Sets GitHub Actions output 'changed' to true/false.
#
# Usage: ./check-seccomp-diff.sh <upstream_file> <local_file>
# =============================================================================
set -euo pipefail

UPSTREAM_FILE="${1:?Usage: $0 <upstream_file> <local_file>}"
LOCAL_FILE="${2:?Usage: $0 <upstream_file> <local_file>}"

if [ ! -f "$LOCAL_FILE" ]; then
    echo "No local copy found — first run, will generate everything."
    echo "changed=true" >> "$GITHUB_OUTPUT"
    exit 0
fi

# Compare normalized JSON (ignore whitespace differences)
UPSTREAM_HASH=$(python3 -c "import json; print(json.dumps(json.load(open('$UPSTREAM_FILE')), sort_keys=True))" | sha256sum | cut -d' ' -f1)
LOCAL_HASH=$(python3 -c "import json; print(json.dumps(json.load(open('$LOCAL_FILE')), sort_keys=True))" | sha256sum | cut -d' ' -f1)

if [ "$UPSTREAM_HASH" != "$LOCAL_HASH" ]; then
    echo "::notice::Upstream Docker seccomp profile has changed (hash: ${LOCAL_HASH} → ${UPSTREAM_HASH})"
    
    # Show what changed using Python for clean diff output
    python3 - "$UPSTREAM_FILE" "$LOCAL_FILE" << 'PYTHON_SCRIPT'
import json
import sys

upstream_file = sys.argv[1]
local_file = sys.argv[2]

with open(upstream_file) as f:
    upstream = json.load(f)
with open(local_file) as f:
    local = json.load(f)

def syscall_names(profile):
    names = set()
    for entry in profile.get('syscalls', []):
        if not isinstance(entry, dict):
            continue
        if isinstance(entry.get('name'), str):
            names.add(entry['name'])
        entry_names = entry.get('names', [])
        if isinstance(entry_names, list):
            names.update(name for name in entry_names if isinstance(name, str))
    return names


upstream_names = syscall_names(upstream)
local_names = syscall_names(local)

added = sorted(upstream_names - local_names)
removed = sorted(local_names - upstream_names)

if added:
    print(f'New syscalls in Docker defaults ({len(added)}):')
    for s in added[:10]:
        print(f'  + {s}')
    if len(added) > 10:
        print(f'  ... and {len(added)-10} more')

if removed:
    print(f'Syscalls removed from Docker defaults ({len(removed)}):')
    for s in removed[:10]:
        print(f'  - {s}')
    if len(removed) > 10:
        print(f'  ... and {len(removed)-10} more')

if not added and not removed:
    print('No syscall name changes detected (possibly action/arg modifications only)')
PYTHON_SCRIPT
    
    echo "changed=true" >> "$GITHUB_OUTPUT"
else
    echo "::notice::Upstream Docker seccomp profile unchanged — skipping."
    echo "changed=false" >> "$GITHUB_OUTPUT"
fi