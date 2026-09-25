# Server Health Telegram Reporter

A small Linux monitoring script that checks CPU, load average, RAM, disk usage,
and uptime. It sends routine reports and threshold alerts through Telegram, then
exits. A systemd timer starts it every five minutes, so nothing stays running
between checks.

## Behavior

- Checks the server every five minutes.
- Sends a routine health report every hour.
- Sends an immediate alert when CPU, RAM, or disk usage reaches its threshold.
- Repeats an ongoing alert no more than once every 30 minutes.
- Sends a recovery message when all values return below their thresholds.

All intervals and thresholds can be changed in `/etc/server-health.env`.

## Requirements

- Linux with `/proc`
- Bash, `awk`, `curl`, `df`, and systemd
- Outbound HTTPS access to `api.telegram.org`

## Telegram setup

1. Open Telegram and create a bot with [@BotFather](https://t.me/BotFather).
2. Open a chat with the new bot and send it a message such as `hello`.
3. In a browser, visit the URL below after substituting your bot token:

   ```text
   https://api.telegram.org/botYOUR_TOKEN/getUpdates
   ```

4. Find `message.chat.id` in the response. This number is the chat ID. Group
   chat IDs are commonly negative.

The reporter uses Telegram's official
[`sendMessage`](https://core.telegram.org/bots/api#sendmessage) method.

## Install

Run on the Linux server:

```bash
sudo ./install.sh
sudoedit /etc/server-health.env
```

Replace the example token and chat ID, then test a real message:

```bash
sudo systemctl start server-health.service
sudo systemctl status server-health.service
```

If the message arrives, enable the timer:

```bash
sudo systemctl enable --now server-health.timer
systemctl list-timers server-health.timer
```

Inspect recent logs with:

```bash
journalctl -u server-health.service --since today
```

## Safe local test

To collect and print the current metrics without contacting Telegram or changing
the saved alert state:

```bash
./server-health.sh --dry-run
```

## Configuration

The defaults in `server-health.env.example` are:

| Setting | Default | Meaning |
| --- | ---: | --- |
| `REPORT_INTERVAL_SECONDS` | `3600` | Routine report interval |
| `ALERT_COOLDOWN_SECONDS` | `1800` | Minimum time between ongoing alerts |
| `CPU_THRESHOLD_PERCENT` | `90` | CPU alert threshold |
| `MEMORY_THRESHOLD_PERCENT` | `90` | RAM alert threshold |
| `DISK_THRESHOLD_PERCENT` | `85` | Disk alert threshold |
| `DISK_PATH` | `/` | Filesystem to monitor |
| `CURL_TIMEOUT_SECONDS` | `15` | Telegram request timeout |

To change the five-minute check frequency, edit
`/etc/systemd/system/server-health.timer`, update `OnUnitActiveSec`, and run:

```bash
sudo systemctl daemon-reload
sudo systemctl restart server-health.timer
```

Keep `/etc/server-health.env` readable only by root because it contains the bot
token. The installer creates it with mode `0600` and does not overwrite an
existing configuration.

## Important limitation

This script cannot notify you when the machine is powered off or has completely
lost its network connection. Use a separate external uptime monitor for those
failures.
