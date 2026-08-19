#!/bin/sh
set -eu

fail=0

for f in workspace.yaml go.work Cargo.toml pnpm-workspace.yaml CLAUDE.md; do
    [ -f "workspace/$f" ] || { echo "missing workspace/$f" >&2; fail=1; }
done

for d in ../opends-*; do
    name=$(basename "$d")
    [ "$name" = "opends-workspace" ] && continue
    [ "$name" = "opends-uhid" ] && continue

    if [ -f "$d/go.mod" ] && ! grep -q "\./$name" workspace/go.work; then
        echo "$name has a go.mod but is missing from go.work" >&2
        fail=1
    fi

    if [ -f "$d/Cargo.toml" ] && ! grep -q "\"$name\"" workspace/Cargo.toml; then
        echo "$name has a Cargo.toml but is missing from the Cargo workspace" >&2
        fail=1
    fi
done

if grep -q '"opends-uhid"' workspace/Cargo.toml; then
    echo "opends-uhid must never be a Cargo workspace member" >&2
    echo "it needs the WDK and cannot build on Linux, so adding it breaks" >&2
    echo "cargo build at the workspace root for everyone" >&2
    fail=1
fi

[ "$fail" -eq 0 ] && echo "workspace files are consistent with the repos on disk"

exit "$fail"
