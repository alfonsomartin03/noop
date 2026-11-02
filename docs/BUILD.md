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

The generated test action sets `NOOP_TEST_HOST=1`; `AppEntry` uses a bare process so tests do not start normal BLE collection or open the live store. Do not remove that isolation.

## Diagnostic tools

| Tool | Purpose |
| --- | --- |
| `Tools/perf_probe` | Release-mode timings of store reads and scoring |
| `Tools/strain_replay` | Compare current scoring against stored NOOP results |
| `Tools/whoop_re` | Python decoder and protocol fixture tests |
| `Tools/ble_probe` | macOS BLE investigation; read the protocol safety docs first |
| `Tools/reverse_engineer` | Analysis of user-provided WHOOP export summaries |

Read each tool's source header for its actual arguments. `perf_probe` and `strain_replay` must use a **database copy**, because store initialization can migrate it. Use an exported database backup, and keep any WAL sidecars supplied by the export. Never benchmark or experiment against the user's live store.
