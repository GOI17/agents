#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

assert_file_exists() {
	local path="$1"
	[ -e "$path" ] || { echo "Expected file to exist: $path" >&2; exit 1; }
}

assert_dir_exists() {
	local path="$1"
	[ -d "$path" ] || { echo "Expected directory to exist: $path" >&2; exit 1; }
}

assert_symlink_target() {
	local path="$1" expected="$2" actual
	[ -L "$path" ] || { echo "Expected symlink: $path" >&2; exit 1; }
	actual="$(readlink "$path")"
	[ "$actual" = "$expected" ] || { echo "Expected $path to point at $expected, got $actual" >&2; exit 1; }
}

assert_file_contains() {
	local path="$1" expected="$2"
	grep -F "$expected" "$path" >/dev/null || { echo "Expected '$expected' in $path" >&2; exit 1; }
}

assert_output_contains() {
	local output="$1" expected="$2"
	printf '%s' "$output" | grep -F "$expected" >/dev/null || { echo "Expected '$expected' in output" >&2; exit 1; }
}

assert_config_repo_path() {
	local config_path="$1" expected="$2" actual
	actual="$(python3 - "$config_path" <<'PY'
import json
import sys
from pathlib import Path

print(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["repo_path"])
PY
)"
	[ "$actual" = "$expected" ] || { echo "Expected repo_path $expected, got $actual" >&2; exit 1; }
}

assert_no_deleted_tracked_files() {
	local deleted
	deleted="$(git -C "$ROOT_DIR" ls-files -d)"
	[ -z "$deleted" ] || { echo "Expected no deleted tracked files, got: $deleted" >&2; exit 1; }
}

resolve_path() {
	local path="$1"
	python3 - "$path" <<'PY'
import sys
from pathlib import Path

print(Path(sys.argv[1]).resolve(strict=False))
PY
}

new_fixture() {
	local fixture
	fixture="$(mktemp -d "${TMPDIR:-/tmp}/agent-switcher-cli.XXXXXX")"
	fixture="$(cd "$fixture" && pwd)"
	mkdir -p "$fixture/home/.config" "$fixture/install/bin"
	cp "$ROOT_DIR/setup.sh" "$fixture/install/setup.sh"
	cp "$ROOT_DIR/bin/agent-switcher" "$fixture/install/bin/agent-switcher"
	chmod +x "$fixture/install/bin/agent-switcher" "$fixture/install/setup.sh"
	echo "$fixture"
}

run_cli_with_stdin() {
	local fixture="$1" input="$2"
	shift 2
	printf '%b' "$input" | HOME="$fixture/home" "$fixture/install/bin/agent-switcher" "$@"
}

run_cli() {
	local fixture="$1"
	shift
	HOME="$fixture/home" "$fixture/install/bin/agent-switcher" "$@"
}

run_symlinked_cli() {
	local fixture="$1"
	shift
	HOME="$fixture/home" "$fixture/prefix/bin/agent-switcher" "$@"
}

test_init_with_absolute_parent_path() {
	local fixture parent repo config output
	fixture="$(new_fixture)"
	parent="$fixture/repos"
	repo="$(resolve_path "$parent/personal-agents-configs")"
	mkdir -p "$parent"

	output="$(run_cli_with_stdin "$fixture" "$parent\npersonal-agents-configs\n" init 2>&1)"

	assert_dir_exists "$repo/profiles"
	assert_dir_exists "$repo/profiles.local"
	assert_file_exists "$repo/.gitignore"
	assert_file_exists "$repo/README.md"
	assert_dir_exists "$repo/.git"
	config="$fixture/home/.config/agent-switcher/config.json"
	assert_file_exists "$config"
	assert_config_repo_path "$config" "$repo"
	assert_output_contains "$output" "agent-switcher sync --profile <profile> --agent <agent>"
	assert_output_contains "$output" "agent-switcher switch --profile <profile> --agent <agent>"
}

test_init_with_dot_relative_to_fixture_cwd() {
	local fixture workdir repo output
	fixture="$(new_fixture)"
	workdir="$fixture/workdir"
	repo="$(resolve_path "$workdir/personal-agents-configs")"
	mkdir -p "$workdir"

	output="$(cd "$workdir" && run_cli_with_stdin "$fixture" ".\npersonal-agents-configs\n" init 2>&1)"

	assert_dir_exists "$repo/profiles"
	assert_dir_exists "$repo/profiles.local"
	assert_dir_exists "$repo/.git"
	assert_config_repo_path "$fixture/home/.config/agent-switcher/config.json" "$repo"
	assert_output_contains "$output" "Initialized agent-switcher repo: $repo"
}

test_init_location_that_already_includes_repo_name() {
	local fixture repo output
	fixture="$(new_fixture)"
	repo="$(resolve_path "$fixture/personal-agents-configs")"

	output="$(run_cli_with_stdin "$fixture" "$repo/\npersonal-agents-configs\n" init 2>&1)"

	assert_dir_exists "$repo/profiles"
	assert_dir_exists "$repo/profiles.local"
	assert_output_contains "$output" "Initialized agent-switcher repo: $repo"
}

write_configured_repo() {
	local fixture="$1" repo="$2"
	mkdir -p "$repo/profiles/baylor/opencode"
	mkdir -p "$fixture/home/.config/agent-switcher"
	printf '{"repo_path":"%s"}\n' "$repo" >"$fixture/home/.config/agent-switcher/config.json"
	cat >"$repo/profiles/baylor/opencode/opencode.jsonc" <<'EOF'
{
  "plugin": ["from-configured-repo"]
}
EOF
}

test_sync_uses_configured_repo_path() {
	local fixture repo local_profile
	fixture="$(new_fixture)"
	repo="$(resolve_path "$fixture/configured-repo")"
	local_profile="$repo/profiles.local/baylor/opencode"
	write_configured_repo "$fixture" "$repo"

	run_cli "$fixture" sync --profile baylor --agent opencode >/dev/null

	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"from-configured-repo"'
}

test_switch_uses_configured_repo_path() {
	local fixture repo local_profile
	fixture="$(new_fixture)"
	repo="$(resolve_path "$fixture/configured-repo")"
	local_profile="$repo/profiles.local/baylor/opencode"
	write_configured_repo "$fixture" "$repo"

	run_cli "$fixture" switch --profile baylor --agent opencode >/dev/null

	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"from-configured-repo"'
}

test_symlinked_cli_uses_bundled_setup_for_sync_and_switch() {
	local fixture repo local_profile
	fixture="$(new_fixture)"
	repo="$(resolve_path "$fixture/configured-repo")"
	local_profile="$repo/profiles.local/baylor/opencode"
	write_configured_repo "$fixture" "$repo"
	mkdir -p "$fixture/prefix/bin"
	ln -s "../../install/bin/agent-switcher" "$fixture/prefix/bin/agent-switcher"
	cat >"$fixture/prefix/setup.sh" <<'EOF'
#!/bin/bash
echo "wrong setup.sh from Homebrew prefix" >&2
exit 99
EOF
	chmod +x "$fixture/prefix/setup.sh"

	run_symlinked_cli "$fixture" sync --profile baylor --agent opencode >/dev/null

	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"from-configured-repo"'
	rm -rf "$fixture/home/.config/opencode"

	run_symlinked_cli "$fixture" switch --profile baylor --agent opencode >/dev/null

	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"from-configured-repo"'
}

assert_no_deleted_tracked_files

test_init_with_absolute_parent_path
test_init_with_dot_relative_to_fixture_cwd
test_init_location_that_already_includes_repo_name
test_sync_uses_configured_repo_path
test_switch_uses_configured_repo_path
test_symlinked_cli_uses_bundled_setup_for_sync_and_switch

assert_no_deleted_tracked_files

echo "agent-switcher init integration tests passed."
