#!/usr/bin/env bash

set -Eeuo pipefail

if (( EUID != 0 )); then
  echo "Run this installer as root: sudo ./install.sh" >&2
  exit 1
fi

source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

install -d -m 0755 /usr/local/lib/server-health
install -m 0755 "$source_dir/server-health.sh" /usr/local/lib/server-health/server-health.sh
install -m 0644 "$source_dir/systemd/server-health.service" /etc/systemd/system/server-health.service
install -m 0644 "$source_dir/systemd/server-health.timer" /etc/systemd/system/server-health.timer

if [[ ! -e /etc/server-health.env ]]; then
  install -m 0600 "$source_dir/server-health.env.example" /etc/server-health.env
  config_status="Created /etc/server-health.env; add your Telegram token and chat ID."
else
  config_status="Kept the existing /etc/server-health.env."
fi

systemctl daemon-reload

echo "$config_status"
echo "Then run:"
echo "  sudo systemctl start server-health.service"
echo "  sudo systemctl enable --now server-health.timer"

