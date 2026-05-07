#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# imperStatusLine installer — handles fresh install AND updates.
#
# Usage:
#   ./install.sh            # install or update (default)
#   ./install.sh --uninstall # remove the script and unwire from settings.json
#   ./install.sh --no-wire   # copy/update the script but don't touch settings.json
#
# What it does:
#   1. Copies imperStatusLine.sh to ~/.claude/imperStatusLine.sh (chmod +x).
#      If a previous copy exists, backs it up to imperStatusLine.sh.bak.<epoch>.
#   2. Wires it into ~/.claude/settings.json via the "statusLine" field
#      (creates the file if missing). Always backs up settings.json first.
#   3. Clears the runtime cache at /tmp/imperstatusline-$USER/ so the next
#      refresh sees the new version immediately.
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_NAME="imperStatusLine.sh"
CLAUDE_DIR="$HOME/.claude"
TARGET="$CLAUDE_DIR/$SCRIPT_NAME"
SETTINGS="$CLAUDE_DIR/settings.json"
CACHE_DIR="/tmp/imperstatusline-${USER:-anon}"

WIRE=1
UNINSTALL=0
for arg in "$@"; do
    case "$arg" in
        --no-wire)   WIRE=0 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help)
            sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Resolve the directory this installer lives in (so it works from any cwd).
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SRC_DIR/$SCRIPT_NAME"

# ─── helpers ─────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }
warn() { printf '  \033[33mwarn:\033[0m %s\n' "$*" >&2; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  \033[36m›\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

backup() {
    local f="$1"
    [ -f "$f" ] || return 0
    local bak="${f}.bak.$(date +%s)"
    cp "$f" "$bak"
    info "backup: $bak"
}

# ─── uninstall path ──────────────────────────────────────────────────────────
if [ "$UNINSTALL" = "1" ]; then
    echo "Uninstalling imperStatusLine…"
    if [ -f "$TARGET" ]; then
        backup "$TARGET"
        rm -f "$TARGET"
        ok "removed $TARGET"
    else
        info "no script at $TARGET"
    fi
    if [ -f "$SETTINGS" ] && have jq; then
        if jq -e '.statusLine.command? // "" | test("imperStatusLine")' "$SETTINGS" >/dev/null 2>&1; then
            backup "$SETTINGS"
            tmp=$(mktemp)
            jq 'del(.statusLine)' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
            ok "removed statusLine entry from settings.json"
        else
            info "settings.json doesn't reference imperStatusLine — left untouched"
        fi
    fi
    rm -rf "$CACHE_DIR"
    ok "cache cleared ($CACHE_DIR)"
    echo "Done."
    exit 0
fi

# ─── preflight ───────────────────────────────────────────────────────────────
echo "Installing imperStatusLine…"
[ -f "$SRC" ] || die "source $SRC not found — run this from the cloned repo, or alongside $SCRIPT_NAME"
have jq || warn "jq not found in PATH — required at runtime; install with 'brew install jq' (macOS) or your package manager"
have sqlite3 || info "sqlite3 not found — claude-mem 'obs' counter will show 0 (optional)"

mkdir -p "$CLAUDE_DIR"

# ─── copy/update script ──────────────────────────────────────────────────────
if [ -f "$TARGET" ]; then
    if cmp -s "$SRC" "$TARGET"; then
        info "script already up to date at $TARGET"
    else
        backup "$TARGET"
        cp "$SRC" "$TARGET"
        chmod +x "$TARGET"
        ok "updated $TARGET"
    fi
else
    cp "$SRC" "$TARGET"
    chmod +x "$TARGET"
    ok "installed $TARGET"
fi

# ─── wire into settings.json ─────────────────────────────────────────────────
if [ "$WIRE" = "1" ]; then
    if ! have jq; then
        warn "skipping settings.json wiring (no jq); add this manually:"
        cat <<EOF

  "statusLine": {
    "type": "command",
    "command": "bash \$HOME/.claude/$SCRIPT_NAME",
    "padding": 0
  }
EOF
    else
        # Build the desired statusLine object
        desired='{"type":"command","command":"bash $HOME/'"$SCRIPT_NAME"'","padding":0}'
        # Note: $HOME stays literal in the JSON so settings stay portable.
        # We embed it into ~/.claude/$SCRIPT_NAME via shell expansion at run time.
        desired_correct='{"type":"command","command":"bash $HOME/.claude/'"$SCRIPT_NAME"'","padding":0}'

        if [ -f "$SETTINGS" ]; then
            current=$(jq -c '.statusLine // null' "$SETTINGS" 2>/dev/null || echo "null")
            if [ "$current" = "$desired_correct" ]; then
                info "settings.json already wired correctly"
            else
                backup "$SETTINGS"
                tmp=$(mktemp)
                jq --argjson sl "$desired_correct" '.statusLine = $sl' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
                ok "updated statusLine in $SETTINGS"
            fi
        else
            jq -n --argjson sl "$desired_correct" '{statusLine:$sl}' > "$SETTINGS"
            ok "created $SETTINGS with statusLine"
        fi
    fi
else
    info "skipped settings.json wiring (--no-wire)"
fi

# ─── clear cache so the next refresh sees the new version ────────────────────
if [ -d "$CACHE_DIR" ]; then
    rm -rf "$CACHE_DIR"
    ok "cleared cache ($CACHE_DIR)"
fi

echo
echo "Done. The new status line will appear at the next Claude Code refresh."
echo "If Claude Code is currently open, just send a message and watch it update."
