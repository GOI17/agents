#!/bin/bash

set -euo pipefail

usage() {
	cat <<'USAGE'
Usage:
  ./setup.sh                         Sync every agent config directory to ~/.config
  ./setup.sh <agent>                 Sync one agent config directory, e.g. ./setup.sh opencode
  ./setup.sh <agent> <path>          Sync one file or directory inside an agent config
  ./setup.sh switch --profile <profile> --agent <agent>
                                      Activate a profile by symlinking ~/.config/<agent>
  ./setup.sh --env <profile>         Sync one profile-first agent config
  ./setup.sh --env <profile> <agent> Sync one agent profile
  ./setup.sh --env <profile> <agent> <path>
                                     Sync one path inside a profile-first agent config
  ./setup.sh --list-envs             Show configured profiles

Profile-first layouts:
  Tracked profiles live in:          <agent>/profiles/<profile>/<agent>/...
  Private profiles live in:          <agent>/profiles.local/<profile>/<agent>/...

For opencode.json/opencode.jsonc, setup merges JSON/JSONC layers in this order:
  canonical profile -> legacy profile

Objects are deep-merged. Arrays and scalar values are replaced by the later layer.
Use profiles.local for secrets, API keys, private MCP headers, or work-only plugins.

Examples:
  ./setup.sh opencode opencode.jsonc
  ./setup.sh opencode plugins
  ./setup.sh --env personal opencode opencode.jsonc
  AGENTS_PROFILE=work-1 ./setup.sh opencode
USAGE
}

echo "Setting up Agents configurations..."

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config"
ENVIRONMENT="${AGENTS_PROFILE:-${AGENTS_ENV:-}}"
PROFILE_DIR_NAME="profiles"
PROFILE_LOCAL_DIR_NAME="profiles.local"
LEGACY_ENV_DIR_NAME="environments"
LEGACY_LOCAL_ENV_DIR_NAME="environments.local"
LIST_ENVIRONMENTS=false
SWITCH_PROFILE=false
SWITCH_AGENT=""
TEMP_FILES=()

cleanup_temp_files() {
	local TEMP_FILE
	for TEMP_FILE in "${TEMP_FILES[@]:-}"; do
		[ -n "$TEMP_FILE" ] && rm -f "$TEMP_FILE"
	done
	return 0
}

trap cleanup_temp_files EXIT

POSITIONAL_ARGS=()
while [ "$#" -gt 0 ]; do
	case "$1" in
		switch)
			SWITCH_PROFILE=true
			shift
			;;
		-e|--env)
			[ "$#" -ge 2 ] || { echo "Missing environment name after $1" >&2; exit 1; }
			ENVIRONMENT="$2"
			shift 2
			;;
		--profile)
			[ "$#" -ge 2 ] || { echo "Missing profile name after $1" >&2; exit 1; }
			ENVIRONMENT="$2"
			shift 2
			;;
		--profile=*)
			ENVIRONMENT="${1#--profile=}"
			shift
			;;
		--agent)
			[ "$#" -ge 2 ] || { echo "Missing agent name after $1" >&2; exit 1; }
			SWITCH_AGENT="$2"
			shift 2
			;;
		--agent=*)
			SWITCH_AGENT="${1#--agent=}"
			shift
			;;
		--env=*)
			ENVIRONMENT="${1#--env=}"
			shift
			;;
		--list-envs)
			LIST_ENVIRONMENTS=true
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		--)
			shift
			while [ "$#" -gt 0 ]; do
				POSITIONAL_ARGS+=("$1")
				shift
			done
			;;
		-*)
			echo "Unknown option: $1" >&2
			usage
			exit 1
			;;
		*)
			POSITIONAL_ARGS+=("$1")
			shift
			;;
	esac
done

if [ "${#POSITIONAL_ARGS[@]}" -gt 0 ]; then
	set -- "${POSITIONAL_ARGS[@]}"
else
	set --
fi

mkdir -p "$CONFIG_DIR"

if [ "$#" -gt 2 ]; then
	usage
	exit 1
fi

if [ "$SWITCH_PROFILE" = true ] && { [ "$#" -gt 0 ] || [ -z "$ENVIRONMENT" ] || [ -z "$SWITCH_AGENT" ]; }; then
	usage
	exit 1
fi

validate_profile_name() {
	local NAME="$1"
	[ -n "$NAME" ] || { echo "Profile name cannot be empty." >&2; exit 1; }
	case "$NAME" in
		/*|*..*|*/*|*\\*)
			echo "Profile name must be a simple directory name: $NAME" >&2
			exit 1
			;;
	esac
}

validate_agent_name() {
	local NAME="$1"
	[ -n "$NAME" ] || { echo "Agent name cannot be empty." >&2; exit 1; }
	case "$NAME" in
		/*|*..*|*/*|*\\*)
			echo "Agent name must be a simple directory name: $NAME" >&2
			exit 1
			;;
	esac
}

validate_relative_path() {
	local RELATIVE_PATH="$1"
	case "$RELATIVE_PATH" in
		/*|*..*)
			echo "Path must be relative and cannot contain '..': $RELATIVE_PATH" >&2
			exit 1
			;;
	esac
}

is_profile_dir_name() {
	local ENTRY_NAME="$1"
	[ "$ENTRY_NAME" = "$PROFILE_DIR_NAME" ] || [ "$ENTRY_NAME" = "$PROFILE_LOCAL_DIR_NAME" ]
}

is_guarded_opencode_config() {
	local AGENT_NAME="$1" RELATIVE_PATH="$2"
	[ "$AGENT_NAME" = "opencode" ] || return 1
	[ "$RELATIVE_PATH" = "opencode.json" ] || [ "$RELATIVE_PATH" = "opencode.jsonc" ]
}

is_json_config_path() {
	local RELATIVE_PATH="$1"
	[ "$RELATIVE_PATH" = "opencode.json" ] || [ "$RELATIVE_PATH" = "opencode.jsonc" ]
}

backup_path() {
	local DEST_PATH="$1" BACKUP_PATH
	BACKUP_PATH="$DEST_PATH.backup.$(date +%Y%m%d%H%M%S)"
	cp -R "$DEST_PATH" "$BACKUP_PATH"
	echo "$BACKUP_PATH"
}

sync_guarded_opencode_config() {
	local SOURCE_PATH="$1" DEST_PATH="$2" RELATIVE_PATH="$3" CHOICE BACKUP_PATH

	[ -e "$SOURCE_PATH" ] || { echo "Missing source: $SOURCE_PATH" >&2; exit 1; }

	if [ ! -e "$DEST_PATH" ] || cmp -s "$SOURCE_PATH" "$DEST_PATH"; then
		copy_path "$SOURCE_PATH" "$DEST_PATH"
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
	if ! read -r CHOICE; then
		echo "Cancelled. Choose 1, 2, or 3." >&2
		exit 1
	fi

	case "$CHOICE" in
		1)
			copy_path "$SOURCE_PATH" "$DEST_PATH"
			;;
		2)
			BACKUP_PATH="$(backup_path "$DEST_PATH")"
			echo "Created backup: $BACKUP_PATH"
			copy_path "$SOURCE_PATH" "$DEST_PATH"
			;;
		3)
			mkdir -p "$(dirname "$SOURCE_PATH")"
			cp -R "$DEST_PATH" "$SOURCE_PATH"
			copy_path "$SOURCE_PATH" "$DEST_PATH"
			echo "Updated repo from global: $SOURCE_PATH"
			;;
		*)
			echo "Cancelled. Choose 1, 2, or 3." >&2
			exit 1
			;;
	esac
}

list_profiles() {
	local AGENT_DIR ROOT PROFILE_DIR FOUND=false
	for AGENT_DIR in "$SCRIPT_PATH"/*/; do
		[ -d "$AGENT_DIR" ] || continue
		for ROOT in "$PROFILE_DIR_NAME" "$PROFILE_LOCAL_DIR_NAME"; do
			[ -d "$AGENT_DIR/$ROOT" ] || continue
			for PROFILE_DIR in "$AGENT_DIR/$ROOT"/*/; do
				[ -d "$PROFILE_DIR" ] || continue
				FOUND=true
				echo "$(basename "$PROFILE_DIR") ($(basename "$AGENT_DIR")/$ROOT)"
			done
		done
	done

	if [ "$FOUND" = false ]; then
		echo "No profiles found. Create <agent>/profiles/<profile>/<agent>/ or <agent>/profiles.local/<profile>/<agent>/ ."
	fi
}

profile_exists() {
	local AGENT_NAME="$1" PROFILE_NAME="$2"
	[ -d "$SCRIPT_PATH/$AGENT_NAME/$PROFILE_DIR_NAME/$PROFILE_NAME/$AGENT_NAME" ] && return 0
	[ -d "$SCRIPT_PATH/$AGENT_NAME/$PROFILE_LOCAL_DIR_NAME/$PROFILE_NAME/$AGENT_NAME" ] && return 0
	[ -d "$SCRIPT_PATH/$AGENT_NAME/$LEGACY_ENV_DIR_NAME/$PROFILE_NAME/$AGENT_NAME" ] && return 0
	[ -d "$SCRIPT_PATH/$AGENT_NAME/$LEGACY_LOCAL_ENV_DIR_NAME/$PROFILE_NAME/$AGENT_NAME" ] && return 0
	return 1
}

profile_prompt_create() {
	local PROFILE_NAME="$1"
	echo "There is no existing profile with provided name, want to create a '$PROFILE_NAME' profile?"
	printf "Create profile? [y/N]: "
}

profile_create_cancelled() {
	echo "Profile creation cancelled." >&2
}

profile_global_dir() {
	local AGENT_NAME="$1"
	echo "$CONFIG_DIR/$AGENT_NAME"
}

canonical_profile_agent_dir() {
	local AGENT_NAME="$1" PROFILE_NAME="$2"
	echo "$SCRIPT_PATH/$AGENT_NAME/$PROFILE_DIR_NAME/$PROFILE_NAME/$AGENT_NAME"
}

local_profile_agent_dir() {
	local AGENT_NAME="$1" PROFILE_NAME="$2"
	echo "$SCRIPT_PATH/$AGENT_NAME/$PROFILE_LOCAL_DIR_NAME/$PROFILE_NAME/$AGENT_NAME"
}

legacy_profile_agent_dir() {
	local AGENT_NAME="$1" PROFILE_NAME="$2"
	echo "$SCRIPT_PATH/$AGENT_NAME/$LEGACY_ENV_DIR_NAME/$PROFILE_NAME/$AGENT_NAME"
}

legacy_local_profile_agent_dir() {
	local AGENT_NAME="$1" PROFILE_NAME="$2"
	echo "$SCRIPT_PATH/$AGENT_NAME/$LEGACY_LOCAL_ENV_DIR_NAME/$PROFILE_NAME/$AGENT_NAME"
}

profile_legacy_source_dirs() {
	local AGENT_NAME="$1" PROFILE_NAME="$2" CANDIDATE
	for CANDIDATE in "$(legacy_profile_agent_dir "$AGENT_NAME" "$PROFILE_NAME")" "$(legacy_local_profile_agent_dir "$AGENT_NAME" "$PROFILE_NAME")"; do
		[ -d "$CANDIDATE" ] && echo "$CANDIDATE"
	done
}

merge_json_config_file() {
	local PRIMARY_SOURCE="$1" OVERLAY_SOURCE="$2" DEST_PATH="$3" TMP_OUTPUT
	[ -e "$PRIMARY_SOURCE" ] || { echo "Missing source: $PRIMARY_SOURCE" >&2; exit 1; }
	[ -e "$OVERLAY_SOURCE" ] || { copy_path "$PRIMARY_SOURCE" "$DEST_PATH"; return 0; }
	TMP_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/agents-setup-json-merge.XXXXXX")"
	TEMP_FILES+=("$TMP_OUTPUT")
	python3 - "$PRIMARY_SOURCE" "$OVERLAY_SOURCE" "$DEST_PATH" <<'PY'
import json
import sys
from pathlib import Path

primary_path = Path(sys.argv[1])
overlay_path = Path(sys.argv[2])
dest_path = Path(sys.argv[3])

def strip_jsonc(text):
    out = []
    in_string = False
    escaped = False
    i = 0
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if in_string:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == '/' and nxt == '/':
            i += 2
            while i < len(text) and text[i] not in '\r\n':
                i += 1
            continue
        if ch == '/' and nxt == '*':
            i += 2
            while i + 1 < len(text) and not (text[i] == '*' and text[i + 1] == '/'):
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    return ''.join(out)

def remove_trailing_commas(text):
    out = []
    in_string = False
    escaped = False
    i = 0
    while i < len(text):
        ch = text[i]
        if in_string:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == ',':
            j = i + 1
            while j < len(text) and text[j].isspace():
                j += 1
            if j < len(text) and text[j] in '}]':
                i += 1
                continue
        out.append(ch)
        i += 1
    return ''.join(out)

def load_jsonc(path):
    text = path.read_text(encoding='utf-8')
    cleaned = remove_trailing_commas(strip_jsonc(text)).strip()
    if not cleaned:
        return {}
    value = json.loads(cleaned)
    if not isinstance(value, dict):
        raise TypeError(path)
    return value

def deep_merge(primary, overlay):
    result = dict(primary)
    for key, overlay_value in overlay.items():
        primary_value = result.get(key)
        if isinstance(primary_value, dict) and isinstance(overlay_value, dict):
            result[key] = deep_merge(primary_value, overlay_value)
        else:
            result[key] = overlay_value
    return result

try:
    merged = deep_merge(load_jsonc(primary_path), load_jsonc(overlay_path))
except Exception as exc:
    print(f"Malformed JSON/JSONC: {primary_path.name if primary_path.exists() else primary_path}::{exc.__class__.__name__}", file=sys.stderr)
    raise SystemExit(1)

dest_path.parent.mkdir(parents=True, exist_ok=True)
dest_path.write_text(json.dumps(merged, indent=2, ensure_ascii=False) + "\n", encoding='utf-8')
PY
}

profile_source_dir() {
	local AGENT_NAME="$1" PROFILE_NAME="$2" CANDIDATE
	materialize_legacy_profile_source "$AGENT_NAME" "$PROFILE_NAME"
	CANDIDATE="$(canonical_profile_agent_dir "$AGENT_NAME" "$PROFILE_NAME")"
	[ -d "$CANDIDATE" ] && { echo "$CANDIDATE"; return 0; }
	CANDIDATE="$SCRIPT_PATH/$AGENT_NAME/$PROFILE_LOCAL_DIR_NAME/$PROFILE_NAME/$AGENT_NAME"
	[ -d "$CANDIDATE" ] && { echo "$CANDIDATE"; return 0; }
	CANDIDATE="$(legacy_profile_agent_dir "$AGENT_NAME" "$PROFILE_NAME")"
	[ -d "$CANDIDATE" ] && { echo "$CANDIDATE"; return 0; }
	CANDIDATE="$(legacy_local_profile_agent_dir "$AGENT_NAME" "$PROFILE_NAME")"
	[ -d "$CANDIDATE" ] && { echo "$CANDIDATE"; return 0; }
	return 1
}

scan_secret_candidates() {
	local SOURCE_DIR="$1"
	local TMP_OUTPUT
	command -v python3 >/dev/null 2>&1 || { echo "python3 is required to scan opencode profile config." >&2; exit 1; }
	TMP_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/agents-setup-secret-scan.XXXXXX")"
	TEMP_FILES+=("$TMP_OUTPUT")
	python3 - "$SOURCE_DIR" <<'PY' >"$TMP_OUTPUT"
import json, math, re, sys
from pathlib import Path

source_dir = Path(sys.argv[1])
key_patterns = re.compile(r"(^|.*[._-])(key|apikey|token|secret|password|authorization|credential|headers)$", re.I)
value_patterns = [re.compile(r"Bearer\s+[A-Za-z0-9._~+/=-]{12,}"), re.compile(r"sk-[A-Za-z0-9]{16,}"), re.compile(r"ghp_[A-Za-z0-9]{20,}")]
placeholder_pattern = re.compile(r"^Bearer\s+\$\{[A-Z0-9_]+\}$|^\$\{[A-Z0-9_]+\}$")

def strip_jsonc(text):
    out=[]; in_string=False; escaped=False; i=0
    while i < len(text):
        ch=text[i]; nxt=text[i+1] if i+1 < len(text) else ""
        if in_string:
            out.append(ch)
            if escaped: escaped=False
            elif ch == "\\": escaped=True
            elif ch == '"': in_string=False
            i += 1; continue
        if ch == '"': in_string=True; out.append(ch); i += 1; continue
        if ch == '/' and nxt == '/':
            i += 2
            while i < len(text) and text[i] not in '\r\n': i += 1
            continue
        if ch == '/' and nxt == '*':
            i += 2
            while i + 1 < len(text) and not (text[i] == '*' and text[i+1] == '/'):
                if text[i] in '\r\n': out.append(text[i])
                i += 1
            i += 2; continue
        out.append(ch); i += 1
    return ''.join(out)

def remove_trailing_commas(text):
    out=[]; in_string=False; escaped=False; i=0
    while i < len(text):
        ch=text[i]
        if in_string:
            out.append(ch)
            if escaped: escaped=False
            elif ch == "\\": escaped=True
            elif ch == '"': in_string=False
            i += 1; continue
        if ch == '"': in_string=True; out.append(ch); i += 1; continue
        if ch == ',':
            j=i+1
            while j < len(text) and text[j].isspace(): j += 1
            if j < len(text) and text[j] in '}]':
                i += 1; continue
        out.append(ch); i += 1
    return ''.join(out)

def load_jsonc(path):
    text = path.read_text(encoding='utf-8')
    cleaned = remove_trailing_commas(strip_jsonc(text)).strip()
    if not cleaned:
        return None
    value = json.loads(cleaned)
    if not isinstance(value, dict):
        raise TypeError(path)
    return value

def path_label(path):
    return str(path.as_posix())

def entropy(value):
    if len(value) < 24: return 0.0
    counts={}
    for ch in value: counts[ch] = counts.get(ch, 0) + 1
    total=len(value)
    return -sum((count/total) * math.log2(count/total) for count in counts.values())

def suspicious_value(value):
    return isinstance(value, str) and not placeholder_pattern.search(value) and (any(p.search(value) for p in value_patterns) or (len(value) >= 32 and entropy(value) >= 4.0))

def subtree_has_placeholder(value):
    if isinstance(value, str):
        return bool(placeholder_pattern.search(value))
    if isinstance(value, list):
        return any(subtree_has_placeholder(child) for child in value)
    if isinstance(value, dict):
        return any(subtree_has_placeholder(child) for child in value.values())
    return False

def walk(value, path=()):
    findings=[]
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = path + (str(key),)
            if key_patterns.search(str(key)) and not subtree_has_placeholder(child):
                findings.append(("/".join(child_path),))
            findings.extend(walk(child, child_path))
    elif isinstance(value, list):
        for index, child in enumerate(value): findings.extend(walk(child, path + (str(index),)))
    elif suspicious_value(value):
        findings.append(("/".join(path) or "value",))
    return findings

parse_errors=[]
for candidate in sorted(source_dir.rglob('*.json')) + sorted(source_dir.rglob('*.jsonc')):
    if any(part.startswith('.env') for part in candidate.parts):
        continue
    try:
        data = load_jsonc(candidate)
    except Exception as exc:
        parse_errors.append(f"{candidate.relative_to(source_dir)}::{exc.__class__.__name__}")
        continue
    if data is None:
        continue
    for finding in walk(data):
        print(f"{candidate.relative_to(source_dir)}::{finding[0]}")

if parse_errors:
    for error in parse_errors:
        print(f"Malformed JSON/JSONC: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
	if [ -s "$TMP_OUTPUT" ]; then
		cat "$TMP_OUTPUT" >&2
		echo "Secret candidates found. Move sensitive data into an ignored env file before creating the profile." >&2
		return 1
	fi
}

bootstrap_profile_copy_allowlist() {
	local AGENT_NAME="$1" PROFILE_NAME="$2" GLOBAL_DIR TARGET_DIR
	GLOBAL_DIR="$(profile_global_dir "$AGENT_NAME")"
	TARGET_DIR="$SCRIPT_PATH/$AGENT_NAME/$PROFILE_LOCAL_DIR_NAME/$PROFILE_NAME/$AGENT_NAME"
	[ -d "$GLOBAL_DIR" ] || { echo "Missing global source: $GLOBAL_DIR" >&2; return 1; }
	scan_secret_candidates "$GLOBAL_DIR"
	mkdir -p "$TARGET_DIR"
	python3 - "$GLOBAL_DIR" "$TARGET_DIR" <<'PY'
import os
import shutil
import sys
from pathlib import Path

source_dir = Path(sys.argv[1])
target_dir = Path(sys.argv[2])
allowlisted = {"opencode.json", "opencode.jsonc", "plugins", "commands", "prompts", "skills", "tui.json"}
copied = False

def excluded(path: Path) -> bool:
    return any(part.startswith('.env') for part in path.parts)

def copy_entry(source: Path, target: Path) -> None:
    global copied
    if excluded(source.relative_to(source_dir)):
        return
    if source.is_dir() and not source.is_symlink():
        target.mkdir(parents=True, exist_ok=True)
        for child in source.iterdir():
            copy_entry(child, target / child.name)
        copied = True
        return
    if source.is_file() or source.is_symlink():
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target, follow_symlinks=False)
        copied = True

for entry in sorted(source_dir.iterdir(), key=lambda path: path.name):
    if entry.name.startswith('.env'):
        continue
    if entry.name not in allowlisted:
        continue
    copy_entry(entry, target_dir / entry.name)

if not copied:
    print(f"Missing usable bootstrap config in {source_dir}", file=sys.stderr)
    raise SystemExit(1)
PY
}

bootstrap_profile_from_global() {
	local AGENT_NAME="$1" PROFILE_NAME="$2" GLOBAL_DIR TARGET_DIR
	bootstrap_profile_copy_allowlist "$AGENT_NAME" "$PROFILE_NAME"
}

seed_local_profile_from_base() {
	local BASE_DIR="$1" LOCAL_DIR="$2"
	[ -d "$BASE_DIR" ] || { echo "Missing local profile source: $BASE_DIR" >&2; return 1; }
	mkdir -p "$LOCAL_DIR"
	python3 - "$BASE_DIR" "$LOCAL_DIR" <<'PY'
import shutil
import sys
from pathlib import Path

base_dir = Path(sys.argv[1])
local_dir = Path(sys.argv[2])

for source in sorted(base_dir.rglob('*')):
    relative_path = source.relative_to(base_dir)
    target = local_dir / relative_path
    if target.exists() or target.is_symlink():
        continue
    if source.is_dir():
        target.mkdir(parents=True, exist_ok=True)
    elif source.is_symlink():
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(source.readlink())
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
PY
	for RELATIVE_PATH in opencode.json opencode.jsonc; do
		if [ -e "$BASE_DIR/$RELATIVE_PATH" ] && [ -e "$LOCAL_DIR/$RELATIVE_PATH" ]; then
			merge_json_config_file "$BASE_DIR/$RELATIVE_PATH" "$LOCAL_DIR/$RELATIVE_PATH" "$LOCAL_DIR/$RELATIVE_PATH"
		fi
	done
}

materialize_legacy_profile_source() {
	local AGENT_NAME="$1" PROFILE_NAME="$2" SOURCE_DIR DEST_DIR
	for SOURCE_DIR in "$(legacy_profile_agent_dir "$AGENT_NAME" "$PROFILE_NAME")" "$(legacy_local_profile_agent_dir "$AGENT_NAME" "$PROFILE_NAME")"; do
		[ -d "$SOURCE_DIR" ] || continue
		if [ "$SOURCE_DIR" = "$(legacy_local_profile_agent_dir "$AGENT_NAME" "$PROFILE_NAME")" ]; then
			DEST_DIR="$(local_profile_agent_dir "$AGENT_NAME" "$PROFILE_NAME")"
		else
			DEST_DIR="$SCRIPT_PATH/$AGENT_NAME/$PROFILE_DIR_NAME/$PROFILE_NAME/$AGENT_NAME"
		fi
		[ -e "$DEST_DIR" ] || copy_path "$SOURCE_DIR" "$DEST_DIR"
	done
}

ensure_profile_exists() {
	local AGENT_NAME="$1" PROFILE_NAME="$2"
	profile_exists "$AGENT_NAME" "$PROFILE_NAME" && return 0
	[ -d "$(profile_global_dir "$AGENT_NAME")" ] || { echo "Missing profile source and missing global config: $PROFILE_NAME" >&2; return 1; }
	profile_prompt_create "$PROFILE_NAME"
	if ! read -r CHOICE; then
		profile_create_cancelled
		return 1
	fi
	case "$CHOICE" in
		y|Y|yes|YES)
			bootstrap_profile_from_global "$AGENT_NAME" "$PROFILE_NAME"
			;;
		*)
			profile_create_cancelled
			return 1
			;;
	esac
}

ensure_switch_local_profile() {
	local AGENT_NAME="$1" PROFILE_NAME="$2" CANONICAL_DIR LOCAL_DIR LEGACY_TRACKED_DIR
	CANONICAL_DIR="$(canonical_profile_agent_dir "$AGENT_NAME" "$PROFILE_NAME")"
	LOCAL_DIR="$(local_profile_agent_dir "$AGENT_NAME" "$PROFILE_NAME")"
	LEGACY_TRACKED_DIR="$(legacy_profile_agent_dir "$AGENT_NAME" "$PROFILE_NAME")"

	[ -d "$SCRIPT_PATH/$AGENT_NAME" ] || { echo "Missing agent config directory: $SCRIPT_PATH/$AGENT_NAME" >&2; return 1; }
	profile_exists "$AGENT_NAME" "$PROFILE_NAME" || { echo "Missing profile: $PROFILE_NAME" >&2; return 1; }

	[ -d "$CANONICAL_DIR" ] && scan_secret_candidates "$CANONICAL_DIR"
	[ -d "$LEGACY_TRACKED_DIR" ] && scan_secret_candidates "$LEGACY_TRACKED_DIR"
	materialize_legacy_profile_source "$AGENT_NAME" "$PROFILE_NAME"

	[ -d "$CANONICAL_DIR" ] || { [ -d "$LOCAL_DIR" ] && return 0; }
	[ -d "$CANONICAL_DIR" ] || { echo "Missing local profile source: $LOCAL_DIR" >&2; return 1; }
	scan_secret_candidates "$CANONICAL_DIR"
	seed_local_profile_from_base "$CANONICAL_DIR" "$LOCAL_DIR"
}

activate_profile_symlink() {
	local AGENT_NAME="$1" PROFILE_NAME="$2" GLOBAL_DIR LOCAL_DIR
	GLOBAL_DIR="$(profile_global_dir "$AGENT_NAME")"
	LOCAL_DIR="$(local_profile_agent_dir "$AGENT_NAME" "$PROFILE_NAME")"

	[ -d "$LOCAL_DIR" ] || { echo "Missing local profile: $LOCAL_DIR" >&2; return 1; }
	mkdir -p "$(dirname "$GLOBAL_DIR")"
	if [ -e "$GLOBAL_DIR" ] || [ -L "$GLOBAL_DIR" ]; then
		if [ ! -L "$GLOBAL_DIR" ]; then
			echo "Refusing to replace existing machine config: $GLOBAL_DIR" >&2
			echo "Move it into $LOCAL_DIR, back it up, or remove it before switching." >&2
			return 1
		fi
		rm "$GLOBAL_DIR"
	fi
	ln -s "$LOCAL_DIR" "$GLOBAL_DIR"
}

switch_profile() {
	local AGENT_NAME="$1" PROFILE_NAME="$2"
	validate_agent_name "$AGENT_NAME"
	validate_profile_name "$PROFILE_NAME"
	ensure_switch_local_profile "$AGENT_NAME" "$PROFILE_NAME"
	activate_profile_symlink "$AGENT_NAME" "$PROFILE_NAME"
}

copy_path() {
	local SOURCE_PATH="$1" DEST_PATH="$2"
	[ -e "$SOURCE_PATH" ] || { echo "Missing source: $SOURCE_PATH" >&2; exit 1; }
	mkdir -p "$(dirname "$DEST_PATH")"
	rm -rf "$DEST_PATH"
	cp -R "$SOURCE_PATH" "$DEST_PATH"
}

sync_profile_relative_path() {
	local AGENT_NAME="$1" PROFILE_NAME="$2" RELATIVE_PATH="$3" SOURCE_DIR SOURCE_PATH DEST_PATH
	validate_relative_path "$RELATIVE_PATH"
	SOURCE_DIR="$(profile_source_dir "$AGENT_NAME" "$PROFILE_NAME")" || { echo "Missing profile: $PROFILE_NAME" >&2; exit 1; }
	SOURCE_PATH="$SOURCE_DIR/$RELATIVE_PATH"
	DEST_PATH="$CONFIG_DIR/$AGENT_NAME/$RELATIVE_PATH"
	if is_json_config_path "$RELATIVE_PATH"; then
		while IFS= read -r LEGACY_DIR; do
			[ -n "$LEGACY_DIR" ] || continue
			if [ "$SOURCE_DIR" != "$LEGACY_DIR" ] && [ -e "$LEGACY_DIR/$RELATIVE_PATH" ]; then
				merge_json_config_file "$SOURCE_PATH" "$LEGACY_DIR/$RELATIVE_PATH" "$DEST_PATH"
				return 0
			fi
		done <<EOF
$(profile_legacy_source_dirs "$AGENT_NAME" "$PROFILE_NAME")
EOF
	fi
	copy_path "$SOURCE_PATH" "$DEST_PATH"
}

sync_profile_dir() {
	local AGENT_NAME="$1" PROFILE_NAME="$2" SOURCE_DIR DEST_DIR
	SOURCE_DIR="$(profile_source_dir "$AGENT_NAME" "$PROFILE_NAME")" || { echo "Missing profile: $PROFILE_NAME" >&2; exit 1; }
	DEST_DIR="$CONFIG_DIR/$AGENT_NAME"
	mkdir -p "$DEST_DIR"
	cp -R "$SOURCE_DIR"/. "$DEST_DIR"/
	if [ -e "$SOURCE_DIR/opencode.json" ] || [ -e "$SOURCE_DIR/opencode.jsonc" ]; then
		while IFS= read -r LEGACY_DIR; do
			[ -n "$LEGACY_DIR" ] || continue
			for RELATIVE_PATH in opencode.json opencode.jsonc; do
				if [ -e "$LEGACY_DIR/$RELATIVE_PATH" ] && [ -e "$SOURCE_DIR/$RELATIVE_PATH" ]; then
					merge_json_config_file "$SOURCE_DIR/$RELATIVE_PATH" "$LEGACY_DIR/$RELATIVE_PATH" "$DEST_DIR/$RELATIVE_PATH"
				fi
			done
		done <<EOF
$(profile_legacy_source_dirs "$AGENT_NAME" "$PROFILE_NAME")
EOF
	fi
}

sync_agent_path() {
	local AGENT_NAME="$1" RELATIVE_PATH="$2" SOURCE_PATH DEST_PATH
	validate_relative_path "$RELATIVE_PATH"
	if is_profile_dir_name "$RELATIVE_PATH" || [ "$RELATIVE_PATH" = "$LEGACY_ENV_DIR_NAME" ] || [ "$RELATIVE_PATH" = "$LEGACY_LOCAL_ENV_DIR_NAME" ]; then
		return 0
	fi
	SOURCE_PATH="$SCRIPT_PATH/$AGENT_NAME/$RELATIVE_PATH"
	DEST_PATH="$CONFIG_DIR/$AGENT_NAME/$RELATIVE_PATH"
	if is_guarded_opencode_config "$AGENT_NAME" "$RELATIVE_PATH"; then
		sync_guarded_opencode_config "$SOURCE_PATH" "$DEST_PATH" "$RELATIVE_PATH"
	else
		copy_path "$SOURCE_PATH" "$DEST_PATH"
	fi
}

sync_agent_dir_without_profiles() {
	local AGENT_NAME="$1" SOURCE_DIR="$SCRIPT_PATH/$AGENT_NAME" DEST_DIR="$CONFIG_DIR/$AGENT_NAME" ENTRY ENTRY_NAME
	[ -d "$SOURCE_DIR" ] || { echo "Missing agent config directory: $SOURCE_DIR" >&2; exit 1; }
	mkdir -p "$DEST_DIR"
	for ENTRY in "$SOURCE_DIR"/* "$SOURCE_DIR"/.[!.]* "$SOURCE_DIR"/..?*; do
		[ -e "$ENTRY" ] || continue
		ENTRY_NAME="$(basename "$ENTRY")"
		is_profile_dir_name "$ENTRY_NAME" && continue
		[ "$ENTRY_NAME" = "$LEGACY_ENV_DIR_NAME" ] && continue
		[ "$ENTRY_NAME" = "$LEGACY_LOCAL_ENV_DIR_NAME" ] && continue
		copy_path "$ENTRY" "$DEST_DIR/$ENTRY_NAME"
	done
}

if [ "$LIST_ENVIRONMENTS" = true ]; then
	list_profiles
	exit 0
fi

if [ "$SWITCH_PROFILE" = true ]; then
	switch_profile "$SWITCH_AGENT" "$ENVIRONMENT"
	echo ""
	echo "Switched $SWITCH_AGENT to profile: $ENVIRONMENT"
	echo ""
	exit 0
fi

if [ -n "$ENVIRONMENT" ]; then
	validate_profile_name "$ENVIRONMENT"
	echo "Using profile: $ENVIRONMENT"
fi

if [ "$#" -eq 2 ]; then
	AGENT_NAME="$1"
	RELATIVE_PATH="$2"
	if [ -n "$ENVIRONMENT" ]; then
		ensure_profile_exists "$AGENT_NAME" "$ENVIRONMENT"
		sync_profile_relative_path "$AGENT_NAME" "$ENVIRONMENT" "$RELATIVE_PATH"
	else
		sync_agent_path "$AGENT_NAME" "$RELATIVE_PATH"
	fi
	echo ""
	echo "Setup complete!"
	echo ""
	exit 0
fi

if [ "$#" -eq 1 ]; then
	AGENT_NAME="$1"
	if [ -n "$ENVIRONMENT" ]; then
		ensure_profile_exists "$AGENT_NAME" "$ENVIRONMENT"
		sync_profile_dir "$AGENT_NAME" "$ENVIRONMENT"
	else
		sync_agent_dir_without_profiles "$AGENT_NAME"
	fi
	echo ""
	echo "Setup complete!"
	echo ""
	exit 0
fi

for AGENT_DIR in "$SCRIPT_PATH"/*/; do
	[ -d "$AGENT_DIR" ] || continue
	AGENT_NAME="$(basename "$AGENT_DIR")"
	sync_agent_dir_without_profiles "$AGENT_NAME"
done

echo ""
echo "Setup complete!"
echo ""
