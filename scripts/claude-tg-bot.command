#!/bin/bash
# Claude Code Telegram Bot — daemon with single-instance guard + auto-restart
# Opens in Terminal.app (via .command extension) → provides real TTY.
# Launched by launchd plist via `open`, ensuring trust dialog auto-confirms.
#
# Keepalive layers:
#   1. This script's while-true loop (restart on exit, backoff on crash loops)
#   2. launchd plist (com.claude.tg-bot) restarts this script if it dies
#   3. Telegram plugin's built-in 409 retry (handles zombie handoff)
#
# Single-instance guarantee:
#   - Atomic mkdir lock prevents duplicate daemons
#   - Settings file (claude-tg-settings.json) scopes the Telegram plugin
#     to this process only — other Claude instances must NOT install the
#     telegram plugin at user scope (installed_plugins.json), or they will
#     compete for getUpdates and steal messages.
#
# Security note:
#   --dangerously-skip-permissions is required for unattended daemon operation.
#   All security relies on the Telegram plugin's access control layer
#   (pairing codes + allowlist in ~/.claude/channels/telegram/access.json).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${CLAUDE_TG_REPO:-$(dirname "$SCRIPT_DIR")}"
CLAUDE="${CLAUDE_TG_BIN:-$HOME/.local/bin/claude}"
CHANNELS="${CLAUDE_TG_CHANNELS:-plugin:telegram@claude-plugins-official}"
SETTINGS="${CLAUDE_TG_SETTINGS:-$SCRIPT_DIR/claude-tg-settings.json}"
LOG_DIR="${CLAUDE_TG_LOG_DIR:-$HOME/logs}"
DEBUG="${CLAUDE_TG_DEBUG:-false}"
LOG_FILE="$LOG_DIR/claude-tg-bot.log"
LOCK_DIR="$LOG_DIR/claude-tg-bot.lock"

MAX_FAST_RESTARTS=5
FAST_RESTART_WINDOW=60   # seconds — restart faster than this counts as a crash
BACKOFF_SECONDS=300      # 5-minute backoff after crash loop

mkdir -p "$LOG_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

debug() {
  if [ "$DEBUG" = "true" ]; then
    printf '[%s] [DEBUG] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
  fi
}

# --- Log rotation (keep last 3000 lines) ---
rotate_log() {
  if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 5000 ]; then
    tail -3000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    log "Log rotated"
  fi
}

# --- Single-instance lock (atomic mkdir) ---
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    LOCK_ACQUIRED=true
    return 0
  fi
  # Lock exists — check if holder is still alive
  local old_pid
  old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    log "ABORT: another instance already running (PID $old_pid)"
    echo "Another instance already running (PID $old_pid). Exiting."
    sleep 5
    exit 0
  fi
  # Stale lock — reclaim
  log "WARN: removing stale lock (PID $old_pid)"
  rm -rf "$LOCK_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    LOCK_ACQUIRED=true
    return 0
  fi
  # Another process beat us to reclaim — bail out
  log "ABORT: lost lock race, another instance starting"
  exit 0
}

LOCK_ACQUIRED=false

release_lock() {
  if [ "$LOCK_ACQUIRED" = true ]; then
    rm -rf "$LOCK_DIR"
    LOCK_ACQUIRED=false
  fi
}

CLAUDE_PID=""

trap release_lock EXIT
trap 'log "SHUTDOWN: received signal"; [ -n "${CLAUDE_PID:-}" ] && kill "$CLAUDE_PID" 2>/dev/null; exit 0' SIGTERM SIGINT SIGHUP

# --- Pre-flight checks ---
if [ ! -x "$CLAUDE" ]; then
  CLAUDE=$(command -v claude 2>/dev/null || true)
  if [ -z "$CLAUDE" ]; then
    echo "ERROR: claude not found"
    sleep 10
    exit 1
  fi
fi

if [ ! -d "$REPO_DIR" ]; then
  echo "ERROR: repo dir not found at $REPO_DIR"
  sleep 10
  exit 1
fi

# --- Main ---
acquire_lock
cd "$REPO_DIR"
rotate_log

log "DAEMON START: PID $$ | repo=$REPO_DIR | claude=$CLAUDE | debug=$DEBUG"
debug "ENV: CHANNELS=$CHANNELS"
debug "ENV: SETTINGS=$SETTINGS"
debug "ENV: LOG_DIR=$LOG_DIR"
debug "ENV: LOCK_DIR=$LOCK_DIR"
debug "ENV: PATH=$PATH"
debug "System: $(uname -a)"
debug "Uptime: $(uptime)"
debug "Claude version: $("$CLAUDE" --version 2>&1 || echo 'unknown')"

RESTART_COUNT=0

while true; do
  START_TIME=$(date +%s)
  log "START: launching claude (restart #$RESTART_COUNT)"
  debug "Memory: $(vm_stat 2>/dev/null | head -5 || echo 'unavailable')"
  debug "Disk: $(df -h "$REPO_DIR" 2>/dev/null | tail -1 || echo 'unavailable')"
  debug "Network: $(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 https://api.anthropic.com 2>/dev/null || echo 'unreachable')"

  "$CLAUDE" --channels "$CHANNELS" \
    --dangerously-skip-permissions \
    --settings "$SETTINGS" \
    2>> "$LOG_FILE"
  EXIT_CODE=$?

  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))
  log "EXIT: claude exited with code $EXIT_CODE after ${DURATION}s"
  debug "Exit details: code=$EXIT_CODE duration=${DURATION}s restart_count=$RESTART_COUNT"

  # Crash loop detection
  if [ "$DURATION" -lt "$FAST_RESTART_WINDOW" ]; then
    RESTART_COUNT=$((RESTART_COUNT + 1))
    debug "Fast restart detected: count=$RESTART_COUNT threshold=$MAX_FAST_RESTARTS"
    if [ "$RESTART_COUNT" -ge "$MAX_FAST_RESTARTS" ]; then
      log "ERROR: $MAX_FAST_RESTARTS fast restarts in a row, backing off ${BACKOFF_SECONDS}s"
      debug "Entering backoff: ${BACKOFF_SECONDS}s sleep"
      sleep "$BACKOFF_SECONDS"
      RESTART_COUNT=0
    fi
  else
    debug "Normal exit (ran ${DURATION}s > ${FAST_RESTART_WINDOW}s), resetting crash counter"
    RESTART_COUNT=0
  fi

  rotate_log
  log "RESTART: waiting 5s before restart..."
  sleep 5
done
