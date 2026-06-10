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
	if [ -d "$ROOT_DIR/opencode" ]; then
		cp -R "$ROOT_DIR/opencode" "$fixture/opencode"
	else
		mkdir -p "$fixture/opencode"
	fi
	rm -rf "$fixture/opencode/profiles.local" "$fixture/opencode/environments.local"
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
	mkdir -p "$fixture/environments/personal/opencode"
	cat >"$fixture/environments/personal/opencode/opencode.jsonc" <<'EOF'
{
  "plugin": ["legacy-tracked"]
}
EOF
}

write_local_legacy_profile() {
	local fixture="$1"
	mkdir -p "$fixture/environments.local/personal/opencode"
	cat >"$fixture/environments.local/personal/opencode/opencode.jsonc" <<'EOF'
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
	local fixture local_profile output
	fixture="$(new_fixture)"
	local_profile="$fixture/profiles.local/work-sample/opencode"
	write_global_config "$fixture"
	output="$(run_setup_with_stdin "$fixture" 'y\n' --env work-sample opencode 2>&1)"
	printf '%s' "$output" | grep -F "There is no existing profile with provided name" >/dev/null
	assert_file_exists "$local_profile/opencode.jsonc"
	assert_file_missing "$fixture/opencode/profiles.local/work-sample/opencode/opencode.jsonc"
	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
	assert_file_exists "$fixture/home/.config/opencode/opencode.jsonc"
	assert_file_contains "$local_profile/opencode.jsonc" '"plugin": ["from-global"]'
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"enabled_providers": ["github-copilot"]'
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"plugin": ["from-global"]'
}

test_baylor_bootstrap_uses_root_local_profile_storage() {
	local fixture local_profile output
	fixture="$(new_fixture)"
	local_profile="$fixture/profiles.local/baylor/opencode"
	rm -rf "$fixture/opencode"
	rm -rf "$fixture/profiles" "$fixture/profiles.local" "$fixture/environments" "$fixture/environments.local"
	write_global_config "$fixture"
	output="$(run_setup_with_stdin "$fixture" 'y\n' --env baylor opencode 2>&1)"
	printf '%s' "$output" | grep -F "Setup complete!" >/dev/null
	assert_file_exists "$local_profile/opencode.jsonc"
	assert_file_missing "$fixture/opencode"
	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"plugin": ["from-global"]'
	printf 'via-env-symlink\n' >"$fixture/home/.config/opencode/runtime.txt"
	assert_file_contains "$local_profile/runtime.txt" 'via-env-symlink'
}

test_env_uses_root_tracked_profile_without_root_agent_dir() {
	local fixture local_profile output
	fixture="$(new_fixture)"
	local_profile="$fixture/profiles.local/baylor/opencode"
	rm -rf "$fixture/opencode"
	mkdir -p "$fixture/profiles/baylor/opencode"
	printf '{"plugin":["root-profile"]}\n' >"$fixture/profiles/baylor/opencode/opencode.jsonc"

	output="$(run_setup "$fixture" --env baylor opencode 2>&1)"

	printf '%s' "$output" | grep -F "Setup complete!" >/dev/null
	assert_file_exists "$local_profile/opencode.jsonc"
	assert_file_contains "$local_profile/opencode.jsonc" 'root-profile'
	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
	assert_file_missing "$fixture/opencode"
}

test_baylor_bootstrap_backs_up_machine_config_before_symlink() {
	local fixture local_profile output backup_count
	fixture="$(new_fixture)"
	local_profile="$fixture/profiles.local/baylor/opencode"
	write_global_config "$fixture"
	output="$(run_setup_with_stdin "$fixture" 'y\n' --env baylor opencode 2>&1)"
	printf '%s' "$output" | grep -F "Backed up existing machine config:" >/dev/null
	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
	backup_count=0
	for backup in "$fixture/home/.config/opencode.backup."*; do
		[ -e "$backup" ] || continue
		backup_count=$((backup_count + 1))
		assert_file_contains "$backup/notes.txt" 'global-notes'
	done
	[ "$backup_count" -eq 1 ] || { echo "Expected one opencode backup, got $backup_count" >&2; exit 1; }
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
	assert_file_missing "$fixture/profiles.local/work-sample"
	assert_file_missing "$fixture/opencode/profiles.local/work-sample"
	assert_file_exists "$fixture/home/.config/opencode/opencode.jsonc"
}

test_granular_profile_sync() {
	local fixture
	fixture="$(new_fixture)"
	mkdir -p "$fixture/profiles/personal/opencode"
	cat >"$fixture/profiles/personal/opencode/opencode.jsonc" <<'EOF'
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
	mkdir -p "$fixture/profiles/personal/opencode"
	mkdir -p "$fixture/environments.local/personal/opencode"
	cat >"$fixture/profiles/personal/opencode/opencode.jsonc" <<'EOF'
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
	cat >"$fixture/environments.local/personal/opencode/opencode.jsonc" <<'EOF'
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
	mkdir -p "$fixture/profiles/personal/opencode"
	mkdir -p "$fixture/environments/personal/opencode"
	cat >"$fixture/profiles/personal/opencode/opencode.jsonc" <<'EOF'
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
	cat >"$fixture/environments/personal/opencode/opencode.jsonc" <<'EOF'
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
	assert_file_missing "$fixture/profiles.local/work-sample"
	assert_file_missing "$fixture/opencode/profiles.local/work-sample"
}

test_env_placeholder_bootstrap_allows_safe_values() {
	local fixture output
	fixture="$(new_fixture)"
	write_placeholder_global_config "$fixture"
	output="$(run_setup_with_stdin "$fixture" 'y\n' --env work-sample opencode 2>&1)"
	printf '%s' "$output" | grep -F "Setup complete!" >/dev/null
	assert_file_exists "$fixture/profiles.local/work-sample/opencode/opencode.jsonc"
	assert_file_contains "$fixture/profiles.local/work-sample/opencode/opencode.jsonc" 'Bearer ${DEMO_TOKEN}'
	assert_file_missing "$fixture/profiles.local/work-sample/opencode/.env.local"
	assert_file_missing "$fixture/opencode/profiles.local/work-sample/opencode/opencode.jsonc"
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
	assert_file_missing "$fixture/profiles.local/work-sample"
	assert_file_missing "$fixture/opencode/profiles.local/work-sample"
}

test_profile_scan_ignores_node_modules_non_object_json() {
	local fixture output
	fixture="$(new_fixture)"
	mkdir -p "$fixture/home/.config/opencode/node_modules/@babel/compat-data/data"
	mkdir -p "$fixture/home/.config/opencode/node_modules/@babel/helper-globals/data"
	mkdir -p "$fixture/home/.config/opencode/node_modules/node-releases/data/processed"
	cat >"$fixture/home/.config/opencode/opencode.jsonc" <<'EOF'
{
  "enabled_providers": ["github-copilot"],
  "plugin": ["baylor"]
}
EOF
	printf '["es.promise.finally", "es.array.flat"]\n' >"$fixture/home/.config/opencode/node_modules/@babel/compat-data/data/corejs3-shipped-proposals.json"
	printf '["AbortController", "AudioWorkletNode"]\n' >"$fixture/home/.config/opencode/node_modules/@babel/helper-globals/data/browser-upper.json"
	printf '["aggregateerror", "array"]\n' >"$fixture/home/.config/opencode/node_modules/@babel/helper-globals/data/builtin-lower.json"
	printf '["AggregateError", "Array"]\n' >"$fixture/home/.config/opencode/node_modules/@babel/helper-globals/data/builtin-upper.json"
	printf '[{"name":"node","version":"20.0.0"}]\n' >"$fixture/home/.config/opencode/node_modules/node-releases/data/processed/envs.json"

	output="$(run_setup_with_stdin "$fixture" 'y\n' --env baylor opencode 2>&1)"

	printf '%s' "$output" | grep -F "Setup complete!" >/dev/null
	assert_text_not_contains "$output" "Malformed JSON/JSONC"
	assert_file_exists "$fixture/home/.config/opencode/opencode.jsonc"
	assert_file_exists "$fixture/profiles.local/baylor/opencode/opencode.jsonc"
	assert_file_missing "$fixture/profiles.local/baylor/opencode/node_modules"
	assert_file_missing "$fixture/opencode/profiles.local/baylor/opencode"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"plugin": ['
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"baylor"'
}

test_profile_scan_checks_non_object_config_values() {
	local fixture output
	fixture="$(new_fixture)"
	mkdir -p "$fixture/home/.config/opencode/prompts"
	cat >"$fixture/home/.config/opencode/opencode.jsonc" <<'EOF'
{
  "enabled_providers": ["github-copilot"]
}
EOF
	printf '["Bearer sk-1234567890abcdef123456"]\n' >"$fixture/home/.config/opencode/prompts/unsafe.json"

	if output="$(run_setup_with_stdin "$fixture" 'y\n' --env work-sample opencode 2>&1)"; then
		echo "Expected secret scan to block non-object config secret" >&2
		exit 1
	fi
	printf '%s' "$output" | grep -F "Secret candidates found" >/dev/null
	assert_text_not_contains "$output" 'sk-1234567890abcdef123456'
	assert_file_missing "$fixture/profiles.local/work-sample"
	assert_file_missing "$fixture/opencode/profiles.local/work-sample"
}

test_existing_tracked_profile_sync_blocks_literal_secret() {
	local fixture output
	fixture="$(new_fixture)"
	mkdir -p "$fixture/profiles/baylor/opencode"
	mkdir -p "$fixture/home/.config/opencode"
	printf 'existing-machine-config\n' >"$fixture/home/.config/opencode/existing.txt"
	cat >"$fixture/profiles/baylor/opencode/opencode.jsonc" <<'EOF'
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

	if output="$(run_setup "$fixture" --env baylor opencode 2>&1)"; then
		echo "Expected existing tracked profile sync to block literal secret" >&2
		exit 1
	fi

	printf '%s' "$output" | grep -F "Secret candidates found" >/dev/null
	assert_text_not_contains "$output" 'sk-1234567890abcdef123456'
	assert_file_contains "$fixture/home/.config/opencode/existing.txt" 'existing-machine-config'
	assert_file_missing "$fixture/home/.config/opencode/opencode.jsonc"
}

test_existing_tracked_profile_sync_allows_env_placeholder() {
	local fixture local_profile output
	fixture="$(new_fixture)"
	local_profile="$fixture/profiles.local/baylor/opencode"
	mkdir -p "$fixture/profiles/baylor/opencode"
	cat >"$fixture/profiles/baylor/opencode/opencode.jsonc" <<'EOF'
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

	output="$(run_setup "$fixture" --env baylor opencode 2>&1)"

	printf '%s' "$output" | grep -F "Setup complete!" >/dev/null
	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" 'Bearer ${DEMO_TOKEN}'
}

test_existing_tracked_profile_sync_allows_long_agent_prompt() {
	local fixture output
	fixture="$(new_fixture)"
	mkdir -p "$fixture/profiles/baylor/opencode"
	cat >"$fixture/profiles/baylor/opencode/opencode.json" <<'EOF'
{
  "agent": {
    "gentle-orchestrator": {
      "description": "Routes work to focused subagents.",
      "prompt": "You are a precise orchestrator for complex engineering work. Coordinate diagnosis, implementation, review, and verification without exposing private values or changing unrelated files. Keep the user informed only when the information affects decisions."
    }
  }
}
EOF

	output="$(run_setup "$fixture" --env baylor opencode 2>&1)"

	printf '%s' "$output" | grep -F "Setup complete!" >/dev/null
	assert_text_not_contains "$output" "Secret candidates found"
	assert_file_contains "$fixture/home/.config/opencode/opencode.json" 'gentle-orchestrator'
}

test_existing_tracked_profile_sync_allows_permission_key_globs() {
	local fixture output
	fixture="$(new_fixture)"
	mkdir -p "$fixture/profiles/baylor/opencode"
	cat >"$fixture/profiles/baylor/opencode/opencode.jsonc" <<'EOF'
{
  "permission": {
    "read": {
      "*": "allow",
      "**/*.key": "deny",
      "**/*.pem": "deny"
    }
  }
}
EOF

	output="$(run_setup "$fixture" --env baylor opencode 2>&1)"

	printf '%s' "$output" | grep -F "Setup complete!" >/dev/null
	assert_text_not_contains "$output" "Secret candidates found"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"**/*.key": "deny"'
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"**/*.pem": "deny"'
}

test_existing_tracked_profile_sync_allows_permission_external_directory_patterns() {
	local fixture output
	fixture="$(new_fixture)"
	mkdir -p "$fixture/profiles/baylor/opencode"
	cat >"$fixture/profiles/baylor/opencode/opencode.jsonc" <<'EOF'
{
  "permission": {
    "external_directory": {
      "~/secrets/**": "deny",
      "~/work/**": "allow"
    }
  }
}
EOF

	output="$(run_setup "$fixture" --env baylor opencode 2>&1)"

	printf '%s' "$output" | grep -F "Setup complete!" >/dev/null
	assert_text_not_contains "$output" "Secret candidates found"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"~/secrets/**": "deny"'
}

test_existing_tracked_profile_sync_blocks_permission_authorization_header_secret() {
	local fixture output
	fixture="$(new_fixture)"
	mkdir -p "$fixture/profiles/baylor/opencode"
	cat >"$fixture/profiles/baylor/opencode/opencode.jsonc" <<'EOF'
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

	if output="$(run_setup "$fixture" --env baylor opencode 2>&1)"; then
		echo "Expected existing tracked profile sync to block authorization secret" >&2
		exit 1
	fi

	printf '%s' "$output" | grep -F "Secret candidates found" >/dev/null
	assert_text_not_contains "$output" 'sk-1234567890abcdef123456'
}

test_existing_tracked_profile_sync_blocks_permission_glob_literal_secret_value() {
	local fixture output
	fixture="$(new_fixture)"
	mkdir -p "$fixture/profiles/baylor/opencode"
	cat >"$fixture/profiles/baylor/opencode/opencode.jsonc" <<'EOF'
{
  "permission": {
    "read": {
      "**/*.key": "Bearer sk-1234567890abcdef123456"
    }
  }
}
EOF

	if output="$(run_setup "$fixture" --env baylor opencode 2>&1)"; then
		echo "Expected existing tracked profile sync to block literal secret under glob rule" >&2
		exit 1
	fi

	printf '%s' "$output" | grep -F "Secret candidates found" >/dev/null
	assert_text_not_contains "$output" 'sk-1234567890abcdef123456'
}

test_existing_tracked_profile_sync_ignores_package_lock() {
	local fixture local_profile output
	fixture="$(new_fixture)"
	local_profile="$fixture/profiles.local/baylor/opencode"
	mkdir -p "$fixture/profiles/baylor/opencode"
	cat >"$fixture/profiles/baylor/opencode/opencode.jsonc" <<'EOF'
{
  "enabled_providers": ["github-copilot"],
  "plugin": ["baylor"]
}
EOF
	cat >"$fixture/profiles/baylor/opencode/package-lock.json" <<'EOF'
{
  "name": "opencode-profile",
  "lockfileVersion": 3,
  "packages": {
    "node_modules/example": {
      "version": "1.0.0",
      "resolved": "https://registry.npmjs.org/example/-/example-1.0.0.tgz",
      "integrity": "sha512-yxZUM1MJrohp3R8isDAwXXrMU7swk9yLSfKBwxLkCpLxcKMr+v0YtEQ84a6Q9gVE8RxcJ9xIciAbDJo2r5xG8A=="
    }
  }
}
EOF

	output="$(run_setup "$fixture" --env baylor opencode 2>&1)"

	printf '%s' "$output" | grep -F "Setup complete!" >/dev/null
	assert_text_not_contains "$output" "Secret candidates found"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"baylor"'
	assert_file_missing "$fixture/home/.config/opencode/package-lock.json"
	assert_file_missing "$local_profile/package-lock.json"
}

test_existing_tracked_profile_sync_ignores_node_modules_non_object_json() {
	local fixture local_profile output
	fixture="$(new_fixture)"
	local_profile="$fixture/profiles.local/baylor/opencode"
	mkdir -p "$fixture/profiles/baylor/opencode/node_modules/@babel/compat-data/data"
	mkdir -p "$fixture/profiles/baylor/opencode/node_modules/@babel/helper-globals/data"
	mkdir -p "$fixture/profiles/baylor/opencode/node_modules/node-releases/data/processed"
	cat >"$fixture/profiles/baylor/opencode/opencode.jsonc" <<'EOF'
{
  "enabled_providers": ["github-copilot"],
  "plugin": ["baylor"]
}
EOF
	printf '["es.promise.finally", "es.array.flat"]\n' >"$fixture/profiles/baylor/opencode/node_modules/@babel/compat-data/data/corejs3-shipped-proposals.json"
	printf '["AbortController", "AudioWorkletNode"]\n' >"$fixture/profiles/baylor/opencode/node_modules/@babel/helper-globals/data/browser-upper.json"
	printf '["aggregateerror", "array"]\n' >"$fixture/profiles/baylor/opencode/node_modules/@babel/helper-globals/data/builtin-lower.json"
	printf '["AggregateError", "Array"]\n' >"$fixture/profiles/baylor/opencode/node_modules/@babel/helper-globals/data/builtin-upper.json"
	printf '[{"name":"node","version":"20.0.0"}]\n' >"$fixture/profiles/baylor/opencode/node_modules/node-releases/data/processed/envs.json"

	output="$(run_setup "$fixture" --env baylor opencode 2>&1)"

	printf '%s' "$output" | grep -F "Setup complete!" >/dev/null
	assert_text_not_contains "$output" "Malformed JSON/JSONC"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"baylor"'
	assert_file_missing "$fixture/home/.config/opencode/node_modules"
	assert_file_missing "$local_profile/node_modules"
}

test_existing_profile_sync_allows_local_overlay_literal_secret() {
	local fixture output
	fixture="$(new_fixture)"
	mkdir -p "$fixture/profiles/baylor/opencode"
	mkdir -p "$fixture/environments.local/baylor/opencode"
	cat >"$fixture/profiles/baylor/opencode/opencode.jsonc" <<'EOF'
{
  "plugin": ["tracked"],
  "settings": {
    "demo": {
      "base": "1"
    }
  }
}
EOF
	cat >"$fixture/environments.local/baylor/opencode/opencode.jsonc" <<'EOF'
{
  "plugin": ["local-overlay"],
  "mcp": {
    "demo": {
      "headers": {
        "Authorization": "Bearer sk-1234567890abcdef123456"
      }
    }
  }
}
EOF

	output="$(run_setup "$fixture" --env baylor opencode 2>&1)"

	printf '%s' "$output" | grep -F "Setup complete!" >/dev/null
	assert_text_not_contains "$output" 'sk-1234567890abcdef123456'
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"local-overlay"'
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"base": "1"'
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
	assert_file_exists "$fixture/profiles.local/work-sample/opencode/opencode.jsonc"
	assert_file_missing "$fixture/profiles.local/work-sample/opencode/.env"
	assert_file_missing "$fixture/profiles.local/work-sample/opencode/.env.local"
	assert_file_missing "$fixture/profiles.local/work-sample/opencode/notes.txt"
	assert_file_exists "$fixture/profiles.local/work-sample/opencode/plugins/keep-me/manifest.txt"
	assert_file_missing "$fixture/opencode/profiles.local/work-sample/opencode"
}

test_list_profiles_reports_root_profile_storage() {
	local fixture output
	fixture="$(new_fixture)"
	mkdir -p "$fixture/profiles/personal/opencode"
	mkdir -p "$fixture/profiles.local/baylor/opencode"
	output="$(run_setup "$fixture" --list-envs 2>&1)"
	printf '%s' "$output" | grep -F "personal/opencode (profiles)" >/dev/null
	printf '%s' "$output" | grep -F "baylor/opencode (profiles.local)" >/dev/null
}

test_top_level_sync_skips_root_profile_storage_dirs() {
	local fixture
	fixture="$(new_fixture)"
	mkdir -p "$fixture/profiles/baylor/opencode"
	mkdir -p "$fixture/profiles.local/baylor/opencode"
	mkdir -p "$fixture/environments/baylor/opencode"
	mkdir -p "$fixture/environments.local/baylor/opencode"
	printf 'tracked-profile\n' >"$fixture/profiles/baylor/opencode/profile.txt"
	printf 'local-profile\n' >"$fixture/profiles.local/baylor/opencode/profile.txt"
	printf 'legacy-profile\n' >"$fixture/environments/baylor/opencode/profile.txt"
	printf 'legacy-local-profile\n' >"$fixture/environments.local/baylor/opencode/profile.txt"

	run_setup "$fixture" >/dev/null

	assert_file_missing "$fixture/home/.config/profiles"
	assert_file_missing "$fixture/home/.config/profiles.local"
	assert_file_missing "$fixture/home/.config/environments"
	assert_file_missing "$fixture/home/.config/environments.local"
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

test_non_env_agent_sync_requires_root_agent_dir() {
	local fixture output
	fixture="$(new_fixture)"
	rm -rf "$fixture/opencode"

	if output="$(run_setup "$fixture" opencode 2>&1)"; then
		echo "Expected non-env agent sync to require root agent config directory" >&2
		exit 1
	fi

	printf '%s' "$output" | grep -F "Missing agent config directory: $fixture/opencode" >/dev/null
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
	assert_file_missing "$fixture/profiles.local/work-sample"
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
	assert_file_exists "$fixture/profiles.local/personal/opencode/opencode.jsonc"
	assert_file_missing "$fixture/opencode/profiles.local/personal/opencode/opencode.jsonc"
}

test_legacy_tracked_profile_materializes_canonical_storage() {
	local fixture
	fixture="$(new_fixture)"
	write_tracked_legacy_profile "$fixture"
	run_setup "$fixture" --env personal opencode >/dev/null
	assert_file_exists "$fixture/profiles/personal/opencode/opencode.jsonc"
	assert_file_contains "$fixture/profiles/personal/opencode/opencode.jsonc" '"legacy-tracked"'
	assert_file_missing "$fixture/opencode/profiles/personal/opencode/opencode.jsonc"
	assert_file_exists "$fixture/home/.config/opencode/opencode.jsonc"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" '"legacy-tracked"'
}

test_agent_nested_legacy_profile_materializes_root_canonical_storage() {
	local fixture
	fixture="$(new_fixture)"
	mkdir -p "$fixture/opencode/environments/personal/opencode"
	printf '{"plugin":["nested-legacy"]}\n' >"$fixture/opencode/environments/personal/opencode/opencode.jsonc"
	run_setup "$fixture" --env personal opencode >/dev/null
	assert_file_exists "$fixture/profiles/personal/opencode/opencode.jsonc"
	assert_file_contains "$fixture/profiles/personal/opencode/opencode.jsonc" 'nested-legacy'
	assert_file_exists "$fixture/home/.config/opencode/opencode.jsonc"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" 'nested-legacy'
}

test_switch_seeds_local_profile_and_symlinks_machine_config() {
	local fixture local_profile
	fixture="$(new_fixture)"
	mkdir -p "$fixture/profiles/consultancy/opencode"
	cat >"$fixture/profiles/consultancy/opencode/opencode.jsonc" <<'EOF'
{
  "plugin": ["consultancy"]
}
EOF
	local_profile="$fixture/profiles.local/consultancy/opencode"
	run_setup "$fixture" switch --profile consultancy --agent opencode >/dev/null
	assert_file_exists "$local_profile/opencode.jsonc"
	assert_file_contains "$local_profile/opencode.jsonc" '"consultancy"'
	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
}

test_switch_uses_root_local_profile_without_root_agent_dir() {
	local fixture local_profile
	fixture="$(new_fixture)"
	local_profile="$fixture/profiles.local/baylor/opencode"
	rm -rf "$fixture/opencode"
	mkdir -p "$local_profile"
	printf '{"plugin":["local-profile"]}\n' >"$local_profile/opencode.jsonc"

	run_setup "$fixture" switch --profile baylor --agent opencode >/dev/null

	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
	assert_file_contains "$fixture/home/.config/opencode/opencode.jsonc" 'local-profile'
	assert_file_missing "$fixture/opencode"
}

test_switch_repoints_existing_profile_symlink() {
	local fixture personal_profile consultancy_profile
	fixture="$(new_fixture)"
	mkdir -p "$fixture/profiles/personal/opencode"
	mkdir -p "$fixture/profiles/consultancy/opencode"
	printf '{"plugin":["personal"]}\n' >"$fixture/profiles/personal/opencode/opencode.jsonc"
	printf '{"plugin":["consultancy"]}\n' >"$fixture/profiles/consultancy/opencode/opencode.jsonc"
	personal_profile="$fixture/profiles.local/personal/opencode"
	consultancy_profile="$fixture/profiles.local/consultancy/opencode"
	run_setup "$fixture" switch --profile personal --agent opencode >/dev/null
	assert_symlink_target "$fixture/home/.config/opencode" "$personal_profile"
	run_setup "$fixture" switch --profile consultancy --agent opencode >/dev/null
	assert_symlink_target "$fixture/home/.config/opencode" "$consultancy_profile"
}

test_env_profile_repoints_existing_profile_symlink() {
	local fixture personal_profile baylor_profile
	fixture="$(new_fixture)"
	mkdir -p "$fixture/profiles/personal/opencode"
	mkdir -p "$fixture/profiles/baylor/opencode"
	printf '{"plugin":["personal"]}\n' >"$fixture/profiles/personal/opencode/opencode.jsonc"
	printf '{"plugin":["baylor"]}\n' >"$fixture/profiles/baylor/opencode/opencode.jsonc"
	personal_profile="$fixture/profiles.local/personal/opencode"
	baylor_profile="$fixture/profiles.local/baylor/opencode"
	run_setup "$fixture" --env personal opencode >/dev/null
	assert_symlink_target "$fixture/home/.config/opencode" "$personal_profile"
	run_setup "$fixture" --env baylor opencode >/dev/null
	assert_symlink_target "$fixture/home/.config/opencode" "$baylor_profile"
}

test_switch_machine_config_edits_affect_local_profile() {
	local fixture local_profile
	fixture="$(new_fixture)"
	mkdir -p "$fixture/profiles/personal/opencode"
	printf '{"plugin":["personal"]}\n' >"$fixture/profiles/personal/opencode/opencode.jsonc"
	local_profile="$fixture/profiles.local/personal/opencode"
	run_setup "$fixture" switch --profile personal --agent opencode >/dev/null
	printf 'via-symlink\n' >"$fixture/home/.config/opencode/runtime.txt"
	assert_file_contains "$local_profile/runtime.txt" 'via-symlink'
}

test_switch_blocks_existing_non_symlink_machine_config() {
	local fixture output
	fixture="$(new_fixture)"
	mkdir -p "$fixture/profiles/personal/opencode"
	printf '{"plugin":["personal"]}\n' >"$fixture/profiles/personal/opencode/opencode.jsonc"
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
	mkdir -p "$fixture/profiles/work/opencode"
	cat >"$fixture/profiles/work/opencode/opencode.jsonc" <<'EOF'
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
	assert_file_missing "$fixture/profiles.local/work"
	assert_file_missing "$fixture/opencode/profiles.local/work"
	assert_file_missing "$fixture/home/.config/opencode"
}

test_switch_allows_tracked_profile_env_placeholder() {
	local fixture local_profile
	fixture="$(new_fixture)"
	mkdir -p "$fixture/profiles/work/opencode"
	cat >"$fixture/profiles/work/opencode/opencode.jsonc" <<'EOF'
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
	local_profile="$fixture/profiles.local/work/opencode"
	run_setup "$fixture" switch --profile work --agent opencode >/dev/null
	assert_file_contains "$local_profile/opencode.jsonc" 'Bearer ${DEMO_TOKEN}'
	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
}

test_switch_legacy_tracked_profile_materializes_before_activation() {
	local fixture local_profile
	fixture="$(new_fixture)"
	write_tracked_legacy_profile "$fixture"
	local_profile="$fixture/profiles.local/personal/opencode"
	run_setup "$fixture" switch --profile personal --agent opencode >/dev/null
	assert_file_exists "$fixture/profiles/personal/opencode/opencode.jsonc"
	assert_file_contains "$fixture/profiles/personal/opencode/opencode.jsonc" '"legacy-tracked"'
	assert_file_missing "$fixture/opencode/profiles/personal/opencode/opencode.jsonc"
	assert_file_contains "$local_profile/opencode.jsonc" '"legacy-tracked"'
	assert_symlink_target "$fixture/home/.config/opencode" "$local_profile"
}

test_switch_mixed_legacy_tracked_base_and_local_overlay_activation() {
	local fixture local_profile
	fixture="$(new_fixture)"
	mkdir -p "$fixture/environments/personal/opencode"
	mkdir -p "$fixture/environments.local/personal/opencode"
	cat >"$fixture/environments/personal/opencode/opencode.jsonc" <<'EOF'
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
	cat >"$fixture/environments.local/personal/opencode/opencode.jsonc" <<'EOF'
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
	printf 'base-notes\n' >"$fixture/environments/personal/opencode/base.txt"
	printf 'local-notes\n' >"$fixture/environments.local/personal/opencode/local.txt"
	local_profile="$fixture/profiles.local/personal/opencode"

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
test_baylor_bootstrap_uses_root_local_profile_storage
test_env_uses_root_tracked_profile_without_root_agent_dir
test_missing_profile_decline_leaves_no_changes
test_granular_profile_sync
test_secret_scan_blocks_bootstrap
test_env_placeholder_bootstrap_allows_safe_values
test_malformed_jsonc_blocks_bootstrap
test_profile_scan_ignores_node_modules_non_object_json
test_profile_scan_checks_non_object_config_values
test_existing_tracked_profile_sync_blocks_literal_secret
test_existing_tracked_profile_sync_allows_env_placeholder
test_existing_tracked_profile_sync_allows_long_agent_prompt
test_existing_tracked_profile_sync_allows_permission_key_globs
test_existing_tracked_profile_sync_allows_permission_external_directory_patterns
test_existing_tracked_profile_sync_blocks_permission_authorization_header_secret
test_existing_tracked_profile_sync_blocks_permission_glob_literal_secret_value
test_existing_tracked_profile_sync_ignores_package_lock
test_existing_tracked_profile_sync_ignores_node_modules_non_object_json
test_existing_profile_sync_allows_local_overlay_literal_secret
test_bootstrap_excludes_env_and_unsafe_material
test_list_profiles_reports_root_profile_storage
test_top_level_sync_skips_root_profile_storage_dirs
test_non_env_opencode_config_fails_closed_without_choice
test_non_env_opencode_config_overwrites_on_explicit_choice
test_non_env_agent_sync_requires_root_agent_dir
test_non_interactive_cancel_handles_read_failure
test_direct_setup_executes_help
test_granular_jsonc_merge_combines_canonical_and_legacy_layers
test_whole_profile_jsonc_merge_combines_canonical_and_legacy_layers
test_legacy_local_only_profile_sync_works
test_legacy_tracked_profile_materializes_canonical_storage
test_agent_nested_legacy_profile_materializes_root_canonical_storage
test_switch_seeds_local_profile_and_symlinks_machine_config
test_switch_uses_root_local_profile_without_root_agent_dir
test_switch_repoints_existing_profile_symlink
test_env_profile_repoints_existing_profile_symlink
test_switch_machine_config_edits_affect_local_profile
test_switch_blocks_existing_non_symlink_machine_config
test_switch_blocks_tracked_profile_literal_secret
test_switch_allows_tracked_profile_env_placeholder
test_switch_legacy_tracked_profile_materializes_before_activation
test_switch_mixed_legacy_tracked_base_and_local_overlay_activation

echo "setup.sh integration tests passed."
