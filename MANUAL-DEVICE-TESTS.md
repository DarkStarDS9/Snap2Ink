# Manual device tests

Everything the simulator cannot verify. The simulator has no camera and no Bluetooth, so every path
below is stubbed there — the viewfinder shows a test card and `MockDisplayTransport` fakes the link.
None of it is evidence about real hardware.

**Nothing in the v6 image path has ever run on the wire, from either side.** BLE is blocked for the
agent processes (macOS ties Bluetooth authorization to the terminal's parent process). So a failure
here is more likely a genuine firmware or app bug than a mistake in this list. **Report failures; do
not work around them.**

Every step has an unambiguous pass condition. Where a step says "count" or "measure", it means it —
do not judge by overall impression.

---

## Before you start

**You need:** an iPhone, an XTEINK X3 flashed with v6 firmware, and — for §2, §3.3 and a few
cross-checks — a USB cable to the reader.

**Bluetooth is only needed between the phone and the reader.** The Mac's Bluetooth is not used at
all: it only builds the app and talks to the reader over USB serial. So the macOS Bluetooth
restriction that blocks automated testing does not affect this list at all.

Signing is already set up — see below for the single manual step it needs.

### Build and install

Signing is already configured via `Snap2Ink/Configs/Local.xcconfig` (see README's "Building" section
if that file doesn't exist yet) and verified as far as it can be without the phone attached:
automatic signing, the Apple Development certificate that is already in this Mac's keychain, and the
iPhone already registered and enabled in App Store Connect. A build gets all the way to the final
code-signing step on its own.

**There is exactly one thing a person has to do, once.** The keychain will not release the signing
key to a background process — the same class of restriction that blocks Bluetooth for automated
runs — so the first signed build must happen somewhere a macOS prompt can appear and be answered.

```sh
cd /Users/rainer/Git/Snap2Ink
xcodegen generate
open Snap2Ink.xcodeproj
```

In Xcode: connect the iPhone by USB, select it as the run destination, and press **⌘R**.

1. macOS will show **"codesign wants to use the key ... in your keychain"**. Enter the login password
   and click **Always Allow** — not *Allow*. *Always Allow* is what makes every later build,
   including command-line ones, work without prompting again.
2. If the phone asks, tap **Trust This Computer** and enter its passcode.
3. The first launch will fail with *"Untrusted Developer"*. On the phone go to **Settings ▸ General ▸
   VPN & Device Management ▸ Apple Development: <your Apple ID> ▸ Trust**, then run again.

After that first run, command-line builds work unattended:

```sh
xcodebuild -scheme Snap2Ink -destination 'generic/platform=iOS' build
```

If signing ever fails on another machine or account, override the team — nothing else needs changing:

```sh
xcodebuild -scheme Snap2Ink -destination 'generic/platform=iOS' DEVELOPMENT_TEAM=YOURTEAM build
```

<details>
<summary>If it fails: what each error means</summary>

| Error | Cause | Fix |
|---|---|---|
| `errSecInternalComponent` | The keychain refused the signing key to a non-interactive process | Build once from Xcode and click **Always Allow** |
| `No Account for Team "<apple id>"` | Wrong team id. The Apple ID in the certificate's CN was used instead of the team; the team is the certificate's **OU** field | Set the **OU** value as `DEVELOPMENT_TEAM` in `Snap2Ink/Configs/Local.xcconfig`, not the Apple ID |
| `No profiles for 'app.snap2ink.camera' were found` | No provisioning profile yet | Add `-allowProvisioningUpdates` to the xcodebuild call, or just build once from Xcode |
| `Untrusted Developer` on the phone | Certificate not trusted on the device | Settings ▸ General ▸ VPN & Device Management ▸ Trust |

The app uses the team's wildcard provisioning profile, so no App Store Connect record is needed for
`app.snap2ink.camera` and nothing has to be created before building.

</details>

**Use a Debug build** (⌘R does this by default). The calibration target in §4 and the diagnostics
screen are both `#if DEBUG` only, and the checklist needs them.

### The two hidden controls

Both are documented here because the checklist needs them; neither is a shipping feature.

- **Tap the status bar** (the coloured line at the top) → **Diagnostics**. Shows what the device
  advertised: pixel size, image cap, icon size, last `IMAGE_STATUS`, plus what this app is sending.
  Several steps below ask you to record values that are visible nowhere else on the phone.
- **Long-press the shutter for 1 second** → loads the §4 calibration target instead of taking a
  photo.

### Serial console (needed for §2 and §3.3)

Connect the reader by USB and open a serial monitor at 115200 baud (`pio device monitor` from the
firmware repo, or any terminal program). Type a command and press return:

| Command | Does |
|---|---|
| `CPING` | Replies `pong v6` — confirms the console is alive |
| `CRESET` | **Forgets all paired phones.** This is how you get back to never-paired for §2 |
| `CCAP` | Dumps the capability block — cross-check against the Diagnostics screen |
| `CPEERS` | Lists enrolled peers |
| `CBUTTONMAP` | Dumps the button map the device has stored for the foreground app |
| `CBTN <id> <ms>` | Injects a button press: id 0=BACK 1=CONFIRM 2=LEFT 3=RIGHT 4=UP 5=DOWN |

There is no on-device unpair UI and no protocol opcode for it — `CRESET` over serial is the only way.

### Recording results

For each step write PASS, FAIL or SKIP plus what you actually saw. "Looked fine" is not a result;
"four distinct greys, left to right dark→light" is. **Report failures rather than working around
them** — see the warning at the top.

---

## 1. Camera

| # | Do this | Pass condition |
|---|---|---|
| 1.1 | Launch, grant camera access | Live image in the viewfinder within ~2s |
| 1.2 | Deny camera access (Settings ▸ Snap2Ink ▸ Camera off, relaunch) | Placeholder reading "No camera here", **no crash**; the shutter still produces a test card |
| 1.3 | Re-grant access, tap the flip control | Preview switches to the front camera |
| 1.4 | Front camera: raise your right hand, watch the preview | Preview is **mirrored** — your hand appears on the preview's left |
| 1.5 | Front camera: take the photo, look at the proof | Proof matches what the preview showed; **not** flipped back |
| 1.6 | Hold the phone in landscape, take a photo | Result is **cropped**, not rotated; the print stays portrait |
| 1.7 | Frame an object just **inside** the white guide rectangle, shoot | The object survives into the proof |
| 1.8 | Frame an object just **outside** the guide, shoot | The object is **absent** from the proof |

1.7 and 1.8 together are the real test — either alone proves nothing.

---

## 2. Enrolment — first contact

This is the one flow with a step that **cannot happen on the phone**.

| # | Do this | Pass condition |
|---|---|---|
| 2.0 | Run `CRESET` over serial first | Replies `reset ok`. The reader is now never-paired, which is what makes 2.2 happen |
| 2.1 | Launch with the reader awake and nearby | Status bar: "Looking for your reader…", then "Connecting…" |
| 2.2 | Watch **the reader** | It shows a pairing prompt **naming Snap2Ink** |
| 2.3 | Watch the phone at the same time | Status bar: **"Confirm on your reader"** — not a spinner |
| 2.4 | Press **CONFIRM on the reader** | Phone moves to "Reader ready" within ~1s |
| 2.5 | Read the reader's on-screen button hints | Bottom row shows **"Sleep"** and **"Shutter"** |
| 2.5b | Run `CBUTTONMAP` over serial | 6 buttons; CONFIRM is routing 1 (REMOTE) labelled "Shutter"; LEFT and RIGHT are routing 0 (NONE); **0 tags** — Snap2Ink declares none |
| 2.6 | Look where page-turn hints normally appear | **No hint** for LEFT or RIGHT — they are routed `NONE` |
| 2.7 | Let the reader sleep; look at the sleep-screen grid | Snap2Ink's camera icon is present, **dark camera on a light ground** |

If 2.7 shows a light camera on a dark ground, the icon's bit polarity is inverted somewhere. The
protocol document specifies that a set bit is ink, which is what this app emits — so that would be a
firmware finding, not an app setting to flip.

### 2b. Refusals

| # | Do this | Pass condition |
|---|---|---|
| 2.8 | `CRESET`, force-quit and relaunch the app, press **BACK** at the prompt | Phone: "Pairing declined on the reader", plus a Reconnect button |
| 2.9 | `CRESET`, relaunch, then ignore the prompt entirely | Phone eventually: "Pairing timed out" |

After 2.9, run `CRESET` once more and pair normally before continuing — the rest of the list assumes
a paired reader.

---

## 3. Reconnect

| # | Do this | Pass condition |
|---|---|---|
| 3.1 | Force-quit and relaunch | Reconnects with **no** prompt on the reader |
| 3.2 | Walk out of range ~30s, then return | Recovers with no user action |
| 3.3 | Delete the app, reinstall from Xcode, launch | Pairing prompt appears **again** — expected, see below |
| 3.4 | Run `CPEERS` over serial after 3.3 | **Two** peers listed for Snap2Ink — the orphan plus the new one |

3.3 is not a bug. `installId` lives in `UserDefaults`, which app deletion clears, so a reinstall is a
new peer by design. 3.4 makes the cost visible: the old peer directory stays on the reader's SD card
and nothing reclaims it, because unpairing is on-device only. Record the peer count — if it climbs
with every reinstall, that is worth reporting even though it is working as designed.

---

## 4. The dither fidelity check — the most important test here

**The claim being tested:** the panel shows the phone's bit pattern verbatim. The phone dithers to
`{0, 85, 170, 255}`, the firmware decodes with its own dither disabled, and nothing resamples or
re-quantizes in between. If that is false, every print is subtly wrong and the four-level contract is
broken.

Comparing a photograph pixel-for-pixel by eye is impossible, so the app ships a calibration target
that turns it into things you can genuinely judge.

**To send it: long-press the shutter button for 1 second** (Debug builds only). That loads the target
as the proof; then press "Send to reader". It goes through the app's own encoder and transport —
deliberately, so a failure implicates the real path. It bypasses dithering entirely, because it is
already exact, so **any difference on the panel is downstream of the phone.**

The sheet is eight equal horizontal bands. Read them top to bottom:

| Band | Correct | A failure means |
|---|---|---|
| 1 (top) | **Four** solid patches, **darkest on the left** | Fewer than four distinct greys → the palette collapsed. Light-to-dark → inverted. |
| 2 | Crisp fine **vertical** stripes | Flat grey → horizontal resampling |
| 3 | Crisp fine **horizontal** stripes | Flat grey → vertical resampling |
| 4 | Fine even texture (1px checkerboard) | Flat grey → resampling in both axes |
| 5 | Vertical stripes **visibly wider** than band 2 | Flat while band 2 is crisp → downscaled ~2× |
| 6 | **Three** sections, each a different texture | Any section flat → two adjacent levels merged |
| 7 | Repeating 4-step dark→light staircase | Banding or merged steps → bucket boundaries are off |
| 8 (bottom) | Plain white | Not white → the paper level is wrong |

Then, across the whole sheet:

| # | Check | Pass condition |
|---|---|---|
| 4.1 | The border | Exactly **one pixel** of black, touching all four edges |
| 4.2 | The centre cross | One-pixel lines crossing at the exact middle |
| 4.3 | Coverage | Fills the panel — **no** white margin outside the border |
| 4.3b | Look at the white band at the bottom | Clean white, with **no ghost** of whatever was on the panel before |
| 4.4 | Open **Diagnostics** (tap the status bar). Compare "Screen pixels" with "Current print → Pixels" | The two must be **identical**. Record both. Expected **528 × 792** on an X3 |
| 4.5 | Cross-check with `CCAP` over serial | Same pixel size as the Diagnostics screen reports |

A **two-pixel** border, or a border inset with white outside it, means the image was scaled or
centred: either the app sent the wrong dimensions, or the panel is not the 528×792 the capability
characteristic advertised. Report the advertised value.

4.3b is worth doing deliberately. Firmware found and fixed a bug where `renderImage()` never drew the
black/white base before overlaying the grayscale planes, so every print settled on top of whatever
was already on screen. Push the calibration target **twice in a row from different starting screens**
(once after a text screen, once after another photo) — the white band and the four level patches must
look identical both times. Ghosting there means the fix regressed or is incomplete.

If 4.4 shows two different sizes, **stop and report it** — the app is about to push an image the
device will scale and resample, and every subsequent dither observation would be meaningless.

**Only once the target passes** does a photograph tell you anything. Then:

| # | Do this | Pass condition |
|---|---|---|
| 4.6 | Print a photo; compare the panel with the phone's proof | Same dither texture; no banding the proof does not have |
| 4.7 | Print the same photo with all four dithers | Four visibly different looks on the panel |

E-ink contrast is nothing like an OLED's, so the *ranking* may differ from the proof — that is
expected. Texture appearing or disappearing is not.

---

## 5. The image push, end to end

| # | Do this | Pass condition |
|---|---|---|
| 5.1 | Send a print; watch the progress bar | Advances smoothly, reaches 100% |
| 5.2 | Watch what happens **at** 100% | App switches to "Developing…" and stays there for a noticeable interval |
| 5.3 | Watch the panel during that interval | The two-pass grayscale settle visibly runs |
| 5.4 | Watch the app after the panel settles | Moves to "It's on your reader." |
| 5.5 | Time the whole send | Record the number |
| 5.6 | Open **Diagnostics**, read "Last image status" | `displayed` |

**5.2 is an adversarial test of the firmware's ack timing.** `pushImage` is documented not to return
until the device has decoded and displayed the image. If the app snaps from 100% straight to "It's on
your reader" with no developing phase, the firmware is acking earlier than documented — a firmware
finding, and it also means the developing animation has no window.

If 5.5 is far from the mock's assumed ~20ms/packet plus a 4s settle, `DevelopingView`'s pacing needs
the real number.

A `DECODE_FAILED` in 5.6 on a file this app encoded is a firmware finding. The PNG is **2-bit**
grayscale, colour type 0, uninterlaced, filter None, at exactly the advertised pixel size — what the
document recommends, and it round-trips through an independent decoder in the unit tests.

---

## 6. Remote shutter

Prop the reader up **across the room** — the whole point is that the phone is out of reach.

| # | Do this | Pass condition |
|---|---|---|
| 6.0 | Optional dry run: `CBTN 1 0` over serial | Same effect as physically pressing CONFIRM — useful if the reader is out of reach |
| 6.1 | At the viewfinder, press **CONFIRM** on the reader | The phone takes a photo |
| 6.2 | Press **DOWN** (Timer) | The phone's timer control switches to 3s |
| 6.3 | With the timer on, press CONFIRM on the reader | Phone counts 3–2–1 on screen, then captures |
| 6.4 | **Hold** CONFIRM for 3 seconds (or `CBTN 1 3000`) | **Exactly one** photo, not one every 100ms |
| 6.5 | With a proof on screen, press CONFIRM | It sends |
| 6.6 | After a print has landed, press **UP** (Redevelop) | The same print is pushed again |
| 6.7 | Press **BACK** | The reader sleeps, and the phone shows **no** reaction at all |

6.4 is the one most likely to break: the firmware repeats the notification while a button is held and
the app acts only on the initial press. 6.7 confirms `LOCAL_SLEEP` really is handled on-device — any
phone-side reaction means a `REMOTE` notification is arriving that should not be.

---

## 7. Losing the screen

| # | Do this | Pass condition |
|---|---|---|
| 7.1 | Open SpokenFeeds and let it take the screen | Snap2Ink: "Another app has the screen" |
| 7.1b | *If SpokenFeeds is not installed*, skip §7 entirely and say so | — |
| 7.2 | Return to Snap2Ink | It reacquires and **automatically re-pushes** the last print |
| 7.3 | Let another app take the screen **mid-transfer** | The print is **not** reported as delivered |
| 7.4 | Power off the reader mid-transfer | App reports the failure and returns to the proof — no stalled progress bar |

7.2 is worth watching closely. The device retains nothing for a backgrounded session, so the panel
would otherwise show another app's content or nothing at all. The re-push should need no user action.

---

## 8. Size limits

| # | Do this | Pass condition |
|---|---|---|
| 8.1 | Open **Diagnostics**, read "Max image bytes" | Expected: **131072** (128 KB) |
| 8.2 | Photograph dense fine detail (foliage, gravel, a crowd) with Floyd–Steinberg; read the size under the proof | Under the cap |

Measured worst case at 528×792 is Floyd–Steinberg at **~39 KB**, so expect roughly 3× headroom. From
the unit tests: Atkinson 31.9 KB, Floyd–Steinberg 38.6 KB, ordered 6.0 KB, flat 4.0 KB, calibration
target 0.9 KB.

If 8.1 reports much less than 128 KB, those are the numbers to check it against. If a print does
exceed the cap, the app must say it fell back to Ordered rather than silently changing the look.

---

## 9. Worth watching throughout

- **Free heap on the reader during a print.** The firmware streams the PNG to SD rather than
  buffering it, so a ~45 KB print should barely move it. A sharp drop means something is holding the
  image in RAM — a firmware finding.
- **The panel's settle duration.** Feeds directly back into `DevelopingView`'s pacing.
- **Anything that looks like a firmware bug.** Nothing here has been verified on the wire. Report it
  rather than adjusting the app to compensate — a workaround would hide the bug from the firmware
  side and bake a wrong assumption into the client.
