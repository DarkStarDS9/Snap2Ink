# TestFlight deployment

## Status

| Piece | Status |
|---|---|
| Bundle ID `app.snap2ink.camera` | Registered in App Store Connect |
| App Store distribution certificate | Reused from the account's existing one (expires 2027-04-14) |
| Provisioning profile "Snap2Ink AppStore" | Created, installed locally |
| App Store Connect app record | Created |
| App icon | Present |

Real account identifiers (entity/cert/profile IDs, key ID, issuer ID) live in a gitignored local
note (`docs/testflight.local.md`, create your own from `docs/testflight.local.md.example`) rather
than here — they're personal to one Apple Developer account, not project documentation. The ASC
API key itself (key ID + issuer ID) is account-level, not per-app, and is already shared with
SpokenFeeds and Todo2Ink — see `.env.example`.

## Deploying

```bash
./deploy-testflight.sh
```

Wraps `xcodebuild archive` (Release scheme, `-allowProvisioningUpdates` + the ASC key so it
provisions without an Xcode GUI login) and `xcodebuild -exportArchive` (manual signing style, named
profile, `destination: upload`) with pre-flight checks and error diagnosis, same shape as
`SpokenFeedsMixer`'s script in the sibling repo. Confirmed working end to end — archive, export, and
upload to App Store Connect.

## App Store Connect API key

`deploy-testflight.sh` reads the key ID and issuer ID from the `SNAP2INK_ASC_KEY_ID` /
`SNAP2INK_ASC_ISSUER_ID` environment variables — set them in your shell profile, or in a gitignored
`.env` beside the script (copy `.env.example`), which the script sources automatically if present.
The `.env` route is what a non-interactive caller (a script, CI, or an agent's tool shell) needs,
since those don't source `.zshrc`/`.bash_profile` the way an interactive terminal does. Either way
it expects the key file at `~/.appstoreconnect/private_keys/AuthKey_<key id>.p8` (override with
`SNAP2INK_ASC_KEY_PATH`) — never committed. `ExportOptions.plist` (also gitignored, copy from
`ExportOptions.plist.example`) carries your team id and provisioning profile name.

Your actual key ID, issuer ID, team id, and the ASC entity IDs (bundle/cert/profile) belong in
`docs/testflight.local.md`, not in this tracked file.

## Regenerating the provisioning profile

If a capability change ever invalidates it, delete the old one and recreate via the App Store
Connect API (`DELETE profiles/<id>` then `POST profiles` with the bundle id and certificate id) —
see `docs/testflight.local.md` for this project's actual entity IDs and the full recipe.

## Deploy policy

See the top-level `CLAUDE.md`: deploy after every commit that lands on `main`, without waiting to
be asked, unless told otherwise.
