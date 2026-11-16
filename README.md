# Clean Mirror

Shows a Mac screen on an external monitor through a Blackmagic Design playback box (such as the UltraStudio Monitor 3G), so the picture never goes through the Mac's own display output.

It was built by someone who gets migraine-like symptoms from LCDs on Apple Silicon Macs, as an experiment in avoiding the temporal dithering Apple applies at the display output. It isn't a medical device, and there's no guarantee it will help you.

## Why this might help

On Apple Silicon, the display hardware (the DCP) dithers the picture right before it leaves the Mac. Tools like [Stillcolor](https://github.com/aiaf/Stillcolor) switch that dithering off with a system flag, but they don't help everyone.

Clean Mirror takes a different route:

1. It creates a 1920×1080 virtual screen, which appears in macOS as a second monitor.
2. It captures that screen with Apple's ScreenCaptureKit. The capture is taken from the composited picture, before the display hardware.
3. It converts each frame to 8-bit YUV 4:2:2 with a fixed Rec.709 formula. There's no dithering, and the same input always gives the same bytes.
4. It sends the frames over Thunderbolt to the Blackmagic box, which generates its own HDMI/SDI signal on its own clock.

The Mac's display output never touches the picture.

## What's been measured so far

On one Mac mini (Apple M6, macOS 27) with an UltraStudio Monitor 3G:

- **Captured frames are clean, with the Mac's dithering on or off.** The built-in self-test compares each captured frame with the previous one and counts any pixel that changed where macOS didn't redraw anything. Over a minute with a video playing:
  - With Stillcolor active, 2,397 frames were compared, and stray changes appeared in 2, both while switching apps.
  - With Stillcolor off and the dithering flag confirmed on, 2,408 frames had stray changes in 3, at the same app switch.
  - The remaining frames were identical outside the redrawn areas, including over photos with smooth tones.
- **The box output is steady.** A 16-minute session sent 58,859 frames at 60 fps, with 0 late and 1 dropped.
- **Same monitor, two paths.** The author compared one portable monitor (a generic 17.3" 1080p panel) both ways. Plugged straight into the Mac, it's uncomfortable. Through the box with Clean Mirror, it's comfortable. Same panel, same backlight; only the path the picture takes changed. That's one person and not blinded, so treat it as a lead, not a result.

Not yet measured: the box's HDMI output with an RGB 4:4:4 capture device. If you have one, results are very welcome.

## Limits

- **1080p.** The UltraStudio Monitor 3G tops out at 1080p, and its output is YUV 4:2:2, so thin coloured text is slightly soft.
- **Soft text.** macOS text looks soft on any 1080p screen; Apple tunes text rendering for Retina displays. There's a Retina option (`--hidpi`), but most people find the standard mode sharper.
- **It can't fix the monitor.** A PWM backlight, an FRC ("6-bit + FRC" or "8-bit + FRC") panel, overdrive or dynamic contrast will still flicker, whatever signal you feed them. A native 1080p, true 8-bit, flicker-free (DC-dimmed) monitor is the best match. Set it to 1:1 pixel mapping and limited/video range on that input.
- **Undocumented macOS feature.** The virtual screen uses CoreGraphics' `CGVirtualDisplay`, the same feature BetterDisplay and DeskPad use, so a future macOS update could break it. `--main`, which mirrors your main screen scaled down instead, doesn't depend on it.
- **One app at a time.** Only one app can use the box at a time. Turn off Final Cut's A/V Output, or quit Resolve or Media Express, first.

## What you need

- A Mac with Apple Silicon running macOS 15 or later. It has only been tested on macOS 27.
- A Blackmagic Design playback device that outputs 1080p over Thunderbolt: UltraStudio Monitor 3G, UltraStudio HD Mini, UltraStudio 4K Mini, or a DeckLink card in a Thunderbolt enclosure. Only the Monitor 3G has been tested.
- Blackmagic **Desktop Video** (the driver), free from [Blackmagic's support site](https://www.blackmagicdesign.com/support/family/capture-and-playback).
- Apple's Command Line Tools, to build it. Install them with `xcode-select --install`; full Xcode isn't needed.

### Trying the idea without this app

If you already have a Blackmagic playback box, you can test the principle first: play stills or video through Final Cut Pro's A/V Output or DaVinci Resolve's video output, and see whether that's comfortable for you.

## Build

```bash
git clone https://github.com/FettleNorth/clean-mirror.git
cd clean-mirror
swift build -c release
```

## Menu bar app

```bash
./scripts/make-app.sh
open "dist/Clean Mirror.app"
```

A TV icon appears in the menu bar: an outline while the mirror is off, filled while it's on, and a warning triangle if something is wrong. If your menu bar is too full to show it, open the app again (or click it in the Dock) and its menu pops up where the pointer is. The menu has:

- **Turn Mirror On / Off.** Off removes the virtual screen and releases the box for other apps.
- **Status.** The box, the frame rate, screen frames per second, late and dropped frames, and the delay.
- **Standard (sharpest text) / Retina (smoother text)** and **Frame Rate** (60, 50, 30, 25). Changing either restarts the mirror.
- **Lowest Delay.** 2 frames queued in the box (about 33 ms at 60p) instead of 4.
- **Open at Login** and **Quit**. It remembers your settings, and whether the mirror was on.

The first time you turn it on, macOS asks for Screen Recording permission. Allow Clean Mirror in System Settings > Privacy & Security > Screen & System Audio Recording, then quit and reopen the app.

**Rebuilds and permission:** `make-app.sh` signs the app ad hoc, and macOS ties Screen Recording permission to the signature, so it asks again after every rebuild. To avoid that, run `./scripts/make-signing-cert.sh` once. It creates a code-signing certificate in your login keychain, and `make-app.sh` uses it from then on.

## Command-line tool

The same engine, plus the test tools. Run it from the project folder:

| Command | What it does |
|---|---|
| `.build/release/cleanmirror` | Create the virtual screen and show it on the box at 1080p60. Ctrl-C stops it. |
| `.build/release/cleanmirror --hidpi` | Same, with a Retina virtual screen: drawn at 3840×2160 and halved exactly. |
| `.build/release/cleanmirror --main` | Mirror your main screen instead, scaled to 1920×1080. |
| `.build/release/cleanmirror --fps 50` | Output at 25, 30, 50 or 60 fps. |
| `.build/release/cleanmirror --queue 4` | Frames waiting in the box, 2 to 8. Default 2 (least delay); more is steadier. |
| `.build/release/cleanmirror --selftest 60` | Check that captured frames are clean (main screen). Doesn't use the box. |
| `.build/release/cleanmirror --selftest 60 --virtual` | Same, on the virtual screen. Drag a window with a video onto it during the test. |
| `.build/release/cleanmirror --selftest 60 --label stillcolor-off` | Add a name to the saved report, to compare runs. |
| `.build/release/cleanmirror --testpattern` | Send a static gradient test card to the box, with no screen capture. |
| `.build/release/cleanmirror --devices` | List Blackmagic devices and the 1080p modes they can output. |

The mirror and self-test need Screen Recording permission for the app you run them from (Terminal, for example). The test pattern and device list don't.

### Self-test

Compares each captured frame with the one before. Any pixel that changed where macOS didn't redraw is a "stray" change, the kind of frame-to-frame noise dithering would cause. Each stray event prints as it happens. The report is saved as `selftest-<date-time>.txt`, along with the state of the dithering flag Stillcolor sets. If there were stray changes, a matching `.png` is saved too: a dimmed screenshot with the changed pixels in red. (It contains whatever was on your screen, so check it before sharing it.)

A handful of stray frames usually means app switches or window drags: translucent menu bar, Dock and window backgrounds shift by about one level, and macOS doesn't count that as a redraw. Dithering would show in most frames.

### Test pattern

A static card: a full grey ramp, a slow grey ramp from 96 to 160 (where dithering is easiest to spot), red, green and blue ramps, and flat patches. It's computed pixel by pixel, so nothing can dither it. A recording of it should be identical frame to frame, which makes it a baseline for capture-device measurements.

## Technical notes

- **Output format.** Through the DeckLink API, the UltraStudio Monitor 3G accepts 8-bit BGRA only at 1080p25/30, but 8-bit YUV (`2vuy`) at 25/30/50/60. So Clean Mirror always sends 8-bit YUV 4:2:2, converted with vImage: Rec.709 matrix, video range (Y′ 16–235, CbCr 16–240), clamped. That's the format the box sends down HDMI/SDI anyway, so the driver has nothing to convert.
- **Timing.** The box runs scheduled playback on its own clock. On every tick it shows the newest captured frame, and new pixels are only converted when something on screen changed.
- **Virtual screen.** 1920×1080 at 1x (or 3840×2160 with `--hidpi`), at the output frame rate, with Rec.709/sRGB primaries.

## Code layout

- `Sources/MirrorKit`: the engine (screen capture, virtual screen, box output, mirror session).
- `Sources/DeckLinkShim`: a thin C wrapper around Blackmagic's C++ DeckLink API. `sdk/` holds the Desktop Video SDK 16.0 headers.
- `Sources/VirtualDisplay`: the `CGVirtualDisplay` wrapper.
- `Sources/cleanmirror`: the command-line tool, self-test and test pattern.
- `Sources/CleanMirrorApp`: the menu bar app.
- `scripts/`: app packaging and the optional signing certificate.

## Licence

Clean Mirror is under the MIT licence (see `LICENSE`). The Blackmagic Design DeckLink SDK files in `Sources/DeckLinkShim/sdk` keep their own licence, which is in each file's header; see `NOTICE`.
