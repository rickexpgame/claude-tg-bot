# Claude TG Bot

Keep your Claude Code Telegram bot alive 24/7 on macOS.

Three-layer keepalive architecture:

1. **`claude-tg-bot.command`** — while-true restart loop with crash detection and backoff
2. **launchd plist** — `RunAtLoad` auto-starts the bot on login
3. **Telegram plugin** — built-in 409 retry for zombie session handoff

Plus safety guards:
- Atomic `mkdir` lock prevents duplicate daemons
- Auto-removes Telegram plugin from user-scope to prevent Desktop Claude from stealing messages

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed
- Telegram plugin installed: `claude /install telegram@claude-plugins-official`
- Bot token configured: run `/telegram:configure` in Claude Code

## Install

```bash
git clone https://github.com/rickexpgame/claude-tg-bot.git
cd claude-tg-bot
bash scripts/install-tg-bot.sh
```

This will:
- Verify prerequisites (claude CLI, telegram plugin, bot token)
- Remove telegram from user-scope plugins (prevents Desktop Claude contention)
- Install and start the launchd service

The bot starts automatically on login.

## Usage

```bash
# Check status
launchctl print gui/$(id -u)/com.claude.tg-bot

# View logs
tail -f ~/logs/claude-tg-bot.log

# Uninstall
bash scripts/install-tg-bot.sh uninstall
```

## Configuration

All settings are via environment variables (set them before running install):

| Variable | Default | Description |
|---|---|---|
| `CLAUDE_TG_BIN` | `~/.local/bin/claude` | Path to claude CLI |
| `CLAUDE_TG_REPO` | Parent of `scripts/` | Working directory for claude |
| `CLAUDE_TG_CHANNELS` | `plugin:telegram@claude-plugins-official` | Channel spec |
| `CLAUDE_TG_SETTINGS` | `scripts/claude-tg-settings.json` | Claude settings file |
| `CLAUDE_TG_LOG_DIR` | `~/logs` | Log directory |

## How it works

```
Login → launchd → open .command → Terminal.app (real TTY)
                                    → while-true loop
                                      → claude --channels telegram
                                        → crash? → backoff → restart
```

Claude Code's `--channels` flag requires a real TTY, so the `.command` file opens in Terminal.app. The launchd plist uses `/usr/bin/open` to launch it, which also handles macOS trust dialogs automatically.

## License

MIT
