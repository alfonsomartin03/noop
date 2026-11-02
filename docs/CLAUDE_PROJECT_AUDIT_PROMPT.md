# Claude prompt: lean, fast, cohesive NOOP

Paste the prompt below into Claude with access to this repository. Read the current branch and working tree first; this prompt is an implementation task, not a claim that an audit has already been performed.

---

Audit and improve NOOP end to end. Make the existing app smaller to maintain, measurably faster, and visually/behaviorally cohesive using native Apple macOS conventions. Implement the justified changes and verify them; do not stop at recommendations.

## Establish the current state

Read README.md, docs/CONTRIBUTING.md, docs/BUILD.md, docs/ARCHITECTURE.md, docs/SCREEN_INVENTORY.md, project.yml, and relevant source/tests. Inspect git status, branch, and diffs before editing. Preserve all unrelated local changes. Identify committed features versus work in progress, especially sleep-session corrections, alarms, storage migrations and protocol experiments. Do not reset, stash, overwrite, or publish existing work without instruction.

NOOP is a macOS 13+ SwiftUI application, internally named Strand, with five local packages. Its navigation is Overview, Trends, and Settings; the menu bar, onboarding and contextual detail sheets are intentional. Apple Health parsing remains library code but is not an app import feature. Do not revive removed stress/coaching/automation screens, add mobile targets, accounts, telemetry, cloud/API integrations, or new frameworks to make the audit look productive.

## 1. Audit and reduce unnecessary files/code

Build an inventory of app entry points, package APIs, target membership, resources, fixtures, tools, dependencies and docs. Trace real callers and data ownership. Identify dead or duplicate implementation, abandoned feature remnants, repeated formatting/query/scoring work, unnecessary dependencies, obsolete documentation and unrelated project artifacts.

For each removal, record the path, why it is unnecessary, and evidence that targets, resource loading, public APIs, tests, migrations, backups and protocol fixtures do not require it. Search alone is insufficient for dynamically loaded resources or public library APIs. Fewer files is not inherently faster: prefer useful boundaries over giant merged files. Preserve attribution, protocol evidence, migrations and user data. Retained Apple Health/library functionality should be evaluated explicitly, not deleted merely because its screen is gone. Keep ambiguous compatibility removals as documented follow-ups while completing independent safe changes.

## 2. Measure and improve performance

Establish a reproducible Release baseline before optimizing. Use Tools/perf_probe and Instruments as available. Work only with disposable database copies or synthetic fixtures; opening WhoopStore can migrate a database. Never test migrations or replay against the user's live store, and never include private biometric data in reports.

Measure launch-to-usable-content, navigation responsiveness, database reads, initial versus unchanged refresh/scoring, large-history import, chart rendering, idle/live-HR CPU, memory and task/timer behavior. Record hardware, build mode, dataset size and repeated timings. If a dataset, device or profiler is unavailable, state that limitation and do not fabricate measurements.

Trace AppModel/Repository publication, SwiftUI invalidation, view-body computations, repeated date formatting/sorting, main-actor work, detached task lifetime/cancellation, repeated store queries, transaction batching, cache invalidation and chart point counts. Optimize measured bottlenecks without compromising historical packet order, ingestion durability, progress accuracy or incremental scoring. Ensure unchanged history avoids needless work and relevant late data/configuration/corrections still invalidate dependent results. Compare before/after on identical inputs and check result equivalence where semantics should stay unchanged.

## 3. Apply one coherent Apple design system

Inspect every current surface: onboarding, Overview and its details, all Trends segments, all Settings segments, workout/sleep sheets, live-strap sheet, menu-bar popover, and alarm/correction flows if present on this branch.

Review current official Apple Human Interface Guidelines relevant to macOS and accessibility. Implement a consistent macOS design compatible with the macOS 13 deployment target; use availability guards/fallbacks for newer APIs. Avoid decorative effects that increase render cost or obscure health information.

Consolidate semantic color, typography, numeric formatting, spacing, card geometry, hierarchy, chart treatment, buttons, inputs, selection, sheets and motion in StrandDesign and shared helpers. Use system typography, SF Symbols and native controls where appropriate. Review appearance/contrast behavior rather than scattering hard-coded colors. Respect Reduce Motion, keyboard navigation/focus, VoiceOver labels and non-color status cues. A new design token should replace competing usages, not add another parallel system.

Preserve the three-destination information architecture unless a concrete usability defect warrants a small change. Make navigation, detail presentation, dismissal, selection persistence, loading, empty, partial, stale, disconnected and error states behave consistently. Check small supported window sizes and dense historical datasets. Do not promise platform accessibility behavior that was not inspected or tested.

## 4. Synchronize logic with presentation

Audit each metric from source through calculation, persistence, merge, formatting and display. The same metric must have consistent units, time zone/day boundary, selected period, source precedence, rounding, labels and quality state wherever it appears. Centralize shared presentation logic without duplicating domain calculations in views.

Preserve the distinction between imported WHOOP scores and NOOP estimates, measured versus inferred values, missing versus zero, primary sleep versus naps, unknown versus awake intervals, and cardiovascular load versus perceived/strength effort. Do not silently change algorithms to improve the UI. Preserve causal baselines, provenance, user corrections, calibration and scoring invalidation; any justified semantic change needs an explicit explanation, versioning and focused regression coverage.

Review BLE changes against docs/reverse-engineering/SAFETY_MATRIX.md and COMMAND_REGISTRY.md. Do not send experimental commands to real hardware as part of this audit. Keep command allowlists, packet verification, history acknowledgements/retention safeguards, and alarm readback/failure handling intact.

## 5. Implement, verify and report

Work in reviewable batches: establish baseline, remove proven dead work, fix measured bottlenecks, consolidate styling/behavior, then verify the whole app. Complete independent improvements when another item is blocked. Do not claim success from compilation alone.

Run affected package tests and relevant hosted app tests from docs/BUILD.md. Regenerate the Xcode project when required. Add focused regressions for changed behavior; avoid tests that merely mirror implementation. Build the macOS app and visually inspect the affected screens/states, keyboard behavior and accessibility where tools permit. For performance-only changes compare derived results and provenance before/after. Check backup compatibility and migration preservation if touching persistence. Distinguish automated checks from manual/device verification still needed.

Deliver:

1. Prioritized findings with concrete source references and what you fixed.
2. A concise removal/consolidation list with evidence and compatibility considerations.
3. Before/after performance measurements, methodology and any unmeasured areas.
4. A summary of the unified design rules and screenshots of representative actual app screens when available.
5. Behavior/data-integrity checks, test/build results, and remaining risks or blockers.
6. Updated documentation reflecting only the resulting implementation.

Do not claim a clinical validation, performance gain, supported device capability, or completed visual check without evidence. Do not commit or push unless separately requested.
