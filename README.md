# agent-switcher

`agent-switcher` manages reusable agent configuration profiles from one repo and activates them on a machine by syncing or symlinking into `~/.config`.

It keeps shared profile files in `profiles/` and private machine-specific files in `profiles.local/`. The private directory is ignored by git and is the right place for local overrides, work-only configuration, and secrets.

## Quick Start

```bash
agent-switcher init
agent-switcher sync --profile personal --agent opencode
agent-switcher switch --profile work --agent opencode
agent-switcher doctor
```

## Install Shape

The planned install path is Homebrew:

```bash
brew install agent-switcher
```

The Homebrew formula is currently a local draft in `Formula/agent-switcher.rb`. It still has TODO release URL and SHA values because there is no release artifact yet.

## Initialize A Config Repo

Run:

```bash
agent-switcher init
```

The command prompts for:

| Prompt | Meaning |
|--------|---------|
| `Agents repo location` | Parent directory or full target directory for the config repo. |
| `Repo/config name` | Simple directory name to create or reuse. |

`init` creates the repo structure, initializes git, and writes `~/.config/agent-switcher/config.json` with the configured repo path.

It refuses to use a non-empty incompatible directory. Existing directories must be empty or already look like an `agent-switcher` repo with `profiles/`, `profiles.local/`, and `.git/`.

## Sync And Switch

Sync a profile for one agent:

```bash
agent-switcher sync --profile personal --agent opencode
```

Switch the active machine config to a profile:

```bash
agent-switcher switch --profile work --agent opencode
```

Check the installation and configured repo without changing files:

```bash
agent-switcher doctor
```

## Repository Layout

```text
profiles/
  personal/
    opencode/
      opencode.jsonc
profiles.local/
  personal/
    opencode/
      opencode.jsonc
```

| Path | Purpose |
|------|---------|
| `profiles/` | Tracked, shareable profile defaults. |
| `profiles.local/` | Private machine-local overlays and active profile material. Ignored by git. |

Root-level profile storage is canonical. Older `environments/` layouts are still handled by the compatibility engine in `setup.sh`.

## Safety Model

`setup.sh` remains the compatibility engine. The `agent-switcher` CLI reads the configured repo path, then delegates sync and switch behavior to `setup.sh` with that repo path pinned.

Global config reconciliation fails closed:

| Situation | Behavior |
|-----------|----------|
| Existing global config differs during guarded file sync | Prompts before overwriting, backing up, or importing global changes into the repo. |
| Existing machine config blocks profile activation | Refuses replacement unless the env-profile flow explicitly reconciles it. |
| Tracked profile contains likely literal secrets | Blocks sync or switch and keeps existing machine config untouched. |
| Profile-local config contains private values | Allowed because `profiles.local/` is ignored and machine-private. |

`profiles.local/` must stay private. Do not commit it.

## License

No license has been selected yet. Do not publish or redistribute this project as open source until a license is chosen.
