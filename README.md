# imperStatusLine

A custom status line for [Claude Code](https://docs.claude.com/en/docs/claude-code/overview), inspired by Daniel Miessler's [PAI](https://github.com/danielmiessler/Personal_AI_Infrastructure) status line, but **standalone** — no PAI framework required.

![imperStatusLine screenshot](./screenshot.png)

## What you get

```
─ imperStatusLine ─ skill: <output_style>
TIME: 17:42   │   MODEL: Opus 4.7 (1M)   │   EFFORT: default   │   COST: $4.03
ENV:  CC 2.1.131   │   SK 304   │   Hooks 2   │   Plugins 2   │   CMD 168
──────────────────────────────────────────────────────────────────────────
● CONTEXT: ◉◉◉◉◉◉◉◉◉◯◯◯◯◯◯◯◯◯◯◯◯◯◯◯◯◯◯◯◯◯◯◯◯◯◯◯  12%
──────────────────────────────────────────────────────────────────────────
⚡ USAGE: 5H 14%   ↺22:00
──────────────────────────────────────────────────────────────────────────
◆ PWD: my-project   │   Branch: main   │   Age: 2h   │   Mod: 3   │   Sync: ↑1
──────────────────────────────────────────────────────────────────────────
◎ MEMORY: 📁 12 Files   │   🧠 28723 claude-mem   │   📚 141 Wiki   │   🔌 2 Plugins
──────────────────────────────────────────────────────────────────────────
▸ TASKS: 2 bg   │   1 agent
```

## Sections explained

| Section | Source | Notes |
|---|---|---|
| **TIME** | system clock | local time |
| **MODEL** | stdin JSON `model.id` | shortened: `Opus 4.7`, `Sonnet 4.6`, etc. with `(1M)` flag for 1M-context models |
| **EFFORT** | env `CLAUDE_THINKING_LEVEL`, `THINKING_BUDGET`, then `settings.json` | falls back to `default` |
| **COST** | stdin JSON `cost.total_cost_usd` | session cost in USD |
| **ENV** | `settings.json`, `~/.claude/plugins/` | Claude Code version + counts |
| **SK** | filesystem walk | total skills installed (across plugins) |
| **Hooks** | `settings.json → hooks` | hook count |
| **Plugins** | `~/.claude/plugins/installed_plugins.json` | installed plugins |
| **CMD** | filesystem walk | total slash-commands available |
| **CONTEXT** | parses transcript JSONL | bar fills based on token consumption (1M cap for `*-1m` models, 200K otherwise) |
| **USAGE 5H** | `ccusage` (optional) | quota of the current 5-hour rolling window — only shown if `ccusage` is installed |
| **PWD** | stdin JSON `cwd` | last segment of the path |
| **Branch / Age / Mod / Sync** | `git` | only when cwd is inside a git repo |
| **MEMORY** | filesystem + sqlite | 4 sub-counts (see below) |
| **TASKS** | parses transcript JSONL | only shown when there are pending background tasks or agents |

### MEMORY breakdown
- **📁 Files** — files in `~/.claude/projects/<derived-key>/memory/` for the current project (auto-memory dir)
- **🧠 claude-mem** — observations count from `~/.claude-mem/claude-mem.db` (SQLite)
- **📚 Wiki** — `*.md` files in `$CWD/wiki/` (project-local) or `~/wiki/` (global fallback)
- **🔌 Plugins** — installed Claude Code plugins

## Installation

### 1. Save the script

Save `imperStatusLine.sh` to `~/.claude/imperStatusLine.sh`:

```bash
curl -sL https://raw.githubusercontent.com/imperugo/imperStatusLine/main/imperStatusLine.sh \
  -o ~/.claude/imperStatusLine.sh
chmod +x ~/.claude/imperStatusLine.sh
```

(or `git clone https://github.com/imperugo/imperStatusLine.git` and copy `imperStatusLine.sh` from there)

### 2. Wire it into Claude Code

Edit `~/.claude/settings.json` and set the `statusLine` field:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash $HOME/.claude/imperStatusLine.sh",
    "padding": 0
  }
}
```

If you're using `jq`, this one-liner does it for you:

```bash
jq '.statusLine = {"type":"command","command":"bash $HOME/.claude/imperStatusLine.sh","padding":0}' \
  ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
```

> **Tip:** before editing, take a backup → `cp ~/.claude/settings.json ~/.claude/settings.json.bak`

### 3. Open (or restart) Claude Code

The new status line shows up at the next refresh.

## Optional dependencies

| Tool | Required? | Purpose | Install |
|---|---|---|---|
| `jq` | **yes** | JSON parsing | `brew install jq` |
| `sqlite3` | optional | claude-mem observation count | macOS includes it; otherwise `brew install sqlite` |
| `ccusage` | optional | the `USAGE 5H` quota line | nothing to install — runs via `npx -y ccusage@latest` automatically (first run downloads it in background, so the USAGE line appears at the next refresh, not the current one) |

## Caching strategy

Because the status line runs at every Claude Code refresh, expensive lookups are cached in `/tmp/imperstatusline-<user>/`:

| Cache | TTL | What it stores |
|---|---|---|
| `counts.sh` | 30s | skill / hook / plugin / slash-command counts |
| `ccusage.json` | 60s | output of `ccusage blocks --active` |
| `tasks.txt` | 3s | active background-task and agent counts |

The `ccusage` fetch runs **fire-and-forget** in the background, so it never blocks the status line — even when `npx` has to download the package the first time.

## Compatibility

- ✅ macOS (tested on Darwin 25.x)
- ✅ Linux (uses portable POSIX subset, no GNU-only utilities)
- ⚠️ Windows / WSL — should work with WSL bash; native Windows untested

The script is careful to avoid macOS-vs-Linux pitfalls (no `tac`, no `timeout`, no GNU `find` extensions).

## Rollback

If you don't like it:

```bash
# revert to whatever you had before
cp ~/.claude/settings.json.bak ~/.claude/settings.json
```

Or, if you want to go back to the default Claude Code status line, simply remove the `statusLine` field from `settings.json`.

## Credits

- Layout, color palette, and "render-as-block-with-separators" approach borrowed from [PAI v5.0.0](https://github.com/danielmiessler/Personal_AI_Infrastructure) by Daniel Miessler — credit where credit is due.
- This version strips PAI-specific bits (Workflows, Algorithm, Learning, Quote, Banner, …) and keeps only what's universal to any Claude Code setup, plus a few additions: `EFFORT`, `COST`, `CMD`, and the conditional `TASKS` line.

## License

MIT — do whatever you like with it, attribution appreciated.
