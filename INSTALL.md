# Install

## 1. Drop the script in

```bash
mkdir -p ~/.claude/scripts
curl -fsSL https://raw.githubusercontent.com/<your-username>/claude-self-sync/main/sync.sh \
  -o ~/.claude/scripts/sync.sh
chmod +x ~/.claude/scripts/sync.sh
```

## 2. Create your two repos

Go to https://github.com/new and create:

- `claude-config` (public OR private — your call; contains skills/agents/commands/rules/scripts)
- `claude-secrets` (**MUST BE PRIVATE** — contains memory, system prompts, settings)

Initialize them empty (no README).

## 3. Clone them next to your `~/.claude`

```bash
cd ~ && git clone git@github.com:<you>/claude-config.git
cd ~ && git clone git@github.com:<you>/claude-secrets.git
```

(Use SSH or set up a PAT — push must work without typing a password.)

## 4. First push (from your "good" machine)

```bash
~/.claude/scripts/sync.sh push
```

You'll see two commits + pushes go through.

## 5. Pull on the other machine

```bash
# After installing the script and cloning both repos on machine 2:
~/.claude/scripts/sync.sh pull
```

If the pull tries to delete files (because machine 2 has stuff machine 1 doesn't),
you'll see a list and have to either:
- `~/.claude/scripts/sync.sh push` first (to ship machine 2's local stuff up)
- `~/.claude/scripts/sync.sh pull --force` (you confirmed they're disposable)

## 6. (Optional) Wire it as a Claude Code slash command

Drop a `~/.claude/commands/sync.md` like:

```markdown
# Sync Claude Config

Run `~/.claude/scripts/sync.sh $ARGUMENTS` and report the result.
- empty / "pull" → `pull`
- "push" → `push`
- "status" → `status`
- forward `--dry-run` and `--force` if present
```

Then `/sync push` and `/sync pull` work inside Claude Code.

## Troubleshooting

**`flock: command not found`** — you have an old version. Get the latest `sync.sh`; the
current version uses mkdir-based mutex.

**`unlinkat: Directory not empty`** — macOS openrsync warning. The current `sync.sh`
filters this; if you see it, you have an old version.

**`落後 remote N commit`** — another machine pushed first. Run `~/.claude/scripts/sync.sh pull`
before pushing.

**Pull deletes look scary** — that's the safety feature working. Verify the listed files
aren't your unpushed work, then either push first or `--force`.
