# Status 2026-07-21 (post APNs ship)

## Done
- Public repo: https://github.com/FerasMahmoud/tethrx-feras
- Bundle IDs: `uk.firashome.tethrx` (+ widget)
- Default bridge: https://tethrx.firashome.uk
- Bridge live: APNs **on**, ntfy **off**, `GET /api/grok-sessions` live
- APNs config: key `BDC82G4589`, team `3V4NW789C6`, topic `uk.firashome.tethrx`
- Features: Paste on Plan row, Expand gone, CLI resume, image attach, Live Activity

## Phone after TestFlight update
1. Install new build from TestFlight
2. Settings → enable **Push notifications**
3. Connect to Feras-PC (token already in Keychain if paired)
4. Background the app → finish a turn on PC → expect **native** banner (not ntfy app)
5. Session list → **GROK CLI (RESUME)** to continue terminal sessions

## Pair (if fresh install)
| Field | Value |
|-------|--------|
| Address | https://tethrx.firashome.uk |
| Token | `cat ~/.tethrx-pair-token` |

## Known risks
- APNs needs real device token after first enable (0 devices until then)
- AuthKey must have APNs capability in Apple Developer (same p8 as ASC if dual-enabled)
- Image path is path-on-disk fallback (Grok reads file path in text), not native vision blocks yet
- Live Activity updates only while app process alive (no ActivityKit push yet)
