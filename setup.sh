#!/bin/bash

set -e

echo "Setting up Agents configurations..."

# Resolve the absolute path of this script, then its parent directory.
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config"

mkdir -p "$CONFIG_DIR"

for AGENT_DIR in "$SCRIPT_PATH"/*/; do
	[ -d "$AGENT_DIR" ] || continue

	AGENT_NAME="$(basename "$AGENT_DIR")"
	DEST_DIR="$CONFIG_DIR/$AGENT_NAME"

	echo "Copying $AGENT_NAME -> $DEST_DIR"
	rm -rf "$DEST_DIR"
	cp -R "$AGENT_DIR" "$DEST_DIR"
done

echo ""
echo "Setup complete!"
echo ""
