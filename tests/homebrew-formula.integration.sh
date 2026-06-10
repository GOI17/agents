#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FORMULA_PATH="$ROOT_DIR/Formula/agent-switcher.rb"

[ -f "$FORMULA_PATH" ] || { echo "Expected formula: $FORMULA_PATH" >&2; exit 1; }

if command -v ruby >/dev/null 2>&1; then
	ruby -c "$FORMULA_PATH" >/dev/null
fi

grep -F 'bin.install "bin/agent-switcher"' "$FORMULA_PATH" >/dev/null || { echo "Formula must install bin/agent-switcher" >&2; exit 1; }
grep -F 'pkgshare.install "setup.sh"' "$FORMULA_PATH" >/dev/null || { echo "Formula must install setup.sh" >&2; exit 1; }
grep -F 'agent-switcher --help' "$FORMULA_PATH" >/dev/null || { echo "Formula test must run help" >&2; exit 1; }

echo "Homebrew formula integration tests passed."
