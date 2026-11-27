# Build and test NOOP

The only app target is macOS 13+. The Xcode scheme/target is `Strand`; the built product is `NOOP.app`. Package manifests use Swift tools 5.9. Use Xcode with a compatible Swift compiler and install XcodeGen before generating the project.

## Local development

From the repository root:

```sh
xcodegen generate
open Strand.xcodeproj
```

Choose **Strand → My Mac**. `project.yml` is the project definition. `Strand.xcodeproj` is generated and Git-ignored; regenerate after adding app sources or changing configuration.

For development signing, copy `Local.xcconfig.example` to `Local.xcconfig` and replace its example team ID. `Signing.xcconfig` includes this ignored local file. A stable development signature helps preserve Bluetooth permission across builds. Keep personal signing details out of commits.

The initial dependency resolution requires access to GRDB.swift and ZIPFoundation. Runtime app data processing is local. Hardware pairing/collection requires Bluetooth permission and a compatible strap; builds and pure package tests do not require a strap.

## Verification commands

```sh
swift test --package-path Packages/WhoopProtocol
swift test --package-path Packages/WhoopStore
swift test --package-path Packages/StrandAnalytics
swift test --package-path Packages/StrandImport
swift test --package-path Packages/StrandDesign
python3 -m unittest discover -s Tools/whoop_re -p 'test_*.py'
```

Unsigned local build check:

```sh
xcodebuild -project Strand.xcodeproj -scheme Strand \
  -destination 'platform=macOS' -derivedDataPath /tmp/noop-derived \
  CODE_SIGNING_ALLOWED=NO build
```

Hosted app tests (with local signing configured as needed):

```sh
xcodebuild -project Strand.xcodeproj -scheme Strand \
  -destination 'platform=macOS' -derivedDataPath /tmp/noop-derived test
```

The generated test action sets `NOOP_TEST_HOST=1`; `AppEntry` uses a bare process so tests do not start normal BLE collection or open the live store. Do not remove that isolation. Without a development team, `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO` runs the hosted tests ad-hoc signed.

`StrandDesign` snapshot tests render PNGs for visual review when `STRAND_SNAPSHOT_DIR` is set (otherwise they skip):

```sh
STRAND_SNAPSHOT_DIR=/tmp/noop-snapshots swift test --package-path Packages/StrandDesign
```

## iPhone collector shell (#76)

`StrandPhone` is an iOS 17 app target (bundle `com.noopapp.noop.phone`) that only checks it can run: app version, bundled protocol schema, an empty local store (`OpenWhoop/phone-outbox.sqlite`) and Bluetooth state on a tap. It never scans or connects to a strap.

```sh
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme StrandPhone -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath /tmp/noop-phone build
```

On your iPhone with a free Apple ID: connect the phone, turn on Developer Mode (Settings ▸ Privacy & Security), open `Strand.xcodeproj`, pick the `StrandPhone` scheme and your phone, and Run. Signing uses the team in `Local.xcconfig`. Then trust the developer profile on the phone (Settings ▸ General ▸ VPN & Device Management). A free team's install expires after 7 days; run again from Xcode to renew.

## Fixture launch

To inspect or time the real app against a **copy** of a database, without Bluetooth:

```sh
sqlite3 "file:<path to whoop.sqlite>?mode=ro" ".backup /tmp/noop-copy.sqlite"
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/noop-derived CODE_SIGNING_ALLOWED=NO SWIFT_ACTIVE_COMPILATION_CONDITIONS=NOOP_DIAGNOSTICS build
NOOP_FIXTURE_STORE=/tmp/noop-copy.sqlite /tmp/noop-derived/Build/Products/Release/NOOP.app/Contents/MacOS/NOOP \
  -noop.onboarded YES -scoringVersionApplied 5
```

Fixture launches need a diagnostic build: Debug, or Release with `NOOP_DIAGNOSTICS` as above (a plain Release build ignores `NOOP_FIXTURE_STORE`).

With `NOOP_FIXTURE_STORE` set, `StorePaths` returns that file, no CoreBluetooth manager is created (nothing scans, connects or sends a command), and the app prints `[perf] launch-to-content` and `[perf] repository refresh` timings to stderr. Fixture-only arguments: `-noop.fixture.tab trends|settings` opens on a destination; `-noop.fixture.live YES` opens the live-strap sheet; `-noop.fixture.battery cycle` plays synthetic idle → charging → full → disconnected battery states (8 s each) through the real battery surfaces, and `-noop.fixture.battery charging` holds a charging reading. The copy is opened read-write and can be migrated or re-scored; discard it afterwards. An unsigned build is not sandboxed, so it keeps its preferences in `~/Library/Preferences/com.noopapp.noop.plist`, apart from the sandboxed app's container.

## Release build

`LaunchMode.diagnostics` is true only in Debug (or with `NOOP_DIAGNOSTICS`). A plain Release build compiles out the
test host (`NOOP_TEST_HOST`), fixture launches and `[perf]` timings, the connection log and its unified-log lines,
sync-processing log lines, ops-counter files, live R–R evidence archiving, raw capture and research capture (its
Settings row is hidden). Undecodable history is still archived (`OpenWhoop/undecoded-history`): it protects data.

```sh
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/noop-release build
Tools/release/make_dmg.sh /tmp/noop-release/Build/Products/Release/NOOP.app <version>   # NOOP-<version>.dmg
```

The disk image holds `NOOP.app` and an Applications shortcut: users open it and drag NOOP onto Applications.

The build is signed with the team in `Local.xcconfig` (Apple Development); it is not Developer ID signed or notarized,
so another Mac's Gatekeeper blocks it until the user allows it in System Settings ▸ Privacy & Security. 1.0.0 is the
Mac-only release (owner decision 2026-11-27), cut from `release/1.0` before any phone work; the phone + Mac release
will take a later version. Mac-only fixes to 1.0 go on `release/1.0`.

## Diagnostic tools

| Tool | Purpose |
| --- | --- |
| `Tools/perf_probe` | Release-mode timings of store reads and scoring |
| `Tools/strain_replay` | Compare current scoring against stored NOOP results |
| `Tools/whoop_re` | Python decoder and protocol fixture tests |
| `Tools/ble_probe` | macOS BLE investigation; read the protocol safety docs first |
| `Tools/reverse_engineer` | Analysis of user-provided WHOOP export summaries |

Read each tool's source header for its actual arguments. `perf_probe` and `strain_replay` must use a **database copy**, because store initialization can migrate it. Use an exported database backup, and keep any WAL sidecars supplied by the export. Never benchmark or experiment against the user's live store.
