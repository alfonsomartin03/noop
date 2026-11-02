# Privacy and data handling

NOOP processes strap data and imported files locally. The app has no account, cloud sync, telemetry, or WHOOP API integration. Package downloads during development are separate from runtime data processing.

## Data paths

- Bluetooth is **bidirectional**: observations arrive from the strap; the app sends connection, stream, clock and history-control commands. Hardware commands can change device state. See the [command registry](reverse-engineering/COMMAND_REGISTRY.md) and [safety matrix](reverse-engineering/SAFETY_MATRIX.md).
- Settings → Data imports user-selected WHOOP ZIP/folder exports and exports/restores database backups. User-directed exports can leave the app's container; NOOP does not upload them.
- Apple Health parsers remain in the library, but are not exposed by the current app's import UI.

## Local storage

`Strand/Collect/StorePaths.swift` resolves `OpenWhoop/whoop.sqlite` beneath Application Support. Sandboxed builds resolve that location inside the app container. SQLite may use WAL/SHM sidecars. Preferences/profile settings also use UserDefaults, and raw historical archives have their own collection code; the database is not the only local artifact.

The database is not application-encrypted. Backups, captures, and exports may contain sensitive biometric data and identifiers. Keep them out of commits and shared diagnostic reports unless sanitized. Database restore replaces the local database and requires relaunch; it is not a merge or a complete backup of all app preferences.

## App configuration

The checked-in entitlements enable the App Sandbox, Bluetooth, and user-selected file read/write access. They do not grant network client/server access. `project.yml` currently disables Hardened Runtime; the development configuration is not evidence of release notarization or a completed security audit.

## Contributor requirements

Validate packet checksums, lengths, and field bounds before using decoded values. Preserve archive/XML/CSV size checks and error handling. Keep history acknowledgements consistent with persisted data and the user's strap-retention setting. Do not treat a successful hardware response as proof of a command's safety.

See [CONTRIBUTING.md](CONTRIBUTING.md) for review expectations. NOOP is independent of WHOOP and not a medical device; see [DISCLAIMER.md](../DISCLAIMER.md).
