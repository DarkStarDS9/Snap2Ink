# Snap2Ink's device contract

Everything the firmware sees of this app, and why it is that way. The authoritative wire format is
[`docs/companion-display-protocol.md`](https://github.com/DarkStarDS9/xteink-companion-ble/blob/companion/docs/companion-display-protocol.md)
in the firmware repo; this document records only Snap2Ink's own choices within it.

---

## Application id

```
d742c301-e39c-5af0-81d1-2517a49048ad
```

in [`Snap2Ink/Identity/Snap2InkPeer.swift`](../Snap2Ink/Identity/Snap2InkPeer.swift). Derived
reproducibly, matching how SpokenFeeds derives its own:

```python
uuid.uuid5(uuid.NAMESPACE_DNS, "app.snap2ink.camera")
```

Anyone can regenerate it from the app's reverse-DNS name and confirm it, which a magic constant does
not allow. A test re-derives it the long way rather than pinning the literal alone.

**This value is permanent.** It is identical across every install and every version of Snap2Ink,
forever. The device groups sleep-screen tiles by `appId`, so it is what makes two phones running
Snap2Ink one tile rather than two — and changing it would orphan every existing pairing on every
device in the world, with no way to clean them up, because unpairing is on-device only and the
protocol has no "forget me" opcode.

The firmware compares sixteen opaque bytes and never parses them; the UUIDv5 structure is purely
for humans.

**Display name:** `Snap2Ink`. Short because it is drawn in the device's pairing prompt on a 480px
panel.

## Install id

Sixteen random bytes, minted on first run into **`UserDefaults`** by CompanionKit's own
`CompanionIdentity(appId:displayName:defaults:)`.

`UserDefaults` rather than the Keychain is a platform-wide decision shared with SpokenFeeds: a
Keychain item outlives app deletion, so a fresh install would silently re-attach to the peer
directory the previous one left behind on the device.

The cost, recorded so it is a known trade rather than a surprise: a peer is `(appId, installId)`, so
every delete-and-reinstall becomes a *new* peer — a fresh on-device pairing confirmation, and a peer
directory on the SD card that nothing will ever reclaim, since unpairing is on-device only and the
protocol has no "forget me" opcode. Whether that accumulation ever matters is a question for the
firmware's enrolled-peer ceiling, not for this app.

## Button map

Part of the **UI declaration** (content field `0x05`), which carries the button routing and labels
together with the tag declarations in one asset with one digest. Pushed at enrolment and re-pushed
whenever its content hash changes. **Mandatory** — the device refuses `ACQUIRE` from a peer with no
stored declaration, so this is not polish.

| Button | Routing | Label | Why |
|---|---|---|---|
| `BACK` | `LOCAL_SLEEP` | Sleep | A round trip to the phone to say "go to sleep" would be absurd. |
| `CONFIRM` | `REMOTE` | Shutter | **The best thing in the app.** See below. |
| `LEFT` | `NONE` | — | Local paging acts on buffered body text; a print has none. |
| `RIGHT` | `NONE` | — | Same. Binding it would draw a page-turn hint over the photograph. |
| `UP` | `REMOTE` | Redevelop | Re-push the current print, for when another app took the screen. |
| `DOWN` | `REMOTE` | Timer | Toggle the phone-side self-timer. |
| `POWER` | — | — | Not remappable. Firmware-owned in every app, by design. |

**Why `CONFIRM` is a shutter.** The device is across the room, propped up, showing a photo. Making
it the trigger means the phone can be set down *as the camera* — which is the one thing this pair of
devices can do that neither can alone. The self-timer on `DOWN` exists only because of it: you need
a delay if you intend to be in the photo and the reader is out of reach.

The side buttons' labels are stored but not currently drawn (the firmware has no hint position for
them). They are set anyway — a label that exists only in a source comment is a button nobody can
discover, and a future firmware that draws them gets correct strings for free.

Tags are **content hashes**, which CompanionKit computes. The design doc recommends this over a
counter and the reason is app downgrade: a counter leaves the device holding a version number an
older build will never reach again, so that build reads "device is newer than me" and never
re-pushes its own map. A hash simply differs, in both directions.

## Panel dimensions — always read, never assumed

**Prints are encoded at whatever capability bytes 17..20 advertise.** Hardcoding a panel size is the
mistake that had this app encoding 480×800 against a 528×792 panel, and an image at the wrong
dimensions is scaled and resampled on-device — which destroys the dither, the one failure the
four-level contract exists to prevent, and which looks like a vague quality problem rather than a
bug.

The trap is worth naming: `lib/Xtc/Xtc/XtcTypes.h` defines `DISPLAY_WIDTH = 480` /
`DISPLAY_HEIGHT = 800`, and that header is the natural place to look. Those are the **X4's**
dimensions — the X3 (UC8253, 792×528 glass) and the X4 (SSD1677, 800×480) compile into the same
binary. A serial read of a real X3's capability block reports 528×792, and its framebuffer is 52,272
bytes = 528 × 792 / 8 exactly.

`DisplayGeometry.assumedX3` still exists, because a proof has to be renderable before anything is
paired, but it is a **placeholder and nothing more**: the capability read replaces it on connect, and
`PrintStudioModel` re-renders any existing proof when the real geometry arrives, so a print made
before pairing cannot be sent at the placeholder's size. `PrintPipeline.send` refuses a proof whose
dimensions do not match the panel as a backstop. Tests assert that prints — photographic, framed
and calibration alike — are encoded at whatever geometry they are handed, including sizes that are
neither the placeholder nor 480×800.

## Calibration target — making the four-level contract checkable

The premise of this whole app is that the panel shows the phone's bit pattern verbatim. That is
exactly the claim a human cannot verify by eye: two greys on an e-ink panel next to a phone screen
prove nothing.

`CalibrationTarget` converts it into judgements a person can actually make — *count the distinct
greys*, *is this band striped or flat*, *is the border one pixel or two*. Eight bands, each failing
in a specific and recognisable way, plus a one-pixel border and centre cross as the geometry check.
It is already exactly quantized at the panel's pixel size and goes through
`PrintPipeline.makeCalibrationPrint(geometry:)`, which skips rasterizing, dithering and composition
entirely — so **any difference on the panel is downstream of the phone**, which is what makes it a
bisection tool rather than just another picture.

Reachable in Debug builds only, by long-pressing the shutter for one second. It is a bring-up
instrument, not a feature, and a consumer camera app has no business shipping a test card behind a
gesture. It deliberately goes through the app's own encoder and transport: pushing the same sheet
with the firmware's Python script would prove the firmware works while saying nothing about whether
*this app's* bytes survive the trip.

The band-by-band pass conditions are in `MANUAL-DEVICE-TESTS.md` § 4.

## Diagnostics screen

A DEBUG-only readout, reached by tapping the link status bar, showing what the device advertised
(pixel size, image cap, icon size, feature flags, last `IMAGE_STATUS`) alongside what this app is
sending (image format, appId, button map, the current print's dimensions and size).

It exists for one reason: several steps of `MANUAL-DEVICE-TESTS.md` ask the tester to record values
that are otherwise invisible from the phone. They can be read over a serial cable with the firmware's
`CCAP`, but requiring a laptop and a USB lead to run a phone-side checklist is how steps quietly get
skipped. The most important of them puts the device's advertised screen pixels directly above the
current print's dimensions — if those two disagree, the device will scale and resample the image and
every dither observation after that is meaningless.

## Tags — declared empty, deliberately

v6 replaced the firmware's fixed indicator slots with app-declared tags: the app declares which tags
exist and what they are called in the UI declaration (field `0x05`, alongside the button map), and
switches them on and off with field `0x07`. Up to 6 tags, 12-byte labels, all starting hidden.

**Snap2Ink declares none.**

I argued for this capability. When I found that `renderIndicators` was only called from
`renderPage()` — so a tag set while an image was on screen was stored, acknowledged and never
drawn — I reported it as a silent no-op and proposed a "developed" mark as the concrete thing an
image app needed and could not have. That argument was accepted and the firmware now draws a visible
tag as a chip over the image.

Having got it, the honest answer is that **this app should not use it**, and the reasons only became
clear once the rendering was decided:

- **The chip is drawn over the photograph.** There is nowhere else for it to go — reserving a band
  would shrink the image and force the rescale that destroys the dither, which is rightly rejected.
  So the cost of the mark is a permanent blemish on the artifact this whole app exists to produce.
- **It would arrive after the moment it describes.** `pushImage` returns only once the device has
  decoded and displayed the image, so the earliest the mark can be set is *after* the settle has
  finished. The chip would appear in a second screen update, announcing "done" at the exact moment
  the print already visibly looks done.
- **The thing it was meant to disambiguate is already visible.** A settling panel is mid-refresh and
  obviously so from across the room; a settled one is clean. The distinction the mark was supposed to
  carry is one the panel makes by itself.

The argument was better in the abstract than it is for a camera app. It stands for apps whose screen
is text — a "saved" chip beside an article headline costs nothing and says something the content
cannot — which is where the capability belongs.

Nothing is lost by declaring none: tags start hidden, hidden tags cost no pixels, and adding one
later is a declaration change the device picks up on the next connect without re-pairing.

## Sleep-screen icon

A 1-bpp camera silhouette, **drawn in code** at whatever dimensions the capability characteristic
advertises ([`DeviceIcon.swift`](../Snap2Ink/Identity/DeviceIcon.swift)). Row-major, MSB first, a
set bit meaning ink.

Not a bundled asset: the size is advertised per device (capability bytes 11–12; 64×64 = 512 bytes
today) and a wrong length is rejected outright with `ASSET_ACK(REJECTED_SIZE)`, so the app has to be
able to draw whatever it is asked for. Drawing it also makes the icon a pure function, and therefore
testable.

Polarity is settled by the protocol document — *"A set bit is ink (black); a clear bit is paper"* —
and matches what this app emits.

A camera rather than a photograph: at 64×64 on a monochrome panel, a silhouette with one strong
circular feature survives and a framed-print border does not.

If a device ever advertises a width that is not a whole number of bytes, Snap2Ink supplies **no
icon** rather than guessing. `CompanionCapabilities.iconByteCount` is `width * height / 8`, which
only equals the packed size when the width divides by 8; how a ragged row should be padded is a
question for the firmware, not something to invent client-side. The cost of declining is one missing
sleep-screen tile.

## Image encoding — raw packed 2-bit samples

This replaced an 8-bit-per-pixel-capable PNG encoding outright (protocol v7, a clean break — the
image field had not shipped, so no back-compat was owed). The device's PNG decode path needed ~44 KB
heap (PNGdec + zlib inflate window) plus margin, and the ESP32-C3 companion firmware only has
~48–50 KB free with a BLE peer connected: image push was **structurally** broken on PNG, not flaky.

The wire format has **no header at all**. Field `0x04`'s payload is the packed samples only —
width and height are never repeated in it, because the device already has them from the capability
characteristic it advertised before any push (bytes 17–20), and it rejects (`DECODE_FAILED`) any
payload whose length is not exactly right for those advertised dimensions. No on-device scaling or
cropping: get the pixel count wrong and the push fails outright rather than degrading.

- `bytesPerRow = ceil(width / 4)`, four 2-bit samples per byte, most-significant-bits first (bits
  7–6 = the leftmost of the four, bits 1–0 = the rightmost), each row padded to a whole byte, rows
  stored top-to-bottom.
- Each sample is `0...3` and **is** the final display level already (0 = black, 3 = white) — there is
  no `sample * 255 / 3` expansion step on decode any more, so getting the dither's output pixel wrong
  is not caught by any downstream rounding.
- Payload size is always exactly `bytesPerRow * height` — for the X3 (528×792): `bytesPerRow = 132`,
  total = 104,544 bytes, always, for every dither algorithm. There is nothing to trade off: unlike the
  old PNG path, no choice of dithering changes the size, because there is no compression step to
  benefit from periodicity.

Implemented in [`ImagePacker.swift`](../Snap2Ink/Imaging/ImagePacker.swift), which replaced the old
`PNGEncoder.swift`.

### No more size fallback

The PNG-era pipeline used to re-dither with ordered Bayer when a print didn't fit, because that
algorithm's periodicity compressed several times better than diffusion noise. That entire mechanism
is gone: since the packed size is a fixed function of panel geometry alone, no choice of algorithm
ever changes it. If `bytesPerRow * height` exceeds the device's advertised `maxImageFieldLength`, the
pipeline throws `PrintPipeline.PipelineError.tooLarge` immediately — there is nothing left to retry.
In practice this should not be reachable: the cap the device advertises is a function of the same
geometry it advertises, so a device that can report its screen size correctly should always advertise
a cap that fits it.

## Integration status

| Piece | Status |
|---|---|
| Dither pipeline, image packer, layout | Complete, unit-tested |
| Camera capture | Complete; needs a device to verify (see `MANUAL-DEVICE-TESTS.md`) |
| `CompanionKitTransport` | Complete; verified against hardware |
| `MockDisplayTransport` | Complete; used in the simulator and in tests |
| Pairing / preemption UI | Complete, driven by the mock's simulated paths |

The app selects its transport by build target: `MockDisplayTransport` in the simulator, which has no
Bluetooth radio, and `CompanionKitTransport` on device.

## Open questions for the firmware side

None outstanding.
