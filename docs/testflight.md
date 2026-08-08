# TestFlight deployment

## Status

| Piece | Status |
|---|---|
| Bundle ID `app.snap2ink.camera` | Registered in App Store Connect |
| App Store distribution certificate | Reused from the account's existing one (expires 2027-04-14) |
| Provisioning profile "Snap2Ink AppStore" | Created, installed locally |
| App Store Connect **app record** | **Not created — see below** |
| App icon | **Missing — see below** |

Real account identifiers (entity/cert/profile IDs, key ID, issuer ID) live in a gitignored local
note (`docs/testflight.local.md`, create your own from `docs/testflight.local.md.example`) rather
than here — they're personal to one Apple Developer account, not project documentation.

Two manual blockers before a real upload can land in TestFlight; everything else is scripted.

## Blocker 1: the App Store Connect app record

Apple does not allow creating a new app listing via the API — `POST /v1/apps` returns
`403 FORBIDDEN` (`the resource 'apps' does not allow 'CREATE'`) regardless of key role. This has to
be done once, by hand, in the web UI:

1. [App Store Connect](https://appstoreconnect.apple.com) → **My Apps** → **+** → **New App**.
2. Platform: iOS. Name: `Snap2Ink` (or whatever's free — the internal bundle id is fixed regardless).
3. Primary language: English (U.S.). Bundle ID: `app.snap2ink.camera` (already registered, will
   appear in the picker). SKU: anything stable, e.g. `app-snap2ink-camera`.
4. User access: Full Access is fine for a one-person account.

Nothing else on that first screen matters for TestFlight — screenshots, description, pricing, etc.
are only required for an actual App Store review submission, not for internal TestFlight testing.

## Blocker 2: the app icon

`Snap2Ink/Assets.xcassets/AppIcon.appiconset/Contents.json` declares the 1024×1024 universal slot
but has no image assigned to it. `xcodebuild -exportArchive` will fail App Store validation without
one. Needs actual artwork — not something to generate as a placeholder without a design decision.

## Deploying, once both are fixed

```bash
./deploy-testflight.sh
```

Wraps `xcodebuild archive` (Release scheme, `-allowProvisioningUpdates` + the ASC key so it
provisions without an Xcode GUI login) and `xcodebuild -exportArchive` (manual signing style, named
profile, `destination: upload`) with pre-flight checks and error diagnosis, same shape as
`SpokenFeedsMixer`'s script in the sibling repo. Confirmed working through the archive step and
through export far enough to hit ASC (`Error Downloading App Information` — the expected failure
mode for a missing app record, not a config bug).

## App Store Connect API key

`deploy-testflight.sh` reads the key ID and issuer ID from the `SNAP2INK_ASC_KEY_ID` /
`SNAP2INK_ASC_ISSUER_ID` environment variables (set once in your shell profile) and expects the
key file at `~/.appstoreconnect/private_keys/AuthKey_<key id>.p8` (override with
`SNAP2INK_ASC_KEY_PATH`) — never committed. `ExportOptions.plist` (also gitignored, copy from
`ExportOptions.plist.example`) carries your team id and provisioning profile name.

Your actual key ID, issuer ID, team id, and the ASC entity IDs (bundle/cert/profile) belong in
`docs/testflight.local.md`, not in this tracked file.

## Regenerating the provisioning profile

If a capability change ever invalidates it, delete the old one and recreate via the App Store
Connect API (`DELETE profiles/<id>` then `POST profiles` with the bundle id and certificate id) —
see `docs/testflight.local.md` for this project's actual entity IDs and the full recipe.

## Always ask before deploying

After presenting changes, ask the user "should I deploy to TestFlight?" — never auto-deploy.
