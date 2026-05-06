#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# imperStatusLine — custom statusline for Claude Code
# Inspired by PAI (danielmiessler/Personal_AI_Infrastructure) v5.0.0
# Standalone, no PAI dependencies. Adds effort, cost, cmd count, and task tracking.
#
# ─── Layout ───────────────────────────────────────────────────────────────────
#   ─ imperStatusLine ─ skill: <output_style>
#   TIME │ MODEL │ EFFORT │ COST
#   ENV  │ SK │ Hooks │ Plugins │ CMD
#   ──────────────────────────────────
#   ● CONTEXT bar (full width, gradient green→yellow→red)
#   ──────────────────────────────────
#   ⚡ USAGE 5H (only if ccusage cache is populated)
#   ──────────────────────────────────
#   ◆ PWD │ Branch │ Age │ Mod │ Sync   (or "(not a git repo)")
#   ──────────────────────────────────
#   ◎ MEMORY: Files │ claude-mem │ Wiki │ Plugins
#   ──────────────────────────────────
#   ▸ TASKS: N bg │ N agent   (only if active)
#
# ─── Setup ────────────────────────────────────────────────────────────────────
#   1. Save this script as ~/.claude/imperStatusLine.sh
#   2. chmod +x ~/.claude/imperStatusLine.sh
#   3. In ~/.claude/settings.json set:
#        "statusLine": {
#          "type": "command",
#          "command": "bash $HOME/.claude/imperStatusLine.sh",
#          "padding": 0
#        }
#
# ─── Optional dependencies ────────────────────────────────────────────────────
#   - jq          (required) — JSON parsing
#   - sqlite3     (optional) — counts claude-mem observations
#   - npx + ccusage (optional) — populates the USAGE 5H quota line
#                                first run takes ~30s in background, then cached
#
# ─── Colors ───────────────────────────────────────────────────────────────────
#   256-color ANSI palette borrowed from PAI v5.0.0
#   - title gradient: light blue → blue-violet → lilac
#   - labels in cyan, values in azure
#   - gradient bars: green (<60%) → yellow (60-80%) → red (≥80%)
#
# ═══════════════════════════════════════════════════════════════════════════════

set -o pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CACHE PATHS
# ─────────────────────────────────────────────────────────────────────────────
USER_TAG="${USER:-anon}"
CACHE_DIR="/tmp/imperstatusline-${USER_TAG}"
mkdir -p "$CACHE_DIR" 2>/dev/null

CCUSAGE_CACHE="$CACHE_DIR/ccusage.json"
COUNTS_CACHE="$CACHE_DIR/counts.sh"
TASKS_CACHE="$CACHE_DIR/tasks.txt"

CCUSAGE_TTL=60   # seconds
COUNTS_TTL=30
TASKS_TTL=3

# ─────────────────────────────────────────────────────────────────────────────
# COLORS (256-color ANSI palette inspired by PAI)
# ─────────────────────────────────────────────────────────────────────────────
C_TITLE_1="\033[38;5;75m"     # azzurro chiaro — "imper"
C_TITLE_2="\033[38;5;111m"    # azzurro/violaceo — "Status"
C_TITLE_3="\033[38;5;147m"    # lilla — "Line"

C_LABEL="\033[38;5;111m"      # cyan — etichette di sezione (LOC, ENV, ...)
C_VALUE="\033[38;5;75m"       # azzurro — valori numerici/versioni
C_VALUE_DIM="\033[38;5;245m"  # grigio chiaro — testo secondario

C_GREEN="\033[38;5;114m"      # verde — buono / basso uso
C_YELLOW="\033[38;5;179m"     # giallo — attenzione
C_RED="\033[38;5;167m"        # rosso — alto uso

C_PURPLE="\033[38;5;141m"     # viola — memory keywords
C_PINK="\033[38;5;175m"       # rosa — accenti

C_SEP="\033[38;5;240m"        # grigio scuro — separatori │
C_LINE="\033[38;5;238m"       # grigio scurissimo — linee orizzontali ─
C_DIM="\033[38;5;240m"        # grigio per dim text

R="\033[0m"                    # reset
B="\033[1m"                    # bold

# Helper: colora una percentuale (0-100) verde→giallo→rosso
color_pct() {
    local pct="$1"
    if   [ "$pct" -lt 60 ]; then printf '%b' "$C_GREEN"
    elif [ "$pct" -lt 80 ]; then printf '%b' "$C_YELLOW"
    else                          printf '%b' "$C_RED"
    fi
}

# Detect terminal width (fallback 100)
TERM_COLS="${COLUMNS:-0}"
[ "$TERM_COLS" -le 0 ] && TERM_COLS=$(tput cols 2>/dev/null || echo 100)
[ "$TERM_COLS" -le 0 ] && TERM_COLS=100

# Print a thin horizontal separator line, full terminal width
sep() {
    local i line=""
    for ((i=0; i<TERM_COLS; i++)); do line="${line}─"; done
    printf '%b%s%b\n' "$C_LINE" "$line" "$R"
}

# ─────────────────────────────────────────────────────────────────────────────
# READ STDIN JSON (Claude Code passes session info)
# ─────────────────────────────────────────────────────────────────────────────
INPUT="$(cat)"

j() { echo "$INPUT" | jq -r "$1" 2>/dev/null; }

MODEL_ID="$(j '.model.id // "unknown"')"
MODEL_NAME="$(j '.model.display_name // .model.id // "unknown"')"
SESSION_ID="$(j '.session_id // ""')"
TRANSCRIPT="$(j '.transcript_path // ""')"
CWD="$(j '.workspace.current_dir // .cwd // ""')"
CC_VERSION="$(j '.version // ""')"
COST_USD="$(j '.cost.total_cost_usd // 0')"
OUTPUT_STYLE="$(j '.output_style.name // "default"')"

# ─────────────────────────────────────────────────────────────────────────────
# COUNTS — skills, hooks, commands, plugins (cached, mtime-based)
# ─────────────────────────────────────────────────────────────────────────────
SETTINGS_FILE="$HOME/.claude/settings.json"
PLUGINS_DIR="$HOME/.claude/plugins"
INSTALLED_PLUGINS="$PLUGINS_DIR/installed_plugins.json"

needs_refresh() {
    local cache="$1" ttl="$2"
    [ ! -f "$cache" ] && return 0
    local age
    age=$(( $(date +%s) - $(stat -f %m "$cache" 2>/dev/null || stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    [ "$age" -gt "$ttl" ]
}

if needs_refresh "$COUNTS_CACHE" "$COUNTS_TTL"; then
    sk_count=$(find "$PLUGINS_DIR/marketplaces" -type d -name "skills" -maxdepth 6 2>/dev/null \
        | xargs -I{} find {} -mindepth 1 -maxdepth 2 -name "SKILL.md" 2>/dev/null \
        | wc -l | tr -d ' ')
    [ -z "$sk_count" ] || [ "$sk_count" = "0" ] && sk_count=$(find "$PLUGINS_DIR/marketplaces" -type d -maxdepth 6 -name "skills" 2>/dev/null \
        | xargs -I{} find {} -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | wc -l | tr -d ' ')

    cmd_count=$(find "$PLUGINS_DIR/marketplaces" -path "*/commands/*.md" 2>/dev/null \
        | wc -l | tr -d ' ')
    cmd_user=$(find "$HOME/.claude/commands" -maxdepth 3 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    cmd_count=$(( ${cmd_count:-0} + ${cmd_user:-0} ))

    hooks_count=$(jq -r '
        [(.hooks // {}) | to_entries[] | .value | if type=="array" then .[] else . end | (.hooks // []) | length] | add // 0
    ' "$SETTINGS_FILE" 2>/dev/null)
    [ -z "$hooks_count" ] && hooks_count=0

    plugin_count=$(jq -r 'if type=="object" then (keys | length) else length end' "$INSTALLED_PLUGINS" 2>/dev/null)
    [ -z "$plugin_count" ] && plugin_count=0

    {
        echo "SK_COUNT=${sk_count:-0}"
        echo "CMD_COUNT=${cmd_count:-0}"
        echo "HOOKS_COUNT=${hooks_count:-0}"
        echo "PLUGIN_COUNT=${plugin_count:-0}"
    } > "$COUNTS_CACHE"
fi
# shellcheck disable=SC1090
source "$COUNTS_CACHE"

# ─────────────────────────────────────────────────────────────────────────────
# CONTEXT % from transcript (token estimate)
# ─────────────────────────────────────────────────────────────────────────────
# Claude Opus 4.7 1M: 1_000_000 token budget; standard models: 200_000
case "$MODEL_ID" in
    *"1m"*|*"1M"*|*opus-4-7*) CTX_MAX=1000000 ;;
    *) CTX_MAX=200000 ;;
esac

CTX_USED=0
if [ -f "$TRANSCRIPT" ]; then
    # Use the latest "usage" entry from the transcript (Claude Code logs cumulative tokens).
    # macOS lacks `tac`, so we use `tail -N` and process line-by-line with `inputs`.
    CTX_USED=$(tail -200 "$TRANSCRIPT" 2>/dev/null | jq -rn '
        [inputs | select(.message?.usage?) | .message.usage |
            ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.output_tokens // 0))
        ] | if length > 0 then max else 0 end
    ' 2>/dev/null)
    [ -z "$CTX_USED" ] && CTX_USED=0
fi

CTX_PCT=$(( CTX_USED * 100 / CTX_MAX ))
[ "$CTX_PCT" -gt 100 ] && CTX_PCT=100

# Render context bar — width adapts to terminal width
render_ctx_bar() {
    local pct="$1" cells i fill
    # Reserve ~16 chars for "● CONTEXT: " prefix and "  XX%" suffix
    cells=$(( TERM_COLS - 18 ))
    [ "$cells" -lt 10 ] && cells=10
    [ "$cells" -gt 200 ] && cells=200
    fill=$(( pct * cells / 100 ))
    printf '%b' "$(color_pct "$pct")"
    for ((i=0; i<fill; i++)); do printf '◉'; done
    printf '%b' "$C_DIM"
    for ((i=fill; i<cells; i++)); do printf '◯'; done
    printf '%b' "$R"
}

# ─────────────────────────────────────────────────────────────────────────────
# USAGE 5H quota via ccusage (cached 60s)
# ─────────────────────────────────────────────────────────────────────────────
USAGE_5H_PCT="--"
USAGE_5H_RESET=""

if needs_refresh "$CCUSAGE_CACHE" "$CCUSAGE_TTL"; then
    # Fire-and-forget: never block the statusline. Cache populates async,
    # next refresh will pick it up. All output suppressed.
    LOCK="$CCUSAGE_CACHE.lock"
    if ! [ -f "$LOCK" ] || [ "$(find "$LOCK" -mmin +2 2>/dev/null)" ]; then
        : > "$LOCK"
        (
            npx -y ccusage@latest blocks --json --active > "$CCUSAGE_CACHE.tmp" 2>/dev/null \
                && [ -s "$CCUSAGE_CACHE.tmp" ] \
                && mv "$CCUSAGE_CACHE.tmp" "$CCUSAGE_CACHE" \
                || rm -f "$CCUSAGE_CACHE.tmp"
            rm -f "$LOCK"
        ) </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
    fi
fi

if [ -f "$CCUSAGE_CACHE" ]; then
    # ccusage `blocks --active` returns the current 5h block with tokens vs quota
    USAGE_5H_PCT=$(jq -r '
        .blocks[0] // {} |
        if .totalTokens and .tokenLimitStatus then
            ((.totalTokens / (.tokenLimitStatus.limit // 1)) * 100 | floor)
        else "--" end
    ' "$CCUSAGE_CACHE" 2>/dev/null)
    USAGE_5H_RESET=$(jq -r '.blocks[0].endTime // ""' "$CCUSAGE_CACHE" 2>/dev/null \
        | python3 -c "import sys,datetime; t=sys.stdin.read().strip(); print(datetime.datetime.fromisoformat(t.replace('Z','+00:00')).astimezone().strftime('%H:%M')) if t else ''" 2>/dev/null)
    [ -z "$USAGE_5H_PCT" ] && USAGE_5H_PCT="--"
fi

# ─────────────────────────────────────────────────────────────────────────────
# EFFORT (thinking budget)
# ─────────────────────────────────────────────────────────────────────────────
EFFORT="default"
if [ -n "$CLAUDE_THINKING_LEVEL" ]; then
    EFFORT="$CLAUDE_THINKING_LEVEL"
elif [ -n "$THINKING_BUDGET" ]; then
    EFFORT="$THINKING_BUDGET"
else
    e=$(jq -r '.thinkingBudget // .thinking.level // .env.MAX_THINKING_TOKENS // empty' "$SETTINGS_FILE" 2>/dev/null)
    [ -n "$e" ] && EFFORT="$e"
fi
EFFORT_LOWER=$(echo "$EFFORT" | tr '[:upper:]' '[:lower:]')
case "$EFFORT_LOWER" in
    max|high|*32000*|*64000*) EFFORT_COLOR="$C_RED" ;;
    medium|*16000*)            EFFORT_COLOR="$C_YELLOW" ;;
    low|*8000*|*4000*)         EFFORT_COLOR="$C_GREEN" ;;
    *)                          EFFORT_COLOR="$C_VALUE_DIM" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# GIT info
# ─────────────────────────────────────────────────────────────────────────────
GIT_BRANCH=""; GIT_AGE=""; GIT_MOD=""; GIT_SYNC=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
    cd "$CWD" 2>/dev/null
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        GIT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
        last_commit_ts=$(git log -1 --format=%ct 2>/dev/null)
        if [ -n "$last_commit_ts" ]; then
            now=$(date +%s)
            diff=$(( now - last_commit_ts ))
            if   [ "$diff" -lt 60 ];      then GIT_AGE="${diff}s"
            elif [ "$diff" -lt 3600 ];    then GIT_AGE="$(( diff / 60 ))m"
            elif [ "$diff" -lt 86400 ];   then GIT_AGE="$(( diff / 3600 ))h"
            else                                GIT_AGE="$(( diff / 86400 ))d"
            fi
        fi
        GIT_MOD=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        ahead_behind=$(git rev-list --left-right --count "@{upstream}...HEAD" 2>/dev/null)
        if [ -n "$ahead_behind" ]; then
            behind=$(echo "$ahead_behind" | awk '{print $1}')
            ahead=$(echo "$ahead_behind" | awk '{print $2}')
            sync=""
            [ "$ahead" -gt 0 ] && sync="↑${ahead}"
            [ "$behind" -gt 0 ] && sync="${sync}↓${behind}"
            GIT_SYNC="${sync:-=}"
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# MEMORY counts — proposta A: Files | claude-mem | Wiki | Plugins
# ─────────────────────────────────────────────────────────────────────────────
# Files: auto-memory dir for the *current* project (derived from cwd)
MEM_PROJECT_KEY="$(echo "$CWD" | sed 's|/|-|g')"
MEM_DIR="$HOME/.claude/projects/${MEM_PROJECT_KEY}/memory"
MEM_FILES=$(find "$MEM_DIR" -type f -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
# Fallback: count this project's transcripts as proxy for "session files"
[ -z "$MEM_FILES" ] || [ "$MEM_FILES" = "0" ] && \
    MEM_FILES=$(find "$HOME/.claude/projects/${MEM_PROJECT_KEY}" -maxdepth 1 -name "*.jsonl" 2>/dev/null | wc -l | tr -d ' ')

# claude-mem observations: SQLite DB at ~/.claude-mem/claude-mem.db
MEM_OBS=0
if [ -f "$HOME/.claude-mem/claude-mem.db" ] && command -v sqlite3 >/dev/null 2>&1; then
    MEM_OBS=$(sqlite3 "$HOME/.claude-mem/claude-mem.db" "SELECT COUNT(*) FROM observations" 2>/dev/null)
fi

# Wiki articles: prefer project-local wiki (relative to cwd), fallback to ~/wiki
WIKI_COUNT=0
for wiki_root in "$CWD/wiki" "$HOME/wiki"; do
    if [ -d "$wiki_root" ]; then
        WIKI_COUNT=$(find "$wiki_root" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
        break
    fi
done

MEM_FILES=${MEM_FILES:-0}
MEM_OBS=${MEM_OBS:-0}
WIKI_COUNT=${WIKI_COUNT:-0}

# ─────────────────────────────────────────────────────────────────────────────
# TASKS — count active background tasks/agents from transcript (cached 3s)
# ─────────────────────────────────────────────────────────────────────────────
TASKS_BG=0; TASKS_AGENT=0
if [ -f "$TRANSCRIPT" ] && needs_refresh "$TASKS_CACHE" "$TASKS_TTL"; then
    {
        # Background tasks: count tool_use entries with name=Bash and run_in_background=true
        # without a corresponding tool_result yet
        bg=$(jq -rs '
            [.[] | select(.message?.content?[]?.type == "tool_use") | .message.content[] |
                select(.type == "tool_use" and .name == "Bash" and (.input.run_in_background == true)) | .id] as $started
            | [.[] | select(.message?.content?[]?.type == "tool_result") | .message.content[] |
                select(.type == "tool_result") | .tool_use_id] as $finished
            | ($started - $finished) | length
        ' "$TRANSCRIPT" 2>/dev/null)
        [ -z "$bg" ] && bg=0

        ag=$(jq -rs '
            [.[] | select(.message?.content?[]?.type == "tool_use") | .message.content[] |
                select(.type == "tool_use" and .name == "Agent") | .id] as $started
            | [.[] | select(.message?.content?[]?.type == "tool_result") | .message.content[] |
                select(.type == "tool_result") | .tool_use_id] as $finished
            | ($started - $finished) | length
        ' "$TRANSCRIPT" 2>/dev/null)
        [ -z "$ag" ] && ag=0

        echo "TASKS_BG=$bg"
        echo "TASKS_AGENT=$ag"
    } > "$TASKS_CACHE"
fi
[ -f "$TASKS_CACHE" ] && source "$TASKS_CACHE"
TASKS_BG=${TASKS_BG:-0}
TASKS_AGENT=${TASKS_AGENT:-0}

# ─────────────────────────────────────────────────────────────────────────────
# DERIVED VALUES for display
# ─────────────────────────────────────────────────────────────────────────────
NOW=$(date '+%H:%M')
COST_FMT=$(printf '$%.2f' "$COST_USD" 2>/dev/null || echo "\$0.00")
SHORT_CWD="${CWD##*/}"
[ -z "$SHORT_CWD" ] && SHORT_CWD="~"
ACTIVE_SKILL="${OUTPUT_STYLE}"

# Friendly model label
case "$MODEL_ID" in
    *opus-4-7*) MODEL_SHORT="Opus 4.7" ;;
    *opus*)     MODEL_SHORT="Opus" ;;
    *sonnet-4-6*) MODEL_SHORT="Sonnet 4.6" ;;
    *sonnet*)   MODEL_SHORT="Sonnet" ;;
    *haiku*)    MODEL_SHORT="Haiku" ;;
    *)          MODEL_SHORT="$MODEL_NAME" ;;
esac
[[ "$MODEL_ID" == *"1m"* ]] && MODEL_SHORT="$MODEL_SHORT (1M)"

# Color for context %
CTX_COLOR=$(color_pct "$CTX_PCT")
USAGE_COLOR="$C_VALUE_DIM"
if [ "$USAGE_5H_PCT" != "--" ]; then
    USAGE_COLOR=$(color_pct "$USAGE_5H_PCT")
fi

# ─────────────────────────────────────────────────────────────────────────────
# RENDER
# ─────────────────────────────────────────────────────────────────────────────

# Header line with title + active skill (no top separator — PAI-style)
printf '%b─%b %bimper%bStatus%bLine%b %b─%b ' \
    "$C_LINE" "$R" \
    "$C_TITLE_1$B" "$C_TITLE_2$B" "$C_TITLE_3$B" "$R" \
    "$C_LINE" "$R"
printf '%bskill: %b%s%b\n' "$C_VALUE_DIM" "$C_PURPLE" "$ACTIVE_SKILL" "$R"

# Row 1: time | model | effort | cost (no emoji — keeps column alignment with row 2)
printf '%bTIME:%b %s   %b│%b   %bMODEL:%b %b%s%b   %b│%b   %bEFFORT:%b %b%s%b   %b│%b   %bCOST:%b %b%s%b\n' \
    "$C_LABEL" "$R" "$NOW" \
    "$C_SEP" "$R" \
    "$C_LABEL" "$R" "$C_VALUE" "$MODEL_SHORT" "$R" \
    "$C_SEP" "$R" \
    "$C_LABEL" "$R" "$EFFORT_COLOR" "$EFFORT" "$R" \
    "$C_SEP" "$R" \
    "$C_LABEL" "$R" "$C_GREEN" "$COST_FMT" "$R"

# Row 2: ENV / counts
printf '%bENV: %b CC %b%s%b   %b│%b   SK %b%s%b   %b│%b   Hooks %b%s%b   %b│%b   Plugins %b%s%b   %b│%b   CMD %b%s%b\n' \
    "$C_LABEL" "$R" \
    "$C_VALUE" "$CC_VERSION" "$R" \
    "$C_SEP" "$R" "$C_VALUE" "$SK_COUNT" "$R" \
    "$C_SEP" "$R" "$C_VALUE" "$HOOKS_COUNT" "$R" \
    "$C_SEP" "$R" "$C_VALUE" "$PLUGIN_COUNT" "$R" \
    "$C_SEP" "$R" "$C_VALUE" "$CMD_COUNT" "$R"

sep

# Row 3: CONTEXT bar (full width)
printf '%b●%b %bCONTEXT:%b ' "$CTX_COLOR" "$R" "$C_LABEL" "$R"
render_ctx_bar "$CTX_PCT"
printf '  %b%s%%%b\n' "$CTX_COLOR" "$CTX_PCT" "$R"

sep

# Row 4: USAGE (5H quota — only if available)
if [ "$USAGE_5H_PCT" != "--" ]; then
    printf '%b⚡%b %bUSAGE:%b 5H %b%s%%%b' \
        "$C_YELLOW" "$R" "$C_LABEL" "$R" "$USAGE_COLOR" "$USAGE_5H_PCT" "$R"
    [ -n "$USAGE_5H_RESET" ] && printf '   %b↺%s%b' "$C_VALUE_DIM" "$USAGE_5H_RESET" "$R"
    printf '\n'
    sep
fi

# Row 5: PWD + git
printf '%b◆ PWD:%b %b%s%b' "$C_LABEL" "$R" "$C_VALUE" "$SHORT_CWD" "$R"
if [ -n "$GIT_BRANCH" ]; then
    printf '   %b│%b   %bBranch:%b %b%s%b' "$C_SEP" "$R" "$C_LABEL" "$R" "$C_VALUE" "$GIT_BRANCH" "$R"
    [ -n "$GIT_AGE" ]  && printf '   %b│%b   %bAge:%b %s' "$C_SEP" "$R" "$C_LABEL" "$R" "$GIT_AGE"
    if [ "${GIT_MOD:-0}" -gt 0 ]; then
        printf '   %b│%b   %bMod:%b %b%s%b' "$C_SEP" "$R" "$C_LABEL" "$R" "$C_YELLOW" "$GIT_MOD" "$R"
    fi
    [ -n "$GIT_SYNC" ] && [ "$GIT_SYNC" != "=" ] && printf '   %b│%b   %bSync:%b %b%s%b' "$C_SEP" "$R" "$C_LABEL" "$R" "$C_PINK" "$GIT_SYNC" "$R"
else
    printf '   %b(not a git repo)%b' "$C_VALUE_DIM" "$R"
fi
printf '\n'

sep

# Row 6: MEMORY
printf '%b◎ MEMORY:%b 📁 %b%s%b %bFiles%b   %b│%b   🧠 %b%s%b %bclaude-mem%b   %b│%b   📚 %b%s%b %bWiki%b   %b│%b   🔌 %b%s%b %bPlugins%b\n' \
    "$C_LABEL" "$R" \
    "$C_VALUE" "$MEM_FILES" "$R" "$C_PURPLE" "$R" \
    "$C_SEP" "$R" "$C_VALUE" "$MEM_OBS" "$R" "$C_PURPLE" "$R" \
    "$C_SEP" "$R" "$C_VALUE" "$WIKI_COUNT" "$R" "$C_PURPLE" "$R" \
    "$C_SEP" "$R" "$C_VALUE" "$PLUGIN_COUNT" "$R" "$C_PURPLE" "$R"

# Row 7: TASKS (only if any active)
if [ "$TASKS_BG" -gt 0 ] || [ "$TASKS_AGENT" -gt 0 ]; then
    sep
    printf '%b▸ TASKS:%b' "$C_LABEL" "$R"
    [ "$TASKS_BG" -gt 0 ]    && printf ' %b%s%b bg' "$C_YELLOW" "$TASKS_BG" "$R"
    [ "$TASKS_BG" -gt 0 ] && [ "$TASKS_AGENT" -gt 0 ] && printf '   %b│%b' "$C_SEP" "$R"
    [ "$TASKS_AGENT" -gt 0 ] && printf ' %b%s%b agent' "$C_PINK" "$TASKS_AGENT" "$R"
    printf '\n'
fi
