#!/usr/bin/env bash
# Install Claude Code Telegram Bot as a macOS launchd daemon.
#
# What this does:
#   1. Verifies prerequisites (claude CLI, telegram plugin)
#   2. Ensures telegram plugin is NOT in user-scope installed_plugins.json
#      (prevents Desktop Claude from competing for getUpdates)
#   3. Installs the launchd plist with correct paths
#   4. Bootstraps the service
#
# Usage:
#   bash scripts/install-tg-bot.sh          # install & start
#   bash scripts/install-tg-bot.sh uninstall # stop & remove
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PLIST_SRC="$SCRIPT_DIR/com.claude.tg-bot.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.claude.tg-bot.plist"
DAEMON_SCRIPT="$SCRIPT_DIR/claude-tg-bot.command"
INSTALLED_PLUGINS="$HOME/.claude/plugins/installed_plugins.json"
TG_ENV_FILE="$HOME/.claude/channels/telegram/.env"
UID_NUM=$(id -u)

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }

# --- Uninstall ---
if [ "${1:-}" = "uninstall" ]; then
  echo "Uninstalling Claude TG Bot daemon..."
  launchctl bootout "gui/$UID_NUM/com.claude.tg-bot" 2>/dev/null || true
  # Kill the daemon process if still running (Terminal may outlive launchd)
  LOCK_PID_FILE="$HOME/logs/claude-tg-bot.lock/pid"
  if [ -f "$LOCK_PID_FILE" ]; then
    OLD_PID=$(cat "$LOCK_PID_FILE" 2>/dev/null || true)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
      echo "Stopping daemon process (PID $OLD_PID)..."
      kill "$OLD_PID" 2>/dev/null || true
      sleep 2
    fi
  fi
  rm -f "$PLIST_DST"
  rm -rf "$HOME/logs/claude-tg-bot.lock"
  green "Uninstalled. Logs preserved in ~/logs/claude-tg-bot*.log"
  yellow "Note: telegram plugin was removed from user-scope during install."
  yellow "  If you want Desktop Claude to handle Telegram, reinstall the plugin:"
  yellow "  claude /install telegram@claude-plugins-official"
  exit 0
fi

# --- Pre-flight checks ---
echo "=== Claude TG Bot — Install ==="
echo ""

# Check claude CLI
CLAUDE="$HOME/.local/bin/claude"
if [ ! -x "$CLAUDE" ]; then
  CLAUDE=$(command -v claude 2>/dev/null || true)
  if [ -z "$CLAUDE" ]; then
    red "ERROR: claude CLI not found. Install it first:"
    echo "  npm install -g @anthropic-ai/claude-code"
    exit 1
  fi
fi
green "✓ claude CLI: $CLAUDE"

# Check telegram plugin is available
TG_PLUGIN_DIR=$(find "$HOME/.claude/plugins" -path "*/telegram/server.ts" -type f 2>/dev/null | head -1 || true)
if [ -z "$TG_PLUGIN_DIR" ]; then
  red "ERROR: Telegram plugin not installed. Install it first:"
  echo "  claude /install telegram@claude-plugins-official"
  exit 1
fi
green "✓ Telegram plugin found"

# Check bot token
if [ ! -f "$TG_ENV_FILE" ]; then
  red "ERROR: Telegram bot token not configured."
  echo "  Run: /telegram:configure in Claude Code and paste your bot token."
  exit 1
fi
green "✓ Bot token configured"

# --- Guard: remove telegram from user-scope plugins ---
# This prevents Desktop Claude / other CC instances from loading the plugin
# and competing for Telegram's getUpdates (409 Conflict = message stealing).
if [ -f "$INSTALLED_PLUGINS" ] && grep -q '"telegram@claude-plugins-official"' "$INSTALLED_PLUGINS"; then
  yellow "⚠ Removing telegram from user-scope installed_plugins.json"
  yellow "  (Prevents Desktop Claude from stealing the Telegram channel)"

  # Use python3 (available on macOS) for safe JSON editing
  INSTALLED_PLUGINS="$INSTALLED_PLUGINS" python3 -c "
import json, os
path = os.environ['INSTALLED_PLUGINS']
with open(path) as f:
    data = json.load(f)
data.get('plugins', {}).pop('telegram@claude-plugins-official', None)
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"
  green "✓ Telegram plugin removed from user-scope (daemon-only now)"
else
  green "✓ Telegram plugin not in user-scope (good)"
fi

# --- Install daemon script ---
chmod +x "$DAEMON_SCRIPT"
green "✓ Daemon script: $DAEMON_SCRIPT"

# --- Install launchd plist ---
# Stop existing service if running
launchctl bootout "gui/$UID_NUM/com.claude.tg-bot" 2>/dev/null || true
sleep 1

# Template the plist with actual paths
sed -e "s|__REPO_DIR__|$REPO_DIR|g" \
    -e "s|__HOME__|$HOME|g" \
    "$PLIST_SRC" > "$PLIST_DST"

green "✓ Plist installed: $PLIST_DST"

# --- Bootstrap ---
mkdir -p "$HOME/logs"
launchctl bootstrap "gui/$UID_NUM" "$PLIST_DST"
green "✓ Service started"

echo ""
echo "=== Done ==="
echo ""
echo "Check status:  launchctl print gui/$UID_NUM/com.claude.tg-bot"
echo "View logs:     tail -f ~/logs/claude-tg-bot.log"
echo "Uninstall:     bash $SCRIPT_DIR/install-tg-bot.sh uninstall"
echo ""
echo "Architecture:"
echo "  Layer 1: claude-tg-bot.command — Terminal.app + while-true restart loop"
echo "  Layer 2: launchd RunAtLoad — launches .command on login"
echo "  Layer 3: Telegram plugin — 409 retry for zombie session handoff"
echo "  Guard:   Atomic mkdir lock — prevents duplicate daemons"
echo "  Guard:   User-scope plugin removal — prevents Desktop Claude contention"
