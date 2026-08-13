# Profiler

A native macOS and iPadOS laser beam profiler that uses a Sony α7C — or any UVC camera — as
the sensor. Profiler is a single-window SwiftUI app: connect a camera and the window shows
the live beam with integrated horizontal and vertical profiles, ISO 11146 second-moment
widths, centroid, ellipticity and azimuth, and a closed-loop ISO servo.

A measurement leaves the app through the toolbar share button — the beam image as PNG,
both profiles as CSV, and the metrics as JSON — or by dragging the image or either profile
chart straight out of the window.

No vendor SDK or third-party library is required. The app talks to the camera over PTP
through Apple's `ImageCaptureCore` pass-through API.

## Build

```
make          # debug build
make release  # optimised build
make run      # build and launch
make test     # build, then validate the analyser against known beams
make bench    # where a frame's time goes, stage by stage
make ios      # optimised build for an iPad
make ios-sim  # build for the iOS Simulator
make icon     # re-render the app icon
make clean
```

`make` builds the same scheme Xcode does, but into its own DerivedData
(`build/DerivedData`), so a `make` and a ⌘B can never race each other's codesign — two
build systems writing one Products directory is how "Command CodeSign failed" happens.
Concurrent `make` invocations serialize behind a lock for the same reason; a second one
waits rather than colliding.

One target builds both platforms: macOS 14 and iPadOS 17. The measurement core, the PTP
stack and the UI are shared; only the window chrome and the camera lifecycle differ.

### Running on an iPad

Installing is a ⌘R from Xcode. **Set Edit Scheme › Run › Build Configuration to Release
first** — the analyser is numeric code in a per-frame loop, and the debug build is around
100× slower: `make bench` measures one frame at 8 ms in Release against 850 ms in Debug.
A debug build therefore drops most frames and reads as the app being broken rather than
unoptimised.

The camera connects over USB-C, running on its own battery. Two differences from the Mac
worth knowing:

- **Backgrounding ends the session.** iOS takes the USB device away as soon as the app
  leaves the foreground, so the app closes the camera session on the way out rather than
  waiting to be terminated. Returning to the app means connecting again.

## Camera setup

**PC Remote (PTP) — full control.** On the camera: `MENU › Network › USB Connection Mode ›
PC Remote`. Put the mode dial on **M**, **S** or **A** and take ISO off AUTO, otherwise the
body refuses ISO writes and the app will say so. This backend gives live view plus
read/write access to ISO, shutter and aperture, so the auto-gain servo can close the loop.
Live view runs roughly 10–15 fps at around 1024×680.

**USB Streaming (UVC) — higher resolution, no control.** `MENU › Network › USB Connection
Mode › USB Streaming`. Clean 1080p, but macOS exposes no ISO API for capture devices
(`AVCaptureDevice.ISO` and `setExposureModeCustom` are both `API_UNAVAILABLE(macos)`), so
the servo degrades to an advisory that tells you how many stops to dial in on the body.

**Synthetic** — a simulated elliptical Gaussian with known ground truth, shown alongside the
measured values in the inspector. Use it to sanity-check the analyser and exercise the servo
without a laser.

Settings are remembered per camera, keyed to the device's identity, because the setting that
matters most — µm/pixel — describes the optical setup that camera sits in rather than a
global preference. The last backend and camera are restored on launch, and the app waits for
the remembered camera to enumerate before starting.

## When connecting is unreliable

PTP allows exactly one session per device, so almost every connection failure is something
else holding the camera — or a previous session that was never closed.

**Stop macOS grabbing the camera first.** This is the most common cause. Open
**Image Capture.app**, select the camera in the left list, expand the small triangle at the
bottom-left, and set *Connecting this camera opens:* to **No application**. If Photos or
Image Capture opens a session when the camera enumerates, ours cannot.

**Quit Photos** if it is running. It claims cameras opportunistically.

**Plug the camera directly into the Mac**, not through a hub. PTP live view is a stream of
bulk transfers, and a shared hub makes both the connect handshake and the frame rate worse.

**Turn off the camera's auto power off** (`MENU › Setup › Power Setting Option › Power Save
Start Time`). A body that naps mid-session drops the session, and the reconnect races the
camera waking up.

**If it wedges anyway, unplug and replug.** A camera left with an orphaned session stays
claimed until it re-enumerates. The app closes its session on quit specifically to avoid
this, but a force-quit or a crash can still leave one behind.

The app retries a failed connect three times with backoff, tears the session down between
attempts, and times out after 10 s rather than hanging.

macOS asks for removable-volume access on first connect. Opening an ImageCaptureCore session
enumerates the camera's memory card, and `ICEnumerationChronologicalOrder` is the only
`ICSessionOptions` key — there is no way to open a session while skipping the content
catalog, so the prompt is unavoidable. It should only be asked once.

## Measurement method

Widths are ISO 11146 second moments (D4σ), not fits. The pipeline is:

1. Optional dark-frame subtraction (16 frames averaged, so read noise falls by 4×).
2. Baseline estimated from four corner patches; mean and σ reported in the inspector.
3. Iterative integration aperture, sized at 3× the beam diameter per ISO 11146-1, and
   converged on the centroid.
4. Second moments → D4σ in x and y, principal-axis major/minor diameters, ellipticity
   `d_minor/d_major`, and azimuth `½·atan2(2σxy, σxx−σyy)`.
5. Marginal profiles integrated across the aperture, with a Levenberg–Marquardt Gaussian fit
   and an interpolated FWHM overlaid.

Angles are reported in lab convention: CCW positive from horizontal with y up, normalised to
(−90°, 90°]. Image rows run downward, so the sign is flipped on the way out — the on-screen
major-axis tick lets you confirm it visually.

### Two things worth knowing about the numbers

**Thresholding does not touch the data the moments run on.** The noise threshold is used only
to locate the beam and size the aperture. Computing moments on clipped data truncates the
Gaussian wings that ∑I·r² depends on — with a 3σ cut on a beam whose noise floor sits at 5%
of peak, that truncates near 1.2w and biases every width about **9% low**. The self-test's
noisy case exists specifically to catch this regression; it currently reads +0.4%. Inside the
aperture the baseline is subtracted but negative noise samples are kept, because discarding
one sign of a zero-mean fluctuation is itself a bias.

**Saturation invalidates the measurement.** Clipped pixels remove exactly the high-intensity
core that dominates the second moment, so every width reads low. The app flags this in red
over the image and the servo treats over-exposure asymmetrically — an immediate ≥1 stop
correction, versus a gentle walk up when under-exposed.

## Calibration

All sizes scale with **µm/pixel**, set in the sidebar. For a bare sensor with the lens
removed, the α7C's 35.6 mm imager is 6000 px wide natively (5.94 µm pitch), so a downscaled
stream scales proportionally — the "Use bare-sensor pitch" button computes
`35600 / frame_width` for you. With a lens in the path the magnification is yours to
determine; the field is free-form.

The **Channel** picker matters for a Bayer sensor: every channel is spatially undersampled,
green has twice the sampling density of red or blue, and luma mixes channels with different
spectral responses. For a monochromatic source, pick the channel matching its wavelength.

## Protocol provenance

Profiler speaks PTP directly through Apple's public `ImageCaptureCore` pass-through API
(`ICCameraDevice.requestSendPTPCommand`). It does **not** use, link, or embed the Sony
Camera Remote SDK, and no part of that SDK was downloaded, decompiled or consulted.

The standard operation and response codes are ISO 15740. The Sony vendor extensions in the
0x9xxx and 0xDxxx ranges are taken from the public libgphoto2 `camlibs/ptp2` camera library,
which has documented them for well over a decade — the constant *values* only, as facts about
a wire format. No libgphoto2 code was copied, so the binary carries no LGPL obligation. This
matters for App Store distribution: Sony's SDK licence carries consent-capture and
termination conditions, and libgphoto2's LGPL relinking requirement is widely held to
conflict with App Store terms.

Going through ImageCaptureCore rather than IOKit also means macOS's own ImageCapture stack
keeps ownership of the device, so there is no fight with `ptpcamerad` over the USB interface,
and no third-party binaries to re-sign.

## Status

Verified: the measurement core against analytically-known beams (`make test`) — noiseless
cases are exact, the noisy case within 0.5%; the PTP path end to end against an ILCE-7C,
including the `SDIOConnect` handshake, property decode (ISO, shutter) and live-view capture.

Not yet verified: the PTP path under the App Sandbox. The app was developed unsandboxed and
sandboxing is enabled here to match the App Store target; camera enumeration and session
opening should be re-checked on a sandboxed build before shipping.

On iPadOS, verified only that the app builds, launches and analyses correctly — the
synthetic beam reproduces its ground truth on an iPad simulator. **The camera path is
entirely unverified on iPad.** Every PTP call the app makes is declared available on iOS
(`ICDeviceBrowser` and `requestSendPTPCommand` from 13.0, `browsedDeviceTypeMask` from
15.2), but availability is not the same as behaviour: ImageCaptureCore shipped on iOS for
photo *import*, and whether its device browser enumerates a body in PC Remote mode — which
presents differently over USB — has not been tested against real hardware. That is the
assumption the whole iPad port rests on, and it needs an iPad and a camera to settle.

## Layout

```
apps/Profiler/Sources/
  Camera/PTP/     PTPCodec, PTPTypes, PTPTransport (ImageCaptureCore), SonyPTP
  Camera/         FrameSource protocol, PTPSource, UVCSource, SyntheticSource, GainController
  Analysis/       BeamAnalyzer (ISO 11146), GaussianFit (LM), Colormap, BeamFrame
  Model/          ProfilerModel, AnalysisPipeline, SettingsStore
  UI/             ContentView (NavigationSplitView + inspector), MeasurementView,
                  SettingsSidebar, MetricsInspector, BeamImageView, ProfileChartView
  SelfTest.swift  Analyser validation against known beams

apps/Profiler/Assets.xcassets/  App icon, generated by Scripts/make-app-icon.swift
```

The icon is drawn rather than painted: an astigmatic Gaussian through the app's own Turbo
table, cropped by the icon's edges, with the D4σ ellipse dashed over it at the beam's 1/e²
radius. `make icon` regenerates it, and it compiles `Colormap.swift` in rather than copying
its colours, so the icon and the beam view cannot drift apart.

The window is a standard three-column macOS layout: a navigation sidebar holding every
*input*, the instrument display in the centre, and a trailing inspector holding every
measured *output*. Controls and results never share a pane, so there is no ambiguity about
which numbers you can change and which the camera is telling you. The horizontal profile sits
directly above the image and the vertical profile directly right of it, sharing the image's
fitted extent so features register across all three, and sharing one amplitude scale so the
two profile heights are directly comparable.

## Licence

Apache 2.0. See [LICENSE](LICENSE).
