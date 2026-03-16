# NanoClaw Home Assistant Add-on

[NanoClaw](https://nanoclaw.dev) is a secure, lightweight personal AI agent — a self-hosted alternative to OpenClaw. It connects Claude to your messengers (WhatsApp, Telegram) and runs tasks inside isolated Docker containers.

## Features

- **Messenger integration** — WhatsApp and Telegram support
- **Container isolation** — each agent session runs in its own sandboxed container
- **Scheduled tasks** — cron-based automation with Claude feedback
- **Agent swarms** — teams of specialized agents for complex tasks
- **Persistent sessions** — credentials and state survive add-on restarts

## Prerequisites

- Home Assistant OS or Supervised installation (Docker access required)
- An [Anthropic API key](https://console.anthropic.com/)

## Configuration

| Option | Default | Description |
|---|---|---|
| `anthropic_api_key` | _(required)_ | Your Anthropic API key |
| `assistant_name` | `Andy` | Name the bot responds to in group chats |
| `assistant_has_own_number` | `false` | `true` if the bot has a dedicated WhatsApp number |
| `messenger` | `whatsapp` | `whatsapp` or `telegram` |
| `telegram_bot_token` | _(optional)_ | Required when messenger is `telegram` |
| `max_concurrent_containers` | `5` | Max simultaneous agent containers |
| `container_timeout` | `1800` | Seconds before an idle container is stopped |
| `log_level` | `info` | `debug`, `info`, `warning`, or `error` |

## First-Run Setup

### WhatsApp

On first start the add-on prints a QR code in the log output. Scan it with your phone:

> **WhatsApp → Settings → Linked Devices → Link a Device**

After scanning, the session is saved to persistent storage and future restarts will not require re-authentication.

### Telegram

1. Create a bot via [@BotFather](https://t.me/BotFather) and copy the token.
2. Set `messenger: telegram` and paste the token in `telegram_bot_token`.
3. Start the add-on — no QR code needed.

## Usage

Once connected, message your bot (WhatsApp or Telegram) and it will respond using Claude. Example prompts:

- `@Andy search the web for today's weather in Kyiv`
- `@Andy create a shopping list and send it to me`
- `@Andy every morning at 8 summarise my emails`

## Data & Privacy

All credentials, sessions, and agent data are stored in the Home Assistant `/data/nanoclaw` directory. No data is sent anywhere except to the Anthropic API and your configured messenger.

## Troubleshooting

| Symptom | Solution |
|---|---|
| QR code not appearing | Check add-on logs; ensure WhatsApp is selected as messenger |
| Agent containers fail | Verify Docker is available; check `docker_api: true` is set |
| `anthropic_api_key` error | Add key in add-on **Configuration** tab |
| Re-authenticate WhatsApp | Stop add-on, delete `/data/nanoclaw/.config/whatsapp`, restart |
