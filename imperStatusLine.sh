#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# imperStatusLine — custom statusline for Claude Code
# Inspired by PAI (danielmiessler/Personal_AI_Infrastructure) v5.0.0
# Standalone, no PAI dependencies. Adds effort, cost, cmd count, and task tracking.
#
# ─── Layout ───────────────────────────────────────────────────────────────────
#   ─ imperStatusLine ─ skill: <output_style>
#   TIME │ MODEL │ EFFORT │ PERM
#   ENV  │ Agents │ SK │ Hooks │ Plugins │ CMD
#   ──────────────────────────────────
#   ● CONTEXT bar (sized to render width) + % + window size + ⚠200k flag
#   ──────────────────────────────────
#   🔢 TOKENS:  In │ Out │ Cached │ Total
#   💰 SESSION: Cost │ Lines +/- │ Uptime
#   📊 QUOTA:   5h % ↺reset │ 7d % ↺reset
#   ──────────────────────────────────
#   ◆ PWD │ Branch │ Age │ Mod │ Sync │ PR   (or "(not a git repo)")
#   ──────────────────────────────────
#   ◎ MEMORY: Sessions │ claude-mem │ CC version
#   ──────────────────────────────────
#   ▸ TASKS: N bg │ N agent   (only if active)
#
# ─── Data sources ───────────────────────────────────────────────────────────────
#   Claude Code >= 2.1.x passes context/cost/effort/rate_limits/pr natively in the
#   stdin JSON; we use those. On older CC (or before the first API call) we fall
#   back to parsing the transcript and to `ccusage` for the 5h quota.
#   Render width: CC exports COLUMNS (>= v2.1.153). The status line is indented,
#   so full-width content is sized to COLUMNS minus IMPERSL_WIDTH_MARGIN (default 4)
#   to avoid the overflow/truncation that full-COLUMNS sizing caused.
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
#   - npx + ccusage (optional) — FALLBACK for the 5h quota only when CC does not
#                                provide rate_limits natively; first run ~30s in
#                                background, then cached
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

# Helper: human-readable integer (1234 → "1.2K", 1234567 → "1.2M"). Pure bash, no bc.
fmt_n() {
    local n="${1:-0}"
    case "$n" in ''|*[!0-9]*) printf '0'; return ;; esac
    if   [ "$n" -ge 1000000 ]; then printf '%d.%dM' "$(( n / 1000000 ))" "$(( n % 1000000 / 100000 ))"
    elif [ "$n" -ge 1000 ];    then printf '%d.%dK' "$(( n / 1000 ))"    "$(( n % 1000 / 100 ))"
    else                            printf '%d' "$n"
    fi
}

# Detect terminal width. Since Claude Code v2.1.153 the statusline subprocess
# gets COLUMNS exported by CC itself (stdout is captured, so `tput cols` can't
# read the tty from inside the script). Prefer COLUMNS; fall back to tput, 100.
TERM_COLS="${COLUMNS:-0}"
[ "$TERM_COLS" -le 0 ] && TERM_COLS=$(tput cols 2>/dev/null || echo 100)
[ "$TERM_COLS" -le 0 ] && TERM_COLS=100

# IMPORTANT: the status line is rendered INDENTED inside the UI (CC's built-in
# spacing plus the `padding` setting), so the usable width is narrower than the
# full terminal. Sizing full-width content (bars, separators) to TERM_COLS makes
# it overflow and get truncated with "…" — the bug this layout used to hit.
# RCOLS is the safe render width; tune the reserve via IMPERSL_WIDTH_MARGIN.
WIDTH_MARGIN="${IMPERSL_WIDTH_MARGIN:-4}"
RCOLS=$(( TERM_COLS - WIDTH_MARGIN ))
[ "$RCOLS" -lt 20 ] && RCOLS=20

# Print a thin horizontal separator line, sized to the usable render width
sep() {
    local i line=""
    for ((i=0; i<RCOLS; i++)); do line="${line}─"; done
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
# Permission mode: try snake_case (Claude Code statusline JSON) and camelCase
# (older payloads / what we see in transcript metadata). Fallback: "default".
PERM_MODE="$(j '.permission_mode // .permissionMode // empty')"
if [ -z "$PERM_MODE" ] && [ -f "$TRANSCRIPT" ]; then
    # Last resort: read it from the transcript metadata (most recent line).
    PERM_MODE=$(grep -ohE '"permissionMode":"[^"]*"' "$TRANSCRIPT" 2>/dev/null \
        | tail -1 | sed 's/.*"permissionMode":"\([^"]*\)".*/\1/')
fi
[ -z "$PERM_MODE" ] && PERM_MODE="default"

# ─────────────────────────────────────────────────────────────────────────────
# NATIVE FIELDS (Claude Code >= 2.1.x). When present these replace the manual
# transcript parsing and the ccusage subprocess; we fall back to those when a
# field is absent (older CC, or before the first API call / right after /compact).
# ─────────────────────────────────────────────────────────────────────────────
CW_USED_PCT="$(j '.context_window.used_percentage // empty')"
CW_SIZE="$(j '.context_window.context_window_size // empty')"
CW_IN="$(j '.context_window.total_input_tokens // empty')"
CW_OUT="$(j '.context_window.total_output_tokens // empty')"
CW_CUR_IN="$(j '.context_window.current_usage.input_tokens // empty')"
CW_CUR_OUT="$(j '.context_window.current_usage.output_tokens // empty')"
CW_CUR_CC="$(j '.context_window.current_usage.cache_creation_input_tokens // empty')"
CW_CUR_CR="$(j '.context_window.current_usage.cache_read_input_tokens // empty')"
EXCEEDS_200K="$(j '.exceeds_200k_tokens // empty')"
EFFORT_LEVEL="$(j '.effort.level // empty')"
DURATION_MS="$(j '.cost.total_duration_ms // empty')"
LINES_ADD="$(j '.cost.total_lines_added // empty')"
LINES_DEL="$(j '.cost.total_lines_removed // empty')"
RL_5H_PCT="$(j '.rate_limits.five_hour.used_percentage // empty')"
RL_5H_RESET="$(j '.rate_limits.five_hour.resets_at // empty')"
RL_7D_PCT="$(j '.rate_limits.seven_day.used_percentage // empty')"
RL_7D_RESET="$(j '.rate_limits.seven_day.resets_at // empty')"
PR_NUM="$(j '.pr.number // empty')"
PR_STATE="$(j '.pr.review_state // empty')"

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
    # Plugin count from installed_plugins.json:
    #   v2 (current): { "version": 2, "plugins": { "<id>@<marketplace>": [...] } }
    #   v1 (legacy):  flat object { "<id>": {...} }
    plugin_count=$(jq -r '
        if type=="object" and has("plugins") then (.plugins | keys | length)
        elif type=="object" then (keys | length)
        else length end
    ' "$INSTALLED_PLUGINS" 2>/dev/null)
    [ -z "$plugin_count" ] && plugin_count=0

    # Skills / Commands / Agents from each installed plugin's installPath.
    # We deliberately do NOT scan ~/.claude/plugins/marketplaces (full registry
    # clones — would count plugins you haven't installed) nor ~/.claude/plugins/cache
    # at the top level (keeps multiple versions of the same plugin — would double-count).
    sk_plug=0; cmd_plug=0; agent_plug=0
    while IFS= read -r p; do
        [ -z "$p" ] || [ ! -d "$p" ] && continue
        s=$(find "$p" -path "*/skills/*/SKILL.md" 2>/dev/null | wc -l | tr -d ' ')
        c=$(find "$p" -path "*/commands/*.md" 2>/dev/null | wc -l | tr -d ' ')
        a=$(find "$p" -path "*/agents/*.md" 2>/dev/null | wc -l | tr -d ' ')
        sk_plug=$(( sk_plug + ${s:-0} ))
        cmd_plug=$(( cmd_plug + ${c:-0} ))
        agent_plug=$(( agent_plug + ${a:-0} ))
    done < <(jq -r '
        if type=="object" and has("plugins") then
            (.plugins | to_entries[] | .value[0].installPath // empty)
        elif type=="object" then
            (to_entries[] | .value.installPath // empty)
        else empty end
    ' "$INSTALLED_PLUGINS" 2>/dev/null)

    # User-level skills/commands/agents (not part of any plugin)
    sk_user=$(find "$HOME/.claude/skills" -name "SKILL.md" 2>/dev/null | wc -l | tr -d ' ')
    cmd_user=$(find "$HOME/.claude/commands" -maxdepth 3 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    agent_user=$(find "$HOME/.claude/agents" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

    sk_count=$(( sk_plug + ${sk_user:-0} ))
    cmd_count=$(( cmd_plug + ${cmd_user:-0} ))
    agent_count=$(( agent_plug + ${agent_user:-0} ))

    hooks_count=$(jq -r '
        [(.hooks // {}) | to_entries[] | .value | if type=="array" then .[] else . end | (.hooks // []) | length] | add // 0
    ' "$SETTINGS_FILE" 2>/dev/null)
    [ -z "$hooks_count" ] && hooks_count=0

    {
        echo "SK_COUNT=${sk_count:-0}"
        echo "CMD_COUNT=${cmd_count:-0}"
        echo "HOOKS_COUNT=${hooks_count:-0}"
        echo "PLUGIN_COUNT=${plugin_count:-0}"
        echo "AGENT_COUNT=${agent_count:-0}"
    } > "$COUNTS_CACHE"
fi
# shellcheck disable=SC1090
source "$COUNTS_CACHE"

# ─────────────────────────────────────────────────────────────────────────────
# CONTEXT % from transcript (token estimate)
# ─────────────────────────────────────────────────────────────────────────────
# Context window size: prefer the native field; fall back to model-id guessing.
if [ -n "$CW_SIZE" ] && [ "$CW_SIZE" -gt 0 ] 2>/dev/null; then
    CTX_MAX="$CW_SIZE"
else
    case "$MODEL_ID" in
        *"1m"*|*"1M"*|*opus-4-7*) CTX_MAX=1000000 ;;
        *) CTX_MAX=200000 ;;
    esac
fi

CTX_USED=0
SES_IN=0; SES_OUT=0; SES_CACHED=0; SES_TOTAL=0
SES_CALLS=0; SES_UPTIME_MIN=0

# NATIVE PATH: context_window + cost are provided directly. used_percentage is
# the live occupancy; total_input/output reflect CURRENT context (v2.1.132+),
# and current_usage breaks the input side into fresh / cache_read / cache_creation.
NATIVE_TOKENS=0
if [ -n "$CW_USED_PCT" ]; then
    NATIVE_TOKENS=1
    CTX_PCT_NATIVE="${CW_USED_PCT%.*}"            # floor "42.7" → "42"
    [ -z "$CTX_PCT_NATIVE" ] && CTX_PCT_NATIVE=0
    SES_IN="${CW_CUR_IN:-${CW_IN:-0}}"
    SES_OUT="${CW_CUR_OUT:-${CW_OUT:-0}}"
    SES_CACHED=$(( ${CW_CUR_CR:-0} + ${CW_CUR_CC:-0} ))
    SES_TOTAL=$(( SES_IN + SES_OUT + SES_CACHED ))
    [ -n "$DURATION_MS" ] && SES_UPTIME_MIN=$(( DURATION_MS / 60000 ))
fi

# FALLBACK PATH: parse the transcript only when the native context field is absent.
if [ "$NATIVE_TOKENS" -eq 0 ] && [ -f "$TRANSCRIPT" ]; then
    # Token metrics methodology (aligned with sirmalloc/ccstatusline):
    #   * Streaming writes multiple JSONL entries per API call: intermediate ones
    #     have stop_reason: null (partial chunks), the final one has a string
    #     ("end_turn", "tool_use"). Counting all entries double-counts streams.
    #     We sum only entries whose stop_reason is a string (finalized).
    #   * Session totals (In / Out / Cached) are CUMULATIVE sums over the full
    #     transcript — what you've spent so far this session, not the last call.
    #   * Context length is the LAST main-chain entry's
    #     (input + cache_read + cache_creation) — that's the live occupancy.
    #
    # The full transcript is parsed once, but cached on disk and only refreshed
    # when the transcript file is newer than the cache (mtime-based).
    TR_HASH=$(printf '%s' "$TRANSCRIPT" | shasum 2>/dev/null | awk '{print $1}')
    TOKENS_CACHE="$CACHE_DIR/tokens-${TR_HASH}.sh"
    if [ ! -f "$TOKENS_CACHE" ] || [ "$TRANSCRIPT" -nt "$TOKENS_CACHE" ]; then
        read -r _ctx _in _out _cached _total _calls _first_ts _last_ts < <(
            jq -rs '
                [.[] | select(.message?.usage? and (.message.stop_reason | type == "string"))] as $f
                | (([$f[] | .message.usage.input_tokens // 0] | add) // 0) as $in
                | (([$f[] | .message.usage.output_tokens // 0] | add) // 0) as $out
                | (([$f[] | (.message.usage.cache_read_input_tokens // 0)
                          + (.message.usage.cache_creation_input_tokens // 0)] | add) // 0) as $cached
                | (
                    # last main-chain (non-sidechain, non-error) finalized entry
                    [$f[] | select((.isSidechain // false) | not)
                          | select((.isApiErrorMessage // false) | not)] | last
                  ) as $lastMain
                | (
                    if $lastMain then
                        ($lastMain.message.usage.input_tokens // 0)
                        + ($lastMain.message.usage.cache_read_input_tokens // 0)
                        + ($lastMain.message.usage.cache_creation_input_tokens // 0)
                    else 0 end
                  ) as $ctx
                # Session uptime: first and last timestamp across the WHOLE
                # transcript (any line with .timestamp), not just usage entries.
                | ([.[] | .timestamp // empty]) as $allts
                | ($allts | first // "") as $tfirst
                | ($allts | last // "") as $tlast
                | "\($ctx) \($in) \($out) \($cached) \($in + $out + $cached) \($f | length) \($tfirst) \($tlast)"
            ' "$TRANSCRIPT" 2>/dev/null
        )
        # Derive uptime in minutes from the two ISO timestamps (portable: GNU `date -d`
        # and BSD `date -j -f` differ — try both).
        _uptime=0
        if [ -n "$_first_ts" ] && [ -n "$_last_ts" ]; then
            t1=$(date -j -f '%Y-%m-%dT%H:%M:%S' "${_first_ts%.*}" '+%s' 2>/dev/null \
                || date -d "$_first_ts" '+%s' 2>/dev/null)
            t2=$(date -j -f '%Y-%m-%dT%H:%M:%S' "${_last_ts%.*}" '+%s' 2>/dev/null \
                || date -d "$_last_ts" '+%s' 2>/dev/null)
            if [ -n "$t1" ] && [ -n "$t2" ] && [ "$t2" -gt "$t1" ]; then
                _uptime=$(( (t2 - t1) / 60 ))
            fi
        fi
        {
            echo "CTX_USED=${_ctx:-0}"
            echo "SES_IN=${_in:-0}"
            echo "SES_OUT=${_out:-0}"
            echo "SES_CACHED=${_cached:-0}"
            echo "SES_TOTAL=${_total:-0}"
            echo "SES_CALLS=${_calls:-0}"
            echo "SES_UPTIME_MIN=${_uptime:-0}"
        } > "$TOKENS_CACHE"
    fi
    # shellcheck disable=SC1090
    source "$TOKENS_CACHE"
fi
: "${CTX_USED:=0}" "${SES_IN:=0}" "${SES_OUT:=0}" "${SES_CACHED:=0}" "${SES_TOTAL:=0}"
: "${SES_CALLS:=0}" "${SES_UPTIME_MIN:=0}"

# Uptime formatter: minutes → "Xh Ym" / "Ym" / "<1m"
fmt_uptime() {
    local m="${1:-0}"
    case "$m" in ''|*[!0-9]*) printf '<1m'; return ;; esac
    if [ "$m" -lt 1 ];   then printf '<1m'
    elif [ "$m" -lt 60 ]; then printf '%dm' "$m"
    elif [ $((m % 60)) -eq 0 ]; then printf '%dh' "$((m / 60))"
    else printf '%dh %dm' "$((m / 60))" "$((m % 60))"
    fi
}

if [ "$NATIVE_TOKENS" -eq 1 ]; then
    CTX_PCT="$CTX_PCT_NATIVE"
else
    CTX_PCT=$(( CTX_USED * 100 / CTX_MAX ))
fi
case "$CTX_PCT" in ''|*[!0-9]*) CTX_PCT=0 ;; esac
[ "$CTX_PCT" -gt 100 ] && CTX_PCT=100

# Render context bar — width adapts to terminal width
render_ctx_bar() {
    local pct="$1" cells i fill
    # Reserve ~22 chars for "● CONTEXT  " prefix and "  XX%  (1M)" suffix.
    # Sized to RCOLS (usable render width) so it never overflows the panel.
    cells=$(( RCOLS - 22 ))
    [ "$cells" -lt 10 ] && cells=10
    fill=$(( pct * cells / 100 ))
    printf '%b' "$(color_pct "$pct")"
    for ((i=0; i<fill; i++)); do printf '◉'; done
    printf '%b' "$C_DIM"
    for ((i=fill; i<cells; i++)); do printf '◯'; done
    printf '%b' "$R"
}

# ─────────────────────────────────────────────────────────────────────────────
# QUOTA — 5h + 7d rate limits. Native (rate_limits.*) when present, else ccusage.
# ─────────────────────────────────────────────────────────────────────────────
USAGE_5H_PCT="--"; USAGE_5H_RESET=""
USAGE_7D_PCT="--"; USAGE_7D_RESET=""

# Format a Unix epoch (seconds) using BSD `date -r` or GNU `date -d @…`.
fmt_epoch() {  # $1=epoch  $2=strftime format
    local e="$1" f="$2"
    case "$e" in ''|*[!0-9]*) return ;; esac
    date -r "$e" "+$f" 2>/dev/null || date -d "@$e" "+$f" 2>/dev/null
}

if [ -n "$RL_5H_PCT" ]; then
    # NATIVE: Claude.ai Pro/Max only, populated after the first API response.
    # resets_at is Unix epoch seconds. seven_day may be absent independently.
    USAGE_5H_PCT="${RL_5H_PCT%.*}"; [ -z "$USAGE_5H_PCT" ] && USAGE_5H_PCT=0
    USAGE_5H_RESET="$(fmt_epoch "$RL_5H_RESET" '%H:%M')"
    if [ -n "$RL_7D_PCT" ]; then
        USAGE_7D_PCT="${RL_7D_PCT%.*}"; [ -z "$USAGE_7D_PCT" ] && USAGE_7D_PCT=0
        USAGE_7D_RESET="$(fmt_epoch "$RL_7D_RESET" '%b %d')"
    fi
else
    # FALLBACK (older CC / API-key users): ccusage subprocess, 5h block only.
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
fi

# ─────────────────────────────────────────────────────────────────────────────
# EFFORT (thinking budget)
# ─────────────────────────────────────────────────────────────────────────────
EFFORT="default"
if [ -n "$EFFORT_LEVEL" ]; then
    # NATIVE: live effort level (low/medium/high/xhigh/max), incl. mid-session /effort.
    EFFORT="$EFFORT_LEVEL"
elif [ -n "$CLAUDE_THINKING_LEVEL" ]; then
    EFFORT="$CLAUDE_THINKING_LEVEL"
elif [ -n "$THINKING_BUDGET" ]; then
    EFFORT="$THINKING_BUDGET"
else
    e=$(jq -r '.thinkingBudget // .thinking.level // .env.MAX_THINKING_TOKENS // empty' "$SETTINGS_FILE" 2>/dev/null)
    [ -n "$e" ] && EFFORT="$e"
fi
EFFORT_LOWER=$(echo "$EFFORT" | tr '[:upper:]' '[:lower:]')
case "$EFFORT_LOWER" in
    max|xhigh|high|*32000*|*64000*) EFFORT_COLOR="$C_RED" ;;
    medium|*16000*)            EFFORT_COLOR="$C_YELLOW" ;;
    low|*8000*|*4000*)         EFFORT_COLOR="$C_GREEN" ;;
    *)                          EFFORT_COLOR="$C_VALUE_DIM" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# GIT info
# ─────────────────────────────────────────────────────────────────────────────
GIT_BRANCH=""; GIT_AGE=""; GIT_MOD=""; GIT_SYNC=""
if [ -n "$CWD" ] && [ -d "$CWD" ] && git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_BRANCH=$(git -C "$CWD" symbolic-ref --short HEAD 2>/dev/null || git -C "$CWD" rev-parse --short HEAD 2>/dev/null)
    last_commit_ts=$(git -C "$CWD" log -1 --format=%ct 2>/dev/null)
    if [ -n "$last_commit_ts" ]; then
        now=$(date +%s)
        diff=$(( now - last_commit_ts ))
        if   [ "$diff" -lt 60 ];      then GIT_AGE="${diff}s"
        elif [ "$diff" -lt 3600 ];    then GIT_AGE="$(( diff / 60 ))m"
        elif [ "$diff" -lt 86400 ];   then GIT_AGE="$(( diff / 3600 ))h"
        else                                GIT_AGE="$(( diff / 86400 ))d"
        fi
    fi
    GIT_MOD=$(git -C "$CWD" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    ahead_behind=$(git -C "$CWD" rev-list --left-right --count "@{upstream}...HEAD" 2>/dev/null)
    if [ -n "$ahead_behind" ]; then
        behind=$(echo "$ahead_behind" | awk '{print $1}')
        ahead=$(echo "$ahead_behind" | awk '{print $2}')
        sync=""
        [ "$ahead" -gt 0 ] && sync="↑${ahead}"
        [ "$behind" -gt 0 ] && sync="${sync}↓${behind}"
        GIT_SYNC="${sync:-=}"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# MEMORY counts — proposta A: Files | claude-mem | Wiki | Plugins
# ─────────────────────────────────────────────────────────────────────────────
# Sessions: count of Claude Code transcript files (.jsonl) for this project.
# Claude Code normalizes the cwd into a project key by replacing every
# non-alphanumeric character with a dash (e.g. "ugo.lattanzi" → "ugo-lattanzi"),
# not just slashes — matching that behavior is required to find the right dir.
MEM_PROJECT_KEY="$(echo "$CWD" | sed 's|[^a-zA-Z0-9]|-|g')"
MEM_PROJECT_DIR="$HOME/.claude/projects/${MEM_PROJECT_KEY}"
MEM_SESSIONS=$(find "$MEM_PROJECT_DIR" -maxdepth 1 -name "*.jsonl" 2>/dev/null | wc -l | tr -d ' ')

# claude-mem observations: SQLite DB at ~/.claude-mem/claude-mem.db.
# We pull two counts in one connection: the global total (across all projects)
# and the count for THIS project, where claude-mem identifies projects by the
# cwd basename (e.g. "imperugo", "moresi-agent-framework"). The local count is
# 0 if claude-mem hasn't observed this project yet.
MEM_OBS=0; MEM_OBS_LOCAL=0
if [ -f "$HOME/.claude-mem/claude-mem.db" ] && command -v sqlite3 >/dev/null 2>&1; then
    PROJ_BASE="${CWD##*/}"
    # Escape single quotes for SQL literal safety (' → '')
    PROJ_BASE_SQL="${PROJ_BASE//\'/\'\'}"
    read -r MEM_OBS MEM_OBS_LOCAL < <(
        sqlite3 -separator ' ' "$HOME/.claude-mem/claude-mem.db" \
            "SELECT (SELECT COUNT(*) FROM observations), (SELECT COUNT(*) FROM observations WHERE project = '${PROJ_BASE_SQL}')" 2>/dev/null
    )
fi

MEM_SESSIONS=${MEM_SESSIONS:-0}
MEM_OBS=${MEM_OBS:-0}
MEM_OBS_LOCAL=${MEM_OBS_LOCAL:-0}

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

# Human label for the context window size (1M / 200k / …)
if   [ "$CTX_MAX" -ge 1000000 ]; then CTX_MAX_LABEL="$(( CTX_MAX / 1000000 ))M"
elif [ "$CTX_MAX" -ge 1000 ];    then CTX_MAX_LABEL="$(( CTX_MAX / 1000 ))k"
else                                  CTX_MAX_LABEL="$CTX_MAX"
fi

# exceeds_200k flag → a red "⚠200k" marker on the CONTEXT line (relevant on 1M models)
EXCEEDS_MARK=""
[ "$EXCEEDS_200K" = "true" ] && EXCEEDS_MARK=" ⚠200k"

# PR review state → symbol + color (shown on the PWD/git row when a PR is open)
PR_SYM=""; PR_COLOR="$C_VALUE_DIM"
if [ -n "$PR_NUM" ]; then
    case "$PR_STATE" in
        approved)          PR_SYM="✓"; PR_COLOR="$C_GREEN" ;;
        changes_requested) PR_SYM="✗"; PR_COLOR="$C_RED" ;;
        pending)           PR_SYM="●"; PR_COLOR="$C_YELLOW" ;;
        draft)             PR_SYM="◷"; PR_COLOR="$C_VALUE_DIM" ;;
        *)                 PR_SYM="";  PR_COLOR="$C_VALUE" ;;
    esac
fi

# Permission mode → short label + color (red for bypass = "be careful")
case "$PERM_MODE" in
    bypassPermissions) PERM_SHORT="bypass";       PERM_COLOR="$C_RED" ;;
    acceptEdits)       PERM_SHORT="accept";       PERM_COLOR="$C_YELLOW" ;;
    plan)              PERM_SHORT="plan";         PERM_COLOR="$C_PURPLE" ;;
    default|"")        PERM_SHORT="default";      PERM_COLOR="$C_GREEN" ;;
    *)                 PERM_SHORT="$PERM_MODE";   PERM_COLOR="$C_VALUE_DIM" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# RENDER
# ─────────────────────────────────────────────────────────────────────────────

# Header line with title + active skill (no top separator — PAI-style)
printf '%b─%b %bimper%bStatus%bLine%b %b─%b ' \
    "$C_LINE" "$R" \
    "$C_TITLE_1$B" "$C_TITLE_2$B" "$C_TITLE_3$B" "$R" \
    "$C_LINE" "$R"
printf '%bskill: %b%s%b\n' "$C_VALUE_DIM" "$C_PURPLE" "$ACTIVE_SKILL" "$R"

# Row 1: time | model | effort | perm  (cost moved to SESSION row)
printf '%bTIME:%b %s   %b│%b   %bMODEL:%b %b%s%b   %b│%b   %bEFFORT:%b %b%s%b   %b│%b   %bPERM:%b %b%s%b\n' \
    "$C_LABEL" "$R" "$NOW" \
    "$C_SEP" "$R" \
    "$C_LABEL" "$R" "$C_VALUE" "$MODEL_SHORT" "$R" \
    "$C_SEP" "$R" \
    "$C_LABEL" "$R" "$EFFORT_COLOR" "$EFFORT" "$R" \
    "$C_SEP" "$R" \
    "$C_LABEL" "$R" "$PERM_COLOR" "$PERM_SHORT" "$R"

# Row 2: ENV / counts. Agents lives here (active count appended in parens
# when there are sub-agents currently running, e.g. "43 (4 active)").
agents_env="${AGENT_COUNT:-0}"
if [ "${TASKS_AGENT:-0}" -gt 0 ]; then
    agents_env="${AGENT_COUNT:-0} (${TASKS_AGENT} active)"
fi
printf '%bENV: %b Agents %b%s%b   %b│%b   SK %b%s%b   %b│%b   Hooks %b%s%b   %b│%b   Plugins %b%s%b   %b│%b   CMD %b%s%b\n' \
    "$C_LABEL" "$R" \
    "$C_VALUE" "$agents_env" "$R" \
    "$C_SEP" "$R" "$C_VALUE" "$SK_COUNT" "$R" \
    "$C_SEP" "$R" "$C_VALUE" "$HOOKS_COUNT" "$R" \
    "$C_SEP" "$R" "$C_VALUE" "$PLUGIN_COUNT" "$R" \
    "$C_SEP" "$R" "$C_VALUE" "$CMD_COUNT" "$R"

sep

# Row 3: CONTEXT bar (sized to RCOLS) + percentage + window size + 200k warning
printf '%b●%b %bCONTEXT:%b ' "$CTX_COLOR" "$R" "$C_LABEL" "$R"
render_ctx_bar "$CTX_PCT"
printf '  %b%s%%%b %b(%s)%b%b%s%b\n' \
    "$CTX_COLOR" "$CTX_PCT" "$R" \
    "$C_VALUE_DIM" "$CTX_MAX_LABEL" "$R" \
    "$C_RED" "$EXCEEDS_MARK" "$R"

sep

# Row 3b: TOKENS — cumulative session token breakdown
#   In     = NEW input tokens spent this session (small with prompt cache)
#   Out    = tokens generated by the model
#   Cached = cache_read + cache_creation (the bulk on long sessions)
#   Total  = In + Out + Cached
if [ "$SES_TOTAL" -gt 0 ]; then
    printf '%b🔢 TOKENS:%b In %b%s%b   %b│%b   Out %b%s%b   %b│%b   Cached %b%s%b   %b│%b   Total %b%s%b\n' \
        "$C_LABEL" "$R" \
        "$C_VALUE" "$(fmt_n "$SES_IN")" "$R" \
        "$C_SEP" "$R" "$C_VALUE" "$(fmt_n "$SES_OUT")" "$R" \
        "$C_SEP" "$R" "$C_GREEN" "$(fmt_n "$SES_CACHED")" "$R" \
        "$C_SEP" "$R" "$C_VALUE" "$(fmt_n "$SES_TOTAL")" "$R"

    # Row 3c: SESSION meta — cost, lines changed (native), uptime.
    # The 5h/7d reset moved to the dedicated QUOTA row below.
    printf '%b💰 SESSION:%b Cost %b%s%b   %b│%b   Lines %b+%s%b/%b-%s%b   %b│%b   Uptime %b%s%b\n' \
        "$C_LABEL" "$R" \
        "$C_GREEN" "$COST_FMT" "$R" \
        "$C_SEP" "$R" "$C_GREEN" "${LINES_ADD:-0}" "$R" "$C_RED" "${LINES_DEL:-0}" "$R" \
        "$C_SEP" "$R" "$C_VALUE" "$(fmt_uptime "$SES_UPTIME_MIN")" "$R"
    sep
fi

# Row 4: QUOTA — 5h + 7d rate limits (native rate_limits, else ccusage 5h only)
if [ "$USAGE_5H_PCT" != "--" ]; then
    q5_color=$(color_pct "$USAGE_5H_PCT")
    printf '%b📊 QUOTA:%b 5h %b%s%%%b' "$C_LABEL" "$R" "$q5_color" "$USAGE_5H_PCT" "$R"
    [ -n "$USAGE_5H_RESET" ] && printf ' %b↺%s%b' "$C_VALUE_DIM" "$USAGE_5H_RESET" "$R"
    if [ "$USAGE_7D_PCT" != "--" ]; then
        q7_color=$(color_pct "$USAGE_7D_PCT")
        printf '   %b│%b   7d %b%s%%%b' "$C_SEP" "$R" "$q7_color" "$USAGE_7D_PCT" "$R"
        [ -n "$USAGE_7D_RESET" ] && printf ' %b↺%s%b' "$C_VALUE_DIM" "$USAGE_7D_RESET" "$R"
    fi
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
    # PR for the current branch (native .pr — only present when one is open)
    if [ -n "$PR_NUM" ]; then
        printf '   %b│%b   %bPR:%b %b#%s %s%b' "$C_SEP" "$R" "$C_LABEL" "$R" "$PR_COLOR" "$PR_NUM" "$PR_SYM" "$R"
    fi
else
    printf '   %b(not a git repo)%b' "$C_VALUE_DIM" "$R"
fi
printf '\n'

sep

# Row 6: MEMORY. Agents lives in the ENV row now (alongside SK/Hooks/Plugins/CMD);
# the CC version takes its slot here so the row keeps three balanced columns.
# Units: Sessions = .jsonl transcript files for this project; obs = rows in
# claude-mem SQLite DB shown as "local / total" when local > 0; CC = Claude
# Code CLI version.
if [ "$MEM_OBS_LOCAL" -gt 0 ]; then
    obs_display="$MEM_OBS_LOCAL / $(fmt_n "$MEM_OBS")"
else
    obs_display="$MEM_OBS"
fi
printf '%b◎ MEMORY:%b 💬 %b%s%b %bSessions%b   %b│%b   🧠 %b%s%b %bobs%b %b(claude-mem)%b   %b│%b   🟧 %bCC%b %b%s%b\n' \
    "$C_LABEL" "$R" \
    "$C_VALUE" "$MEM_SESSIONS" "$R" "$C_PURPLE" "$R" \
    "$C_SEP" "$R" "$C_VALUE" "$obs_display" "$R" "$C_PURPLE" "$R" "$C_VALUE_DIM" "$R" \
    "$C_SEP" "$R" "$C_PURPLE" "$R" "$C_VALUE" "$CC_VERSION" "$R"

# Row 7: TASKS (only if any active)
if [ "$TASKS_BG" -gt 0 ] || [ "$TASKS_AGENT" -gt 0 ]; then
    sep
    printf '%b▸ TASKS:%b' "$C_LABEL" "$R"
    [ "$TASKS_BG" -gt 0 ]    && printf ' %b%s%b bg' "$C_YELLOW" "$TASKS_BG" "$R"
    [ "$TASKS_BG" -gt 0 ] && [ "$TASKS_AGENT" -gt 0 ] && printf '   %b│%b' "$C_SEP" "$R"
    [ "$TASKS_AGENT" -gt 0 ] && printf ' %b%s%b agent' "$C_PINK" "$TASKS_AGENT" "$R"
    printf '\n'
fi
