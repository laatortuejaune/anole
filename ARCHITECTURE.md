# Anole

GPS location simulation for iPhone, in two applications sharing the same core:
a **macOS** application that drives the tethered iPhone, and a standalone
**iOS** application that changes its own location with no computer involved.

Both work. This file is enough to pick the project back up without rediscovering
anything.

## Architecture

Four modules. The rule that holds everything together: **the interface knows
nothing but the `LocationBackend` protocol**, never the backend. That is what
made it possible to port the project to the iPhone without touching the logic.

| Module | Contents | Platforms |
|---|---|---|
| `AnoleCore` | Geodesy, coordinate and URL parser, GPX, `PathGeometry`, `SpeedPlanner`, `TripSchedule`, `LocationBackend` protocol, error codes | both |
| `AnoleServices` | `TripModel` (all the logic), place search, MapKit routes, real location | both |
| `AnoleMac` | macOS interface (SwiftUI, `NavigationSplitView`) | macOS |
| `AnoleiOS` | iPhone interface + `IDeviceBackend` | iOS |

The `AnoleCore` files that drive subprocesses (`NDJSONChannel`,
`ProcessRunner`, `PyMobileDevice3Backend`, `HelperProtocol`, `DeviceListing`)
are wrapped in `#if os(macOS)`: iOS has no subprocesses.

## The two backends

**macOS** — `PyMobileDevice3Backend` drives `Helper/anoled.py`, a persistent
Python daemon (pymobiledevice3, GPL-3.0) that keeps the tunnel and the service
channel open. It communicates in NDJSON over stdin/stdout.
Persistence is not a convenience: **the simulated location dies with the
channel**, so restarting a command line tool on every movement would lose it
every time.

**iOS** — `IDeviceBackend` calls the Rust library `jkcoxson/idevice` (MIT)
directly, compiled into `Vendor/IDevice.xcframework`.
Chain: `rp_pairing_file_read` → `tunnel_create_rppairing` →
`remote_server_connect_rsd` → `location_simulation_new/set/clear`.

## Commands

```bash
# macOS: build, tests, application
swift build && swift test          # 129 tests
./Scripts/build-app.sh release     # produces build/Anole.app
./Scripts/setup-backend.sh         # venv + pymobiledevice3 (once)

# iOS: the Xcode project is GENERATED, never edit the .xcodeproj
xcodegen generate                  # after adding any file
xcodebuild -project AnoleiOS.xcodeproj -scheme AnoleiOS \
  -destination 'platform=iOS,id=<UDID>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> <.app path>
```

Find your device UDID with `xcrun devicectl list devices`.

Your Apple team ID is the **OU field** of your signing certificate, not the code
in parentheses in its name — that one identifies the certificate itself. Read it
with:

```bash
security find-certificate -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',' '\n' | grep OU=
```

Export it before generating the project, it is never committed:

```bash
export DEVELOPMENT_TEAM=XXXXXXXXXX
```

## USB or Wi-Fi

`usbmuxd` is not only about USB despite its name: once a device has been paired
and Wi-Fi sync is on, it stays reachable over the local network, and both the
tunnel and the DTX channel work over it. `usbmux list` then returns the same
device twice, once as `USB` and once as `Network`.

`DeviceListing` merges the duplicate and prefers USB when both are available.
The interface shows which link is in use, because a dropped link mid-trip is
otherwise indistinguishable from a bug.

Measured, not assumed: a long trip runs to completion over Wi-Fi with the phone
locked. Wireless is a first-class mode here, not a fallback.

## Constraints worth knowing

- **Free developer account: the provisioning profile expires 7 days after
  installation.** The iOS application then refuses to launch; rebuilding and
  reinstalling is enough. A paid account extends this to a year.
- **LocalDevVPN must be connected** before opening the iOS application. An iOS
  application cannot reach `127.0.0.1` to talk to the services of its own
  device: it goes through the virtual interface `10.7.0.1:49152`.
- **Recent iOS versions provide the developer disk image themselves** through a
  system cryptex mounted on `/System/Developer`. There is therefore nothing to
  mount, and a version gap between Xcode's image and the device's is of no
  consequence.
- The pairing file lives in `Documents/pairing.plist` of the application
  container. It survives reinstallations. To remake it:
  `pair_host --name Anole --out pairing.plist` on the Mac, then on the iPhone
  Settings > Privacy & Security > Developer Mode > Other devices.
  **The Mac is what shows the code, the iPhone is what types it in.**
- On the macOS side, the developer disk image **unmounts on every reboot** of
  the iPhone and is remounted with `pymobiledevice3 mounter auto-mount`
  (Internet connection required: Apple signs it for this device).

## Traps already hit

- `image_mounter_mount_personalized_with_callback_rsd` **calls its progress
  callback without checking that it exists**: a null pointer makes the program
  jump to address zero, and iOS then reports `CODESIGNING / Invalid Page`,
  which throws the diagnosis completely off.
- `NSConcreteTask.terminationStatus` raises an Objective-C exception **that
  Swift cannot catch** as long as the process has not terminated, and
  `terminate()` is asynchronous. Never read that status in `stop()`.
- On iOS, the "while using the app" authorization returns
  `.authorizedWhenInUse`, not `.authorizedAlways`: forgetting that case makes
  the app ask for authorization over and over without ever locating.
- `MKLocalSearch.Request` is what it is called in Swift, **not**
  `MKLocalSearchRequest`.
- "No results" from `MKLocalSearch` arrives as an **error**
  (`MKErrorDomain` code 4), not as an empty array.
- `regionPriority` (macOS 15 / iOS 18) is the **only** lever that really biases
  a search towards a region; without it, filling in `region` has almost no
  effect. But it sabotages unique places outside that region, hence the two
  concurrent searches in `PlaceSearchModel`.
- `MapKit does not compute cycling routes`: we ask for a walking trip, whose
  announced duration is therefore a walking one. Without transposition, the
  bike rides at 5 km/h.
- Without Xcode, SwiftUI does not compile: `libSwiftUIMacros.dylib` does not
  ship with the Command Line Tools.

## The speed profile, in a nutshell

Driving at the legal limit gives a trip that is **48% too fast**: the limit
ignores roundabouts, lights and traffic. So we take the duration announced by
the routing service and redistribute it through a physical profile (curvature,
stops at intersections, bounded acceleration), calibrated by bisection on a
cruise factor. The speed really does vary, and the arrival time is right.

`TripSchedule` precomputes the whole trip: the emission loop only has to read a
table indexed by elapsed time. A send that drags therefore does not shift the
trip, it skips a point.

### Where the limits come from

MapKit gives a polyline and a duration, never the identity of the roads. The
limits are recovered by matching the track against OpenStreetMap through the
Overpass API (`OverpassSpeedLimits`), one query covering every route candidate.
`SpeedLimitMatcher` then probes the track every 25 m and asks which segment it
is on: nearest wins, but only among segments whose heading agrees within 45°.
That gate is what stops a crossing road at a junction from dropping its own
limit across the middle of a trunk road; distance alone handles the service road
running parallel.

Each stretch feeds `SpeedSample`: `legalLimit` is a hard ceiling, `travelSpeed`
is that limit times the class flow factor — the diffuse loss from traffic and
merges, *not* stops and turns, which the planner already models and would
otherwise count twice. Bisection then scales the whole thing onto the announced
duration, so the total stays exact while the distribution becomes right.

Every failure is silent by design: `segments()` returns an empty array, the
planner falls back on the pace of the mode, and the trip leaves regardless.
Overpass runs on donated hardware, hence the 300-probe ceiling, the cache and
the identifying user agent.

## Error codes

Numbered in `Sources/AnoleCore/ErrorCodes.swift`, displayed in brackets.
The hundreds group by domain: **1xx** tooling, **2xx** device, **3xx** link,
**4xx** developer services, **5xx** real location, **6xx** route,
**9xx** miscellaneous.

## Conventions

- Comments and interface in English, ASCII only in the source code.
- Comments say **why**, not what the code already shows.
- Any non-obvious behavior deserves a test that locks it down.
- Never edit `AnoleiOS.xcodeproj`: it is generated from `project.yml`.
