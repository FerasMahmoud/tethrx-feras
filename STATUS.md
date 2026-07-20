# Status 2026-07-21

## Done
- Public repo: https://github.com/FerasMahmoud/tethrx-feras
- Bundle IDs registered: uk.firashome.tethrx (+ widget)
- Match certs/profiles: OK
- **IPA builds on CI** (Archive + exportArchive OK)
- Default bridge: https://tethrx.firashome.uk
- IPA artifact + local: ~/secrets/apple/builds/TethrX-Feras.ipa

## Blocked (API key cannot CREATE apps)
App Store Connect has no app record for `uk.firashome.tethrx`.

### One-time unblock (60s)
1. https://appstoreconnect.apple.com → My Apps → +
2. iOS · Name: **TethrX Feras** · Bundle: **uk.firashome.tethrx** · SKU: firashome-tethrx
3. Then: `gh workflow run testflight.yml -R FerasMahmoud/tethrx-feras`
4. Open TestFlight on phone → install **TethrX Feras**
5. Address pre-filled; paste token from `cat ~/.tethrx-pair-token`

## Phone pair (after TestFlight install)
| Field | Value |
|-------|--------|
| Address | https://tethrx.firashome.uk |
| Token | `cat ~/.tethrx-pair-token` |
