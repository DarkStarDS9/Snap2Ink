# Snap2Ink

Take a photo. Watch it develop on e-ink.

Snap2Ink is an iPhone camera app for the XTEINK companion display running
[`xteink-companion-ble`](https://github.com/DarkStarDS9/xteink-companion-ble) firmware. It captures a
photo, dithers it on the phone down to the panel's four grey levels, and pushes it over BLE. The
e-ink panel's slow two-pass grayscale settle does the rest: the picture fades in over several
seconds, like an instant print developing in your hand.

The whole point is that the wait is visible. Nothing here is optimised for speed.

## How it works

The firmware is deliberately dumb — it decodes a PNG and draws it. Everything that makes the print
look the way it does happens on the phone:

1. **Capture** — AVFoundation, front or back camera.
2. **Prepare** — crop and downscale to the panel's pixel grid, read from the device's capability
   block rather than assumed (a real X3 reports 528×792), and convert to 8-bit grey.
3. **Dither** — quantize to exactly `{0, 85, 170, 255}` using Atkinson, Floyd–Steinberg, or ordered
   Bayer. This is the aesthetic choice and it is the app's alone.
4. **Encode** — a 2-bit grayscale PNG, colour type 0, values only ever those four. Four times
   smaller than 8-bit and exactly as faithful. See [docs/device-contract.md](docs/device-contract.md).
5. **Send** — chunked over the Companion Display Protocol's content characteristic, with the
   firmware's dithering switched off so the panel shows the phone's bit pattern verbatim.

## Repo layout

```
project.yml                 XcodeGen project definition — the .xcodeproj is generated, not committed
Snap2Ink/
  Identity/                 appId, installId, button map, device icon
  Imaging/                  the dither pipeline and calibration target — pure, no UIKit, no BLE
  Camera/                   AVFoundation capture
  Transport/                DisplayTransport seam + mock; CompanionKit adapter
  ViewModels/               PrintStudioModel — the one piece of app state
  Views/                    SwiftUI
Snap2InkTests/              unit tests for the pipeline and identity
docs/device-contract.md     appId, button map, icon, wire encoding — the firmware-facing contract
MANUAL-DEVICE-TESTS.md      what the simulator cannot verify
```

## Building

```sh
brew install xcodegen
xcodegen generate
xcodebuild -scheme Snap2Ink -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme Snap2Ink -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The simulator has no camera and no Bluetooth. Both are stubbed there: the viewfinder shows a test
card and the transport is a `MockDisplayTransport` that fakes a realistic transfer. Run
[MANUAL-DEVICE-TESTS.md](MANUAL-DEVICE-TESTS.md) on real hardware before believing anything.

### On a device

Signing uses automatic signing and the Apple Development certificate already in the keychain, with
the team id supplied by `Snap2Ink/Configs/Local.xcconfig` — copy
`Snap2Ink/Configs/Local.xcconfig.example` to that path (gitignored, personal per machine) and fill
in your own team id (find it from your Apple Development certificate's **OU** field in Keychain
Access). The **first** signed build has to happen in Xcode so macOS can prompt for keychain access —
click **Always Allow**, after which command-line builds work unattended. Full steps, and what each
signing error means, are in [MANUAL-DEVICE-TESTS.md § Build and install](MANUAL-DEVICE-TESTS.md).

On another machine or account, override the team on the command line instead; nothing else needs
changing:

```sh
xcodebuild -scheme Snap2Ink -destination 'generic/platform=iOS' DEVELOPMENT_TEAM=YOURTEAM build
```

## Firmware dependency

The app depends on [`CompanionKit`](https://github.com/DarkStarDS9/CompanionKit), a versioned Swift
package extracted from the firmware repo's `clients/swift/CompanionKit`. The package's major version
tracks the protocol version (see `project.yml`'s `packages:` entry); `Package.resolved` records the
exact revision this app was built against. Snap2Ink never edits the firmware or CompanionKit repos
directly; protocol changes are requested, not made here.

To work on CompanionKit itself alongside Snap2Ink, drag a local checkout into the Xcode workspace —
Xcode shadows the remote package reference automatically, no project file changes needed.

## License

Snap2Ink is licensed under a modified MIT license — see [LICENSE](LICENSE).

**In short: you're free to use, modify, and distribute this code by any means — except an app
store.** Publishing this software, or any modified/derivative version of it, to the Apple App
Store, Google Play Store, or any other app store is reserved exclusively to the copyright holder
(Rainer Perl). Everything else the MIT license normally allows — running it, forking it, changing
it, sharing source or builds outside of an app store — is unrestricted.

Pull requests are welcome — the app store restriction is about who can *publish* it, not who can
*contribute* to it.
