#!/bin/bash

set -e

usage() {
	cat <<'USAGE'
Usage:
  ./setup.sh                  Sync every agent config directory to ~/.config
  ./setup.sh <agent>          Sync one agent config directory, e.g. ./setup.sh opencode
  ./setup.sh <agent> <path>   Sync one file or directory inside an agent config

Examples:
  ./setup.sh opencode opencode.jsonc
  ./setup.sh opencode plugins
USAGE
}

echo "Setting up Agents configurations..."

# Resolve the absolute path of this script, then its parent directory.
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config"

mkdir -p "$CONFIG_DIR"

if [ "$#" -gt 2 ]; then
	usage
	exit 1
fi

sync_path() {
	local SOURCE_PATH="$1"
	local DEST_PATH="$2"

	if [ ! -e "$SOURCE_PATH" ]; then
		echo "Missing source: $SOURCE_PATH" >&2
		exit 1
	fi

	mkdir -p "$(dirname "$DEST_PATH")"
	rm -rf "$DEST_PATH"
	cp -R "$SOURCE_PATH" "$DEST_PATH"
}

is_guarded_opencode_config() {
	local AGENT_NAME="$1"
	local RELATIVE_PATH="$2"

	[ "$AGENT_NAME" = "opencode" ] || return 1
	[ "$RELATIVE_PATH" = "opencode.json" ] || [ "$RELATIVE_PATH" = "opencode.jsonc" ]
}

backup_path() {
	local DEST_PATH="$1"
	local BACKUP_PATH

	BACKUP_PATH="$DEST_PATH.backup.$(date +%Y%m%d%H%M%S)"
	cp -R "$DEST_PATH" "$BACKUP_PATH"
	echo "$BACKUP_PATH"
}

sync_guarded_opencode_config() {
	local SOURCE_PATH="$1"
	local DEST_PATH="$2"
	local RELATIVE_PATH="$3"
	local CHOICE
	local BACKUP_PATH

	if [ ! -e "$SOURCE_PATH" ]; then
		echo "Missing source: $SOURCE_PATH" >&2
		exit 1
	fi

	if [ ! -e "$DEST_PATH" ] || cmp -s "$SOURCE_PATH" "$DEST_PATH"; then
		sync_path "$SOURCE_PATH" "$DEST_PATH"
		return
	fi

	echo ""
	echo "Global opencode config differs from repo: $RELATIVE_PATH"
	echo "Syncing now would overwrite: $DEST_PATH"
	echo ""
	echo "Choose an option:"
	echo "  1) Override global with repo version"
	echo "  2) Create backup, then override global with repo version"
	echo "  3) Bring global changes into repo, then sync global"
	echo ""
	printf "Enter 1, 2, or 3: "
	read -r CHOICE

	case "$CHOICE" in
		1)
			sync_path "$SOURCE_PATH" "$DEST_PATH"
			;;
		2)
			BACKUP_PATH="$(backup_path "$DEST_PATH")"
			echo "Created backup: $BACKUP_PATH"
			sync_path "$SOURCE_PATH" "$DEST_PATH"
			;;
		3)
			mkdir -p "$(dirname "$SOURCE_PATH")"
			cp -R "$DEST_PATH" "$SOURCE_PATH"
			sync_path "$SOURCE_PATH" "$DEST_PATH"
			echo "Updated repo from global: $SOURCE_PATH"
			;;
		*)
			echo "Cancelled. Choose 1, 2, or 3." >&2
			exit 1
			;;
	esac
}

sync_agent_path() {
	local AGENT_NAME="$1"
	local RELATIVE_PATH="$2"
	local SOURCE_PATH="$SCRIPT_PATH/$AGENT_NAME/$RELATIVE_PATH"
	local DEST_PATH="$CONFIG_DIR/$AGENT_NAME/$RELATIVE_PATH"

	if is_guarded_opencode_config "$AGENT_NAME" "$RELATIVE_PATH"; then
		sync_guarded_opencode_config "$SOURCE_PATH" "$DEST_PATH" "$RELATIVE_PATH"
	else
		sync_path "$SOURCE_PATH" "$DEST_PATH"
	fi
}

sync_agent_dir() {
	local AGENT_NAME="$1"
	local SOURCE_DIR="$SCRIPT_PATH/$AGENT_NAME"
	local DEST_DIR="$CONFIG_DIR/$AGENT_NAME"
	local ENTRY

	if [ ! -d "$SOURCE_DIR" ]; then
		echo "Missing agent config directory: $SOURCE_DIR" >&2
		exit 1
	fi

	if [ "$AGENT_NAME" != "opencode" ]; then
		sync_path "$SOURCE_DIR" "$DEST_DIR"
		return
	fi

	mkdir -p "$DEST_DIR"
	for ENTRY in "$SOURCE_DIR"/* "$SOURCE_DIR"/.[!.]* "$SOURCE_DIR"/..?*; do
		[ -e "$ENTRY" ] || continue
		sync_agent_path "$AGENT_NAME" "$(basename "$ENTRY")"
	done
}

if [ "$#" -eq 2 ]; then
	AGENT_NAME="$1"
	RELATIVE_PATH="$2"

	case "$RELATIVE_PATH" in
		/*|*..*)
			echo "Path must be relative and cannot contain '..': $RELATIVE_PATH" >&2
			exit 1
			;;
	esac

	SOURCE_PATH="$SCRIPT_PATH/$AGENT_NAME/$RELATIVE_PATH"
	DEST_PATH="$CONFIG_DIR/$AGENT_NAME/$RELATIVE_PATH"

	echo "Copying $AGENT_NAME/$RELATIVE_PATH -> $DEST_PATH"
	sync_agent_path "$AGENT_NAME" "$RELATIVE_PATH"

	echo ""
	echo "Setup complete!"
	echo ""
	exit 0
fi

if [ "$#" -eq 1 ]; then
	AGENT_NAME="$1"
	SOURCE_DIR="$SCRIPT_PATH/$AGENT_NAME"
	DEST_DIR="$CONFIG_DIR/$AGENT_NAME"

	if [ ! -d "$SOURCE_DIR" ]; then
		echo "Missing agent config directory: $SOURCE_DIR" >&2
		exit 1
	fi

	echo "Copying $AGENT_NAME -> $DEST_DIR"
	sync_agent_dir "$AGENT_NAME"

	echo ""
	echo "Setup complete!"
	echo ""
	exit 0
fi

for AGENT_DIR in "$SCRIPT_PATH"/*/; do
	[ -d "$AGENT_DIR" ] || continue

	AGENT_NAME="$(basename "$AGENT_DIR")"
	DEST_DIR="$CONFIG_DIR/$AGENT_NAME"

	echo "Copying $AGENT_NAME -> $DEST_DIR"
	sync_agent_dir "$AGENT_NAME"
done

echo ""
echo "Setup complete!"
echo ""
