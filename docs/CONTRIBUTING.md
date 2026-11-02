# Contributing to NOOP

NOOP is a local macOS SwiftUI app for WHOOP data. Work from the current source and [screen map](SCREEN_INVENTORY.md), not old feature proposals. The product name is NOOP; the target and scheme remain `Strand`.

## Before changing code

1. Read [README](../README.md), [architecture](ARCHITECTURE.md), and the relevant package sources/tests.
2. Check `git status` and preserve unrelated local work. Distinguish committed behavior from in-progress files before documenting a feature as released.
3. Keep changes focused on the existing app. There is no mobile app target, cloud integration, coaching/automation screen, or Apple Health import UI to maintain.
4. Keep the project and upstream credits in [ATTRIBUTION.md](../ATTRIBUTION.md).

## Where changes belong

| Concern | Location |
| --- | --- |
| BLE transport, connection lifecycle, command dispatch | `Strand/BLE/` |
| Historical collection, clocks, raw archives | `Strand/Collect/` |
| Protocol parsing and fixtures | `Packages/WhoopProtocol/` |
| Schema, queries, persistence, cache invalidation | `Packages/WhoopStore/` |
| Scoring and signal analysis | `Packages/StrandAnalytics/` |
| File parsing | `Packages/StrandImport/` |
| Shared visual tokens/components | `Packages/StrandDesign/` |
| App orchestration and UI read model | `Strand/App/`, `Strand/Data/` |
| Screens/navigation/menu bar | `Strand/Screens/`, `Strand/App/RootView.swift`, `Strand/MenuBar/` |

Shared packages retain their declared platforms, but platform declarations do not prove an iOS app exists or is tested. Test fixtures belong in package test resources; private exports and databases do not belong in Git.

## Build and verification

Follow [BUILD.md](BUILD.md). Run the affected package tests; run hosted app tests for app integration changes. Regenerate with `xcodegen generate` after changing `project.yml` or adding app source files. Do not hand-maintain the ignored generated project.

For protocol changes, run Swift fixture tests and the Python decoder tests. For storage changes, cover migration from existing data and replay/idempotence where relevant. For scoring changes, test missing data, gaps, day boundaries, provenance, and incremental invalidation; update the scoring version when semantics change. For UI changes, build the app and inspect the affected screens and states.

Documentation-only changes need path/link checks and a source comparison, not a full hardware test run. Record which checks actually ran and which require a device or private data.

## UI and behavior

Reuse `StrandPalette`, `StrandFont`, `StrandMotion`, `NoopMetrics`, and existing components before introducing new ones. Show live heart rate through `LiveHeartRate` and strap battery through `BatteryPresentation`; do not derive either again in a view. Observe the narrowest object a view needs: `LiveState` changes many times per second during a sync, so a view that only shows a stored score must not subscribe to it. Consolidate repeated styling in `StrandDesign`; keep domain logic out of view bodies. Follow native macOS control, keyboard, focus, sheet, and accessibility conventions. Respect reduced motion and distinguish status through text as well as color.

Keep Overview → detail, Trends → history, and Settings → configuration/tools coherent. The same metric should use the same units, date window, provenance, missing-data state, and wording wherever it appears. Do not add destinations just to expose internal implementation details.

## Data, performance, and Bluetooth

- Keep processing local. Do not add telemetry, account services, or runtime network dependencies.
- Preserve raw data, user-entered records/corrections, imported provenance, database migrations, and backup compatibility. Add migrations rather than rewriting already-applied ones.
- Keep expensive querying/scoring off the UI actor. Preserve ordered historical ingestion, bounded work, cancellation, cache invalidation, and incremental scoring. Measure improvements with representative inputs instead of equating fewer files with faster execution.
- Use a **copy** of the database for performance/replay tools: opening a store can run migrations. See the tool headers for arguments.
- Treat BLE as a bidirectional hardware protocol, not a read-only API. Clock, stream, history acknowledgement, broadcast, and alarm commands can affect device state. Preserve command allowlists and the retention/acknowledgement safeguards; consult the [safety matrix](reverse-engineering/SAFETY_MATRIX.md) and [command registry](reverse-engineering/COMMAND_REGISTRY.md).
- Validate checksums and bounds; retain fixture evidence for decoder changes. Never promote an unknown command to a safe app operation based only on its name or a successful response. Keep destructive/firmware commands out of routine app flows.
- Distinguish measurements, estimates, imported values, and unavailable results. Preserve causal baselines and metric identities. See [MEASUREMENT_VALIDITY.md](MEASUREMENT_VALIDITY.md).

## Review expectations

Explain the concrete behavior change, relevant tests, and any remaining uncertainty. Remove files only after checking callers, target/resource membership, tests, migrations, and documentation links. A retained library API or protocol fixture is not dead merely because the current UI does not call it. Update current guides when behavior changes; label dated reports as historical instead of using them as the feature list.
