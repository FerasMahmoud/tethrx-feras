#!/usr/bin/env bash
# Install a real APNs Auth Key (.p8 with Push enabled) into the TethrX bridge.
# Usage:
#   install-apns-key.sh /path/to/AuthKey_XXXXXXXXXX.p8 [KEY_ID]
# If KEY_ID omitted, parsed from filename AuthKey_XXXXXXXXXX.p8
set -euo pipefail
P8="${1:-}"
if [[ -z "$P8" || ! -f "$P8" ]]; then
  echo "Usage: $0 /path/to/AuthKey_XXXXXXXXXX.p8 [KEY_ID]" >&2
  echo "" >&2
  echo "Create key: https://developer.apple.com/account/resources/authkeys/list" >&2
  echo "  + → enable ONLY 'Apple Push Notifications service (APNs)' → Download" >&2
  exit 1
fi
KEY_ID="${2:-}"
base=$(basename "$P8")
if [[ -z "$KEY_ID" && "$base" =~ AuthKey_([A-Z0-9]+)\.p8 ]]; then
  KEY_ID="${BASH_REMATCH[1]}"
fi
if [[ -z "$KEY_ID" ]]; then
  echo "Could not parse Key ID from filename; pass as 2nd arg" >&2
  exit 1
fi
DEST="$HOME/secrets/apple/AuthKey_${KEY_ID}.p8"
mkdir -p "$HOME/secrets/apple"
install -m 600 "$P8" "$DEST"
python3 - <<PY
import json
from pathlib import Path
p = Path.home() / ".grok-remote" / "config.json"
d = json.loads(p.read_text()) if p.exists() else {}
d["apns"] = {
    "keyPath": "$DEST",
    "keyId": "$KEY_ID",
    "teamId": "3V4NW789C6",
    "topic": "uk.firashome.tethrx",
}
p.write_text(json.dumps(d, indent=2) + "\n")
print("wrote", p)
print(json.dumps(d["apns"], indent=2))
PY
systemctl --user restart tethrx-bridge
sleep 1
TOKEN=$(cat "$HOME/.tethrx-pair-token")
echo "--- probe ---"
curl -sS -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"sendTest":true,"title":"TethrX","message":"APNs Auth Key live"}' \
  http://127.0.0.1:4180/api/push/probe
echo
echo "Done. If probe.authOk=true, check phone lock screen."
