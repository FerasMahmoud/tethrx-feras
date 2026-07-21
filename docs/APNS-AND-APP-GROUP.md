# TethrX Feras — APNs + App Group

## APNs status (proven 2026-07-21)

### What we tried (all automated)

| Attempt | Result |
|---------|--------|
| Use `AuthKey_BDC82G4589.p8` (ASC API key) as APNs | `403 InvalidProviderToken` |
| GHA create `APPLE_PUSH_SERVICES` cert via ASC API | **Not a valid cert type** in ASC API enum |
| GHA created `DEVELOPMENT` cert + mTLS to APNs | TLS `unknown ca` — not a push cert |

**Conclusion:** Apple does **not** expose APNs Auth Key or Push Services cert creation via App Store Connect API. Must use Developer portal UI **once**.

### Fix (60s browser — only human step)

1. https://developer.apple.com/account/resources/authkeys/list  
2. **+** → name `TethrX APNs` → enable **Apple Push Notifications service (APNs)** only  
3. Register → **Download** `AuthKey_XXXXXXXXXX.p8` (once)  
4. On PC:

```bash
# copy from Windows Downloads if needed:
# cp "/mnt/c/Users/feras/Downloads/AuthKey_"*.p8 /tmp/
install-apns-key /path/to/AuthKey_XXXXXXXXXX.p8
```

Script: installs p8 → writes `~/.grok-remote/config.json` → restarts bridge → probe + test push.

Expect `probe.authOk: true` — **not** `InvalidProviderToken`.

Phone: TethrX → Settings → Push on → **Send test push**.

### Manual config (if not using script)

```json
{
  "apns": {
    "keyPath": "/home/feras/secrets/apple/AuthKey_XXXXXXXXXX.p8",
    "keyId": "XXXXXXXXXX",
    "teamId": "3V4NW789C6",
    "topic": "uk.firashome.tethrx"
  }
}
```

```bash
systemctl --user restart tethrx-bridge
TOKEN=$(cat ~/.tethrx-pair-token)
curl -sS -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"sendTest":true}' http://127.0.0.1:4180/api/push/probe | jq .
```

---

## App Group `group.uk.firashome.tethrx`

Needed for widget snapshot. Entitlements already list it.

1. https://developer.apple.com/account/resources/identifiers/list/applicationGroup  
2. **+** → `group.uk.firashome.tethrx`  
3. Attach to `uk.firashome.tethrx` + `.widget`  
4. Next TF: match `force: true` already in Fastfile  

---

## Live Activity background

- App: `pushType: .token` → `POST /api/sessions/:id/activity-token`  
- Bridge: `apns-push-type: liveactivity`, topic `uk.firashome.tethrx.push-type.liveactivity`  
- Same **APNs Auth Key** as alerts  

---

## Hermes → APNs

```bash
tethrx-apns-notify "Hermes" "Session finished"
# or
~/.hermes/scripts/tethrx-apns-session-end.sh "Session finished"
```
