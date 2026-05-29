#!/usr/bin/env bash
# writing-reload.sh — reload host nginx when the Tuyere writing CMS updates the
# /writing 301 redirect map, so slug-move redirects take effect automatically.
#
# nginx reads the `map … include` redirect file (ops/nginx/armoryworks.com.conf)
# only at config load, so a HUP reload is required after Tuyere rewrites it.
# Tuyere writes the file atomically (temp + rename), which surfaces as a
# moved_to event on the directory.
#
# Run as a long-lived service with permission to reload nginx (root):
#   sudo WRITING_CONTENT_DIR=/var/lib/armoryworks/writing ops/writing-reload.sh
# or install it as a systemd service. Requires inotify-tools.
set -euo pipefail

WRITING_DIR="${WRITING_CONTENT_DIR:-/var/lib/armoryworks/writing}"
MAP_FILE="$WRITING_DIR/_redirects.map"

command -v inotifywait >/dev/null 2>&1 || {
  echo "inotifywait not found — install inotify-tools (sudo apt install -y inotify-tools)" >&2
  exit 1
}

echo "watching $MAP_FILE — will 'nginx -t && nginx -s reload' on change"
while inotifywait -q -e close_write,moved_to "$WRITING_DIR" >/dev/null 2>&1; do
  if [[ -f "$MAP_FILE" ]] && nginx -t >/dev/null 2>&1; then
    nginx -s reload && echo "$(date -u +%FT%TZ) reloaded nginx (writing redirects)"
  fi
done
