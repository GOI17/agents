#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

assert_file_exists() {
	local path="$1"
	[ -e "$path" ] || { echo "Expected file to exist: $path" >&2; exit 1; }
}

assert_file_missing() {
	local path="$1"
	[ ! -e "$path" ] || { echo "Expected file to be missing: $path" >&2; exit 1; }
}

assert_symlink_target() {
	local path="$1" expected="$2" actual
	[ -L "$path" ] || { echo "Expected symlink: $path" >&2; exit 1; }
	actual="$(readlink "$path")"
	[ "$actual" = "$expected" ] || { echo "Expected $path to point at $expected, got $actual" >&2; exit 1; }
}

assert_file_contains() {
	local path="$1"
	local expected="$2"
	grep -F "$expected" "$path" >/dev/null || { echo "Expected '$expected' in $path" >&2; exit 1; }
}

assert_file_not_contains() {
	local path="$1"
	local unexpected="$2"
	! grep -F "$unexpected" "$path" >/dev/null || { echo "Did not expect '$unexpected' in $path" >&2; exit 1; }
}

assert_text_not_contains() {
	local text="$1"
	local unexpected="$2"
	! printf '%s' "$text" | grep -F "$unexpected" >/dev/null || { echo "Did not expect '$unexpected' in output" >&2; exit 1; }
}

new_fixture() {
	local fixture
	fixture="$(mktemp -d "${TMPDIR:-/tmp}/agents-setup.XXXXXX")"
	fixture="$(cd "$fixture" && pwd)"
	mkdir -p "$fixture/home/.config"
	cp "$ROOT_DIR/setup.sh" "$fixture/setup.sh"
	cp -R "$ROOT_DIR/opencode" "$fixture/opencode"
	chmod +x "$fixture/setup.sh"
	echo "$fixture"
}

write_global_config() {
	local fixture="$1"
	mkdir -p "$fixture/home/.config/opencode"
	cat >"$fixture/home/.config/opencode/opencode.jsonc" <<'EOF'
{
  "enabled_providers": ["github-copilot"],
  "plugin": ["from-global"]
}
EOF
	printf 'global-notes\n' >"$fixture/home/.config/opencode/notes.txt"
}

write_secret_global_config() {
	local fixture="$1"
	mkdir -p "$fixture/home/.config/opencode"
	cat >"$fixture/home/.config/opencode/opencode.jsonc" <<'EOF'
{
  "mcp": {
    "demo": {
      "headers": {
        "Authorization": "Bearer sk-1234567890abcdef123456"
      }
    }
  }
}
EOF
}

write_placeholder_global_config() {
	local fixture="$1"
	mkdir -p "$fixture/home/.config/opencode"
	cat >"$fixture/home/.config/opencode/opencode.jsonc" <<'EOF'
{
  "mcp": {
    "demo": {
      "headers": {
        "Authorization": "Bearer ${DEMO_TOKEN}"
      }
    }
  }
}
EOF
	printf 'DEMO_TOKEN=ignored-value\n' >"$fixture/home/.config/opencode/.env.local"
}

write_tracked_legacy_profile() {
	local fixture="$1"
	mkdir -p "$fixture/opencode/environments/personal/opencode"
	cat >"$fixture/opencode/environments/personal/opencode/opencode.jsonc" <<'EOF'
{
  "plugin": ["legacy-tracked"]
}
EOF
}

write_local_legacy_profile() {
	local fixture="$1"
	mkdir -p "$fixture/opencode/environments.local/personal/opencode"
	cat >"$fixture/opencode/environments.local/personal/opencode/opencode.jsonc" <<'EOF'
{
  "plugin": ["legacy-local"]
}
EOF
}

run_setup() {
	local fixture="$1"
	shift
	HOME="$fixture/home" "$fixture/setup.sh" "$@"
}

run_setup_with_stdin() {
	local fixture="$1" input="$2"
	shift 2
	printf '%b' "$input" | HOME="$fixture/home" "$fixture/setup.sh" "$@"
}

test_missing_profile_accept_bootstraps() {
	local fixture output
	fixture="$(new_fixture)"
	write_global_config "$fixture"
	output="$(run_setup_with_stdin "$fixture" 'y\n' --env work-sample opencode 2>&1)"
	printf '%s' "$output" | grep -F "There is no existing profile with provided name" >/dev/null
	assert_file_exists "$fixture/opencode/profiles.local/work-sample/opencode/opencode.jsonc"
	assert_file_exists "$fixture/home/.config/opencode/opencode.jsonc"
	assert_file_contains "$fixture/opencode/profiles.local/work-sample/opencode/opencode.jsonc" '"plugin": ["from-global"]'
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"enabled_providers": ["github-copilot"]'
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"plugin": ["from-global"]'
}

test_missing_profile_decline_leaves_no_changes() {
	local fixture output
	fixture="$(new_fixture)"
	write_global_config "$fixture"
	if output="$(run_setup_with_stdin "$fixture" 'n\n' --env work-sample opencode 2>&1)"; then
		echo "Expected decline to fail closed" >&2
		exit 1
	fi
	printf '%s' "$output" | grep -F "Profile creation cancelled." >/dev/null
	assert_file_missing "$fixture/opencode/profiles.local/work-sample"
	assert_file_exists "$fixture/home/.config/opencode/opencode.jsonc"
}

test_granular_profile_sync() {
	local fixture
	fixture="$(new_fixture)"
	mkdir -p "$fixture/opencode/profiles/personal/opencode"
	cat >"$fixture/opencode/profiles/personal/opencode/opencode.jsonc" <<'EOF'
{
  "enabled_providers": ["github-copilot"],
  "plugin": ["granular"]
}
EOF
	run_setup "$fixture" --env personal opencode opencode.jsonc >/dev/null
	assert_file_exists "$fixture/home/.config/opencode/opencode.jsonc"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"plugin": ["granular"]'
}

test_granular_jsonc_merge_combines_canonical_and_legacy_layers() {
	local fixture
	fixture="$(new_fixture)"
	mkdir -p "$fixture/opencode/profiles/personal/opencode"
	mkdir -p "$fixture/opencode/environments.local/personal/opencode"
	cat >"$fixture/opencode/profiles/personal/opencode/opencode.jsonc" <<'EOF'
{
  "enabled_providers": ["github-copilot"],
  "mcp": {
    "demo": {
      "headers": {
        "X-Canonical": "1"
      }
    }
  }
}
EOF
	cat >"$fixture/opencode/environments.local/personal/opencode/opencode.jsonc" <<'EOF'
{
  "plugin": ["legacy-granular"],
  "mcp": {
    "demo": {
      "headers": {
        "X-Legacy": "2"
      }
    }
  }
}
EOF
	run_setup "$fixture" --env personal opencode opencode.jsonc >/dev/null
	assert_file_exists "$fixture/home/.config/opencode/opencode.jsonc"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"enabled_providers": ['
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"github-copilot"'
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"plugin": ['
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"legacy-granular"'
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"X-Canonical": "1"'
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"X-Legacy": "2"'
}

test_whole_profile_jsonc_merge_combines_canonical_and_legacy_layers() {
	local fixture
	fixture="$(new_fixture)"
	mkdir -p "$fixture/opencode/profiles/personal/opencode"
	mkdir -p "$fixture/opencode/environments/personal/opencode"
	cat >"$fixture/opencode/profiles/personal/opencode/opencode.jsonc" <<'EOF'
{
  "enabled_providers": ["github-copilot"],
  "mcp": {
    "demo": {
      "headers": {
        "X-Canonical": "1"
      }
    }
  }
}
EOF
	cat >"$fixture/opencode/environments/personal/opencode/opencode.jsonc" <<'EOF'
{
  "plugin": ["legacy-whole"],
  "mcp": {
    "demo": {
      "headers": {
        "X-Legacy": "2"
      }
    }
  }
}
EOF
	run_setup "$fixture" --env personal opencode >/dev/null
	assert_file_exists "$fixture/home/.config/opencode/opencode.jsonc"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"enabled_providers": ['
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"github-copilot"'
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"plugin": ['
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"legacy-whole"'
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"X-Canonical": "1"'
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"X-Legacy": "2"'
}

test_secret_scan_blocks_bootstrap() {
	local fixture output
	fixture="$(new_fixture)"
	write_secret_global_config "$fixture"
	if output="$(run_setup_with_stdin "$fixture" 'y\n' --env work-sample opencode 2>&1)"; then
		echo "Expected secret scan to block bootstrap" >&2
		exit 1
	fi
	printf '%s' "$output" | grep -F "Secret candidates found" >/dev/null
	assert_text_not_contains "$output" 'sk-1234567890abcdef123456'
	assert_file_missing "$fixture/opencode/profiles.local/work-sample"
}

test_env_placeholder_bootstrap_allows_safe_values() {
	local fixture output
	fixture="$(new_fixture)"
	write_placeholder_global_config "$fixture"
	output="$(run_setup_with_stdin "$fixture" 'y\n' --env work-sample opencode 2>&1)"
	printf '%s' "$output" | grep -F "Setup complete!" >/dev/null
	assert_file_exists "$fixture/opencode/profiles.local/work-sample/opencode/opencode.jsonc"
	assert_file_contains "$fixture/opencode/profiles.local/work-sample/opencode/opencode.jsonc" 'Bearer ${DEMO_TOKEN}'
	assert_file_missing "$fixture/opencode/profiles.local/work-sample/opencode/.env.local"
}

test_malformed_jsonc_blocks_bootstrap() {
	local fixture output
	fixture="$(new_fixture)"
	mkdir -p "$fixture/home/.config/opencode"
	cat >"$fixture/home/.config/opencode/opencode.jsonc" <<'EOF'
{
  "mcp": {
    "demo": {
      "headers": {
        "Authorization": "Bearer"
      }
    }
  }
EOF
	if output="$(run_setup_with_stdin "$fixture" 'y\n' --env work-sample opencode 2>&1)"; then
		echo "Expected malformed JSONC to block bootstrap" >&2
		exit 1
	fi
	printf '%s' "$output" | grep -F "Malformed JSON/JSONC" >/dev/null
	assert_file_missing "$fixture/opencode/profiles.local/work-sample"
}

test_bootstrap_excludes_env_and_unsafe_material() {
	local fixture
	fixture="$(new_fixture)"
	mkdir -p "$fixture/home/.config/opencode/plugins/keep-me"
	cat >"$fixture/home/.config/opencode/opencode.jsonc" <<'EOF'
{
  "enabled_providers": ["github-copilot"]
}
EOF
	printf 'secret=1\n' >"$fixture/home/.config/opencode/.env"
	printf 'ignored=1\n' >"$fixture/home/.config/opencode/.env.local"
	printf 'notes\n' >"$fixture/home/.config/opencode/notes.txt"
	printf 'plugin\n' >"$fixture/home/.config/opencode/plugins/keep-me/manifest.txt"
	run_setup_with_stdin "$fixture" 'y\n' --env work-sample opencode >/dev/null
	assert_file_exists "$fixture/opencode/profiles.local/work-sample/opencode/opencode.jsonc"
	assert_file_missing "$fixture/opencode/profiles.local/work-sample/opencode/.env"
	assert_file_missing "$fixture/opencode/profiles.local/work-sample/opencode/.env.local"
	assert_file_missing "$fixture/opencode/profiles.local/work-sample/opencode/notes.txt"
	assert_file_exists "$fixture/opencode/profiles.local/work-sample/opencode/plugins/keep-me/manifest.txt"
}

test_non_env_opencode_config_fails_closed_without_choice() {
	local fixture output
	fixture="$(new_fixture)"
	mkdir -p "$fixture/opencode"
	cat >"$fixture/opencode/opencode.jsonc" <<'EOF'
{
  "enabled_providers": ["github-copilot"],
  "plugin": ["root-level"]
}
EOF
	mkdir -p "$fixture/home/.config/opencode"
	cat >"$fixture/home/.config/opencode/opencode.jsonc" <<'EOF'
{
  "enabled_providers": ["github-copilot"],
  "plugin": ["global-root"]
}
EOF
	if output="$(run_setup "$fixture" opencode opencode.jsonc 2>&1)"; then
		echo "Expected guarded sync to fail closed without explicit choice" >&2
		exit 1
	fi
	printf '%s' "$output" | grep -F "Cancelled. Choose 1, 2, or 3." >/dev/null
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"plugin": ["global-root"]'
	assert_file_not_contains "$fixture/home/.config/opencode/opencode.jsonc" '"plugin": ["root-level"]'
}

test_non_env_opencode_config_overwrites_on_explicit_choice() {
	local fixture
	fixture="$(new_fixture)"
	mkdir -p "$fixture/opencode"
	cat >"$fixture/opencode/opencode.jsonc" <<'EOF'
{
  "enabled_providers": ["github-copilot"],
  "plugin": ["root-level"]
}
EOF
	mkdir -p "$fixture/home/.config/opencode"
	cat >"$fixture/home/.config/opencode/opencode.jsonc" <<'EOF'
{
  "enabled_providers": ["github-copilot"],
  "plugin": ["global-root"]
}
EOF
	run_setup_with_stdin "$fixture" '1\n' opencode opencode.jsonc >/dev/null
	assert_file_exists "$fixture/home/.config/opencode/opencode.jsonc"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"plugin": ["root-level"]'
}

test_non_interactive_cancel_handles_read_failure() {
	local fixture output
	fixture="$(new_fixture)"
	write_global_config "$fixture"
	if output="$(HOME="$fixture/home" "$fixture/setup.sh" --env work-sample opencode </dev/null 2>&1)"; then
		echo "Expected non-interactive prompt to fail closed" >&2
		exit 1
	fi
	printf '%s' "$output" | grep -F "Profile creation cancelled." >/dev/null
	assert_file_missing "$fixture/opencode/profiles.local/work-sample"
}

test_direct_setup_executes_help() {
	local fixture
	fixture="$(new_fixture)"
	"$fixture/setup.sh" --help >/dev/null
}

test_legacy_local_only_profile_sync_works() {
	local fixture
	fixture="$(new_fixture)"
	write_local_legacy_profile "$fixture"
	run_setup "$fixture" --env personal opencode >/dev/null
	assert_file_exists "$fixture/home/.config/opencode/opencode.jsonc"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"plugin": ['
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"legacy-local"'
	assert_file_exists "$fixture/opencode/profiles.local/personal/opencode/opencode.jsonc"
}

test_legacy_tracked_profile_materializes_canonical_storage() {
	local fixture
	fixture="$(new_fixture)"
	write_tracked_legacy_profile "$fixture"
	run_setup "$fixture" --env personal opencode >/dev/null
	assert_file_exists "$fixture/opencode/profiles/personal/opencode/opencode.jsonc"
	assert_file_contains "$fixture/opencode/profiles/personal/opencode/opencode.jsonc" '"legacy-tracked"'
	assert_file_exists "$fixture/home/.config/opencode/opencode.jsonc"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"legacy-tracked"'
}

test_switch_seeds_local_profile_and_symlinks_machine_config() {
	local fixture local_profile
	fixture="$(new_fixture)"
	mkdir -p "$fixture/opencode/profiles/consultancy/opencode"
	cat >"$fixture/opencode/profiles/consultancy/opencode/opencode.jsonc" <<'EOF'
{
  "plugin": ["consultancy"]
}
EOF
	local_profile="$fixture/opencode/profiles.local/consultancy/opencode"
	run_setup "$fixture" switch --profile consultancy --agent opencode >/dev/null
	assert_file_exists "$local_profile/opencode.jsonc"
	assert_file_contains "$local_profile/opencode.jsonc" '"consultancy"'
	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
}

test_switch_repoints_existing_profile_symlink() {
	local fixture personal_profile consultancy_profile
	fixture="$(new_fixture)"
	mkdir -p "$fixture/opencode/profiles/personal/opencode"
	mkdir -p "$fixture/opencode/profiles/consultancy/opencode"
	printf '{"plugin":["personal"]}\n' >"$fixture/opencode/profiles/personal/opencode/opencode.jsonc"
	printf '{"plugin":["consultancy"]}\n' >"$fixture/opencode/profiles/consultancy/opencode/opencode.jsonc"
	personal_profile="$fixture/opencode/profiles.local/personal/opencode"
	consultancy_profile="$fixture/opencode/profiles.local/consultancy/opencode"
	run_setup "$fixture" switch --profile personal --agent opencode >/dev/null
	assert_symlink_target "$fixture/home/.config/opencode" "$personal_profile"
	run_setup "$fixture" switch --profile consultancy --agent opencode >/dev/null
	assert_symlink_target "$fixture/home/.config/opencode" "$consultancy_profile"
}

test_switch_machine_config_edits_affect_local_profile() {
	local fixture local_profile
	fixture="$(new_fixture)"
	mkdir -p "$fixture/opencode/profiles/personal/opencode"
	printf '{"plugin":["personal"]}\n' >"$fixture/opencode/profiles/personal/opencode/opencode.jsonc"
	local_profile="$fixture/opencode/profiles.local/personal/opencode"
	run_setup "$fixture" switch --profile personal --agent opencode >/dev/null
	printf 'via-symlink\n' >"$fixture/home/.config/opencode/runtime.txt"
	assert_file_contains "$local_profile/runtime.txt" 'via-symlink'
}

test_switch_blocks_existing_non_symlink_machine_config() {
	local fixture output
	fixture="$(new_fixture)"
	mkdir -p "$fixture/opencode/profiles/personal/opencode"
	printf '{"plugin":["personal"]}\n' >"$fixture/opencode/profiles/personal/opencode/opencode.jsonc"
	mkdir -p "$fixture/home/.config/opencode"
	printf 'existing\n' >"$fixture/home/.config/opencode/existing.txt"
	if output="$(run_setup "$fixture" switch --profile personal --agent opencode 2>&1)"; then
		echo "Expected switch to fail closed for existing non-symlink config" >&2
		exit 1
	fi
	printf '%s' "$output" | grep -F "Refusing to replace existing machine config" >/dev/null
	assert_file_exists "$fixture/home/.config/opencode/existing.txt"
	[ ! -L "$fixture/home/.config/opencode" ] || { echo "Expected machine config to remain a directory" >&2; exit 1; }
}

test_switch_blocks_tracked_profile_literal_secret() {
	local fixture output
	fixture="$(new_fixture)"
	mkdir -p "$fixture/opencode/profiles/work/opencode"
	cat >"$fixture/opencode/profiles/work/opencode/opencode.jsonc" <<'EOF'
{
  "mcp": {
    "demo": {
      "headers": {
        "Authorization": "Bearer sk-1234567890abcdef123456"
      }
    }
  }
}
EOF
	if output="$(run_setup "$fixture" switch --profile work --agent opencode 2>&1)"; then
		echo "Expected switch to block tracked profile secret" >&2
		exit 1
	fi
	printf '%s' "$output" | grep -F "Secret candidates found" >/dev/null
	assert_text_not_contains "$output" 'sk-1234567890abcdef123456'
	assert_file_missing "$fixture/opencode/profiles.local/work"
	assert_file_missing "$fixture/home/.config/opencode"
}

test_switch_allows_tracked_profile_env_placeholder() {
	local fixture local_profile
	fixture="$(new_fixture)"
	mkdir -p "$fixture/opencode/profiles/work/opencode"
	cat >"$fixture/opencode/profiles/work/opencode/opencode.jsonc" <<'EOF'
{
  "mcp": {
    "demo": {
      "headers": {
        "Authorization": "Bearer ${DEMO_TOKEN}"
      }
    }
  }
}
EOF
	local_profile="$fixture/opencode/profiles.local/work/opencode"
	run_setup "$fixture" switch --profile work --agent opencode >/dev/null
	assert_file_contains "$local_profile/opencode.jsonc" 'Bearer ${DEMO_TOKEN}'
	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
}

test_switch_legacy_tracked_profile_materializes_before_activation() {
	local fixture local_profile
	fixture="$(new_fixture)"
	write_tracked_legacy_profile "$fixture"
	local_profile="$fixture/opencode/profiles.local/personal/opencode"
	run_setup "$fixture" switch --profile personal --agent opencode >/dev/null
	assert_file_exists "$fixture/opencode/profiles/personal/opencode/opencode.jsonc"
	assert_file_contains "$fixture/opencode/profiles/personal/opencode/opencode.jsonc" '"legacy-tracked"'
	assert_file_contains "$local_profile/opencode.jsonc" '"legacy-tracked"'
	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
}

test_switch_mixed_legacy_tracked_base_and_local_overlay_activation() {
	local fixture local_profile
	fixture="$(new_fixture)"
	mkdir -p "$fixture/opencode/environments/personal/opencode"
	mkdir -p "$fixture/opencode/environments.local/personal/opencode"
	cat >"$fixture/opencode/environments/personal/opencode/opencode.jsonc" <<'EOF'
{
  "enabled_providers": ["github-copilot"],
  "plugin": ["legacy-tracked"],
  "settings": {
    "demo": {
      "base": "1",
      "override": "base"
    }
  }
}
EOF
	cat >"$fixture/opencode/environments.local/personal/opencode/opencode.jsonc" <<'EOF'
{
  "plugin": ["legacy-local"],
  "settings": {
    "demo": {
      "override": "local",
      "local": "2"
    }
  }
}
EOF
	printf 'base-notes\n' >"$fixture/opencode/environments/personal/opencode/base.txt"
	printf 'local-notes\n' >"$fixture/opencode/environments.local/personal/opencode/local.txt"
	local_profile="$fixture/opencode/profiles.local/personal/opencode"

	run_setup "$fixture" switch --profile personal --agent opencode >/dev/null

	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
	assert_file_contains "$local_profile/opencode.jsonc" '"enabled_providers": ['
	assert_file_contains "$local_profile/opencode.jsonc" '"github-copilot"'
	assert_file_contains "$local_profile/opencode.jsonc" '"plugin": ['
	assert_file_contains "$local_profile/opencode.jsonc" '"legacy-local"'
	assert_file_contains "$local_profile/opencode.jsonc" '"base": "1"'
	assert_file_contains "$local_profile/opencode.jsonc" '"override": "local"'
	assert_file_contains "$local_profile/opencode.jsonc" '"local": "2"'
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"base": "1"'
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"override": "local"'
	assert_file_contains "$local_profile/base.txt" 'base-notes'
	assert_file_contains "$local_profile/local.txt" 'local-notes'
}

test_missing_profile_accept_bootstraps
test_missing_profile_decline_leaves_no_changes
test_granular_profile_sync
test_secret_scan_blocks_bootstrap
test_env_placeholder_bootstrap_allows_safe_values
test_malformed_jsonc_blocks_bootstrap
test_bootstrap_excludes_env_and_unsafe_material
test_non_env_opencode_config_fails_closed_without_choice
test_non_env_opencode_config_overwrites_on_explicit_choice
test_non_interactive_cancel_handles_read_failure
test_direct_setup_executes_help
test_granular_jsonc_merge_combines_canonical_and_legacy_layers
test_whole_profile_jsonc_merge_combines_canonical_and_legacy_layers
test_legacy_local_only_profile_sync_works
test_legacy_tracked_profile_materializes_canonical_storage
test_switch_seeds_local_profile_and_symlinks_machine_config
test_switch_repoints_existing_profile_symlink
test_switch_machine_config_edits_affect_local_profile
test_switch_blocks_existing_non_symlink_machine_config
test_switch_blocks_tracked_profile_literal_secret
test_switch_allows_tracked_profile_env_placeholder
test_switch_legacy_tracked_profile_materializes_before_activation
test_switch_mixed_legacy_tracked_base_and_local_overlay_activation

echo "setup.sh integration tests passed."
