# claude-self-sync

Sync `~/.claude` between **your own machines** using two GitHub repos (one public, one private).
Drop-in bash script. No daemons, no plugins, no external services.

> Built for Claude Code users who develop on multiple machines and want their skills,
> agents, commands, rules, memory, and settings to follow them — without copy-paste hell.

## Why two repos?

| Repo | Visibility | Contains |
|------|-----------|----------|
| `claude-config` | public (or private — your choice) | `skills/ agents/ commands/ rules/ scripts/ hooks/hooks.json` |
| `claude-secrets` | **private** | `CLAUDE.md settings.json memory/ agent-memory/ services/` (anything with personal info / API keys) |

This split lets you share your skills/commands publicly (or with collaborators) while keeping
memory, system prompts, and credentials private.

## Quick start

```bash
# 1. Clone this script
git clone https://github.com/<your-username>/claude-self-sync.git
cp claude-self-sync/sync.sh ~/.claude/scripts/sync.sh
chmod +x ~/.claude/scripts/sync.sh

# 2. Create your two repos on GitHub:
#    https://github.com/new  → claude-config (public)
#    https://github.com/new  → claude-secrets (PRIVATE!)

# 3. Clone them locally
cd ~ && git clone git@github.com:<you>/claude-config.git
cd ~ && git clone git@github.com:<you>/claude-secrets.git

# 4. First push (from your "source of truth" machine)
~/.claude/scripts/sync.sh push

# 5. On the other machine, pull
~/.claude/scripts/sync.sh pull
```

## Commands

```
sync.sh push              # local → GitHub (commits + pushes both repos)
sync.sh pull              # GitHub → local (with delete-protection)
sync.sh pull --force      # bypass delete-protection (you confirmed they're disposable)
sync.sh status            # diff local vs repos, no writes
sync.sh push --dry-run    # preview push, no writes
sync.sh pull --dry-run    # preview pull, no writes
```

## Safety features

This isn't `cp -r ~/.claude/* ~/repo`. It's been battle-tested against real-world failure modes:

- **Push checks `git fetch` first** — refuses to push if remote is ahead, so you don't overwrite
  changes pushed from another machine.
- **Pull pre-flight delete-scan** — lists every file pull would delete, requires `--force` to
  proceed. Protects unpushed work on the receiving machine.
- **Auto tar.gz backup before pull** — saved to `~/.claude/backups/`, keeps last 3.
- **Push uses add-only rsync** (no `--delete`) — local-side accidents don't propagate to repo.
  To delete files cross-machine, delete in the repo and pull.
- **Excludes garbage by default** — `.git/ __pycache__/ *.pyc .DS_Store *.bak.* node_modules/
  .venv/ venv/`. No nested git repos accidentally pushed.
- **mkdir-based mutex** (`/tmp/claude-self-sync.lock.d`) — safe against double-invocation.
  Works without GNU `flock`.
- **openrsync (macOS) noise filter** — macOS's built-in openrsync occasionally emits
  `unlinkat: Directory not empty` warnings that don't affect the transfer; filtered out.

## What is NOT synced (and why)

| Excluded | Reason |
|----------|--------|
| `~/.mempalace/` (Chroma vector store) | Native HNSW segments are single-machine; cross-host sync corrupts the index |
| `.mcp.json` | Contains absolute paths that differ per machine; only `.mcp.json.example` template is synced |
| Nested `.git/` | Would balloon repo size and confuse git |
| `__pycache__/ *.pyc` | Local Python bytecode |
| `.DS_Store` | macOS Finder metadata |
| `node_modules/ .venv/ venv/` | Reinstall locally, don't sync |
| services' `.env` and `*.log` | Per-machine secrets and log noise |

## Configuration

Override paths via env vars (defaults shown):

```bash
CLAUDE_DIR="$HOME/.claude"
CONFIG_REPO="$HOME/claude-config"
SECRETS_REPO="$HOME/claude-secrets"
LAUNCHAGENTS_DIR="$HOME/Library/LaunchAgents"
```

## Comparison with similar projects

- **[Peter-Moriarty/claude-code-multi-machine-setup](https://github.com/Peter-Moriarty/claude-code-multi-machine-setup)** — uses Dropbox/iCloud filesystem-level sync. Conflicts on simultaneous writes, no delete-protection, no quality gates.
- **Plugin marketplaces** — designed for distributing skills to many users, not for personal multi-device sync.
- **`stow` / `chezmoi` / `dotfiles` repos** — generic dotfile managers; don't understand Claude Code's structure (skills vs memory vs agent-memory).

`claude-self-sync` is intentionally narrow: **just `~/.claude`, just for you, just two repos.**

## Requirements

- bash 4+ (macOS default `/bin/bash` 3.2 works for the tested paths)
- `rsync` (macOS openrsync works; GNU rsync also works)
- `git` 2.x with passwordless push to your repos (SSH key or PAT)
- macOS or Linux

## Limitations

- Tested on macOS 15. Linux should work but launchd plist auto-install is macOS-only (skipped on Linux).
- Single-user (`$HOME`-scoped). Multi-user setups need path overrides.
- No encryption beyond what GitHub provides — keep `claude-secrets` private.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

Built after debugging cross-machine drift, accidental deletes, and hours-lost incidents.
The safety-first defaults exist because each one corresponds to a real bug I hit.
