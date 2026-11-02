# NOOP documentation

Current guides describe the macOS app and its retained packages. Research and experiment reports record evidence at a point in time; they are not feature promises.

## Current guides

- [Project overview](../README.md)
- [Contributing](CONTRIBUTING.md) and [build/test](BUILD.md)
- [Features](FEATURES.md) and [screen map](SCREEN_INVENTORY.md)
- [Architecture](ARCHITECTURE.md), [packages](LIBRARY.md), and [data model](DATA_MODEL.md)
- [Analytics](ANALYTICS.md) and [privacy/data handling](PRIVACY_SECURITY.md)

## Measurement and implementation evidence

- [Measurement validity specification/report](MEASUREMENT_VALIDITY.md)
- [Workout/strain implementation report](WORKOUT_STRAIN_REPORT.md)
- [Sleep sessions and corrections](SLEEP_SESSIONS.md) — local work in progress at this refresh
- [Sleep/recovery research, October 27](SLEEP_RECOVERY_RESEARCH_2026-10-27.md)
- [Workout/strain research, October 30](WORKOUT_STRAIN_RESEARCH_2026-10-30.md)
- [Historical sleep/strain audit](SLEEP_STRAIN_AUDIT.md)
- [WHOOP export scoring analysis](WHOOP_REVERSE_ENGINEERING.md)

## Bluetooth evidence

Start with the [reverse-engineering index](reverse-engineering/README.md), [command registry](reverse-engineering/COMMAND_REGISTRY.md), and [safety matrix](reverse-engineering/SAFETY_MATRIX.md). Captures, fixtures, unknown capabilities and experiment logs are retained because they support protocol decisions.

Additional background: [protocol](PROTOCOL.md), [BLE reverse engineering](BLE_REVERSE_ENGINEERING.md), and [HR broadcast research](HR_BROADCAST_RESEARCH.md). Check newer capture evidence against older descriptions before changing a command. [Alarm capabilities](reverse-engineering/ALARM_CAPABILITIES.md) accompanies the current local alarm work.

## Scope of this refresh

On November 2, 2026, remote `main` was verified at `6e5ecda`; the local committed app was at `d14c607`. The two intervening remote commits only removed unrelated cinema-project artifacts. Existing uncommitted sleep/session, alarm, storage and protocol work was preserved, and is not advertised as released. Obsolete mobile-port and rejected API-integration plans were removed from current documentation.
