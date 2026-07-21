# Status 2026-07-21

## Live
- Bridge: https://tethrx.firashome.uk · grok **0.2.108**
- Pinggy SSH: leave running (do not kill)
- Features: FS browse, @path, cwd recents, share URL, PR, CI, quiet hours, history resume

## APNs
| Item | Value |
|------|--------|
| Key | `AuthKey_XF27A33VNY.p8` |
| Key ID | `XF27A33VNY` |
| Team | `3V4NW789C6` |
| Topic | `uk.firashome.tethrx` |
| Auth | **OK on sandbox** |
| Device token | production (TestFlight) → sandbox send = BadDeviceToken |

### If no banner on phone
Recreate APNs key with **Sandbox & Production** (or Production) at:
https://developer.apple.com/account/resources/authkeys/list  
Then: `install-apns-key /path/to/AuthKey_XXX.p8`

Or reinstall a **debug** build so the device token is sandbox-compatible with current key.

## Phone
1. TestFlight update after next ship
2. Settings → Push on
3. Connect Feras-PC
4. Test: finish turn / Send test push

## Pair
| Address | https://tethrx.firashome.uk |
| Token | `cat ~/.tethrx-pair-token` |
