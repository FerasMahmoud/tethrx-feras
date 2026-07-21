# TethrX Feras — APNs key + App Group (one-time portal)

## 1. APNs Auth Key (required — current key is ASC-only)

Probe result on this box:

```json
{ "status": 403, "body": "{\"reason\":\"InvalidProviderToken\"}", "authBad": true }
```

`AuthKey_BDC82G4589.p8` is an **App Store Connect API** key. APNs rejects it.

### Fix (60s in browser)

1. https://developer.apple.com/account/resources/authkeys/list  
2. **+** → enable **Apple Push Notifications service (APNs)** only  
3. Download `.p8` once → save as e.g. `~/secrets/apple/AuthKey_APNS_XXXX.p8`  
4. Note **Key ID** + Team `3V4NW789C6`  
5. Edit `~/.grok-remote/config.json`:

```json
{
  "token": "…",
  "name": "Feras-PC",
  "publicUrl": "https://tethrx.firashome.uk",
  "apns": {
    "keyPath": "/home/feras/secrets/apple/AuthKey_APNS_XXXX.p8",
    "keyId": "XXXX",
    "teamId": "3V4NW789C6",
    "topic": "uk.firashome.tethrx"
  }
}
```

6. `systemctl --user restart tethrx-bridge`  
7. Probe:

```bash
TOKEN=$(cat ~/.tethrx-pair-token)
curl -sS -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"sendTest":true}' http://127.0.0.1:4180/api/push/probe | jq .
```

Expect `probe.authOk: true` (or `BadDeviceToken` on fake token) — **not** `InvalidProviderToken`.

Phone: Settings → enable Push → connect → **Send test push**.

---

## 2. App Group `group.uk.firashome.tethrx`

Needed for widget snapshot + shared defaults. Entitlements already list it.

### Portal

1. https://developer.apple.com/account/resources/identifiers/list/applicationGroup  
2. **+** → App Groups → `group.uk.firashome.tethrx` · name **TethrX Feras**  
3. Identifiers → App IDs → `uk.firashome.tethrx` → App Groups → tick the group  
4. Same for `uk.firashome.tethrx.widget`  
5. Next TestFlight: Fastfile already `force: true` match so profiles pick it up

If match still fails: temporary ship with Push-only entitlements (previous workaround).

---

## 3. Live Activity background push

- App requests activity with `pushType: .token`  
- Registers token: `POST /api/sessions/:id/activity-token`  
- Bridge sends `apns-push-type: liveactivity`  
- Topic: `uk.firashome.tethrx.push-type.liveactivity`  
- Same **APNs** Auth Key as alerts (not ASC)

---

## 4. Hermes finish → APNs (optional)

Script ready (does **not** use ntfy):

```bash
~/.hermes/scripts/tethrx-apns-session-end.sh "Session finished"
# or
tethrx-apns-notify "Hermes" "Session finished"
```

Wire in `~/.hermes/config.yaml` when you want it:

```yaml
hooks:
  on_session_end:
    - command: bash /home/feras/.hermes/scripts/tethrx-apns-session-end.sh
      timeout: 15
```

(Keep existing hooks; append this entry.)
