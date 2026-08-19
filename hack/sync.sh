#!/bin/sh
set -eu

DEST="${1:-..}"

for f in workspace.yaml go.work Cargo.toml pnpm-workspace.yaml CLAUDE.md; do
    cp "workspace/$f" "$DEST/$f"
    echo "sync: wrote $DEST/$f"
done
