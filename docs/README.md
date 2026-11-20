# NOOP documentation

Current guides describe the macOS app as it is in `main`. Source and tests win over any document. Research reports are dated evidence; archived files are history only.

## Current guides

- [Project overview](../README.md) and [project progress](PROJECT_PROGRESS.md) (plain-language status)
- [Architecture](ARCHITECTURE.md) — data flow, packages, screens, storage, analytics rules
- [Build and test](BUILD.md), [contributing](CONTRIBUTING.md), [privacy and data handling](PRIVACY_SECURITY.md)

## Measurement methods and evidence

- [Measurement validity](MEASUREMENT_VALIDITY.md) — metric identity, causal baselines, quality gates
- [Sleep sessions and corrections](SLEEP_SESSIONS.md) and [nap detection](NAP_DETECTION.md)
- [Health models](HEALTH_MODELS.md) — functional age, VO₂max, health monitor, activation timeline

## Bluetooth protocol

Start with the [reverse-engineering index](reverse-engineering/README.md), then the [evidence matrix](reverse-engineering/EVIDENCE_MATRIX.md), [command registry](reverse-engineering/COMMAND_REGISTRY.md) and [safety matrix](reverse-engineering/SAFETY_MATRIX.md). [PROTOCOL.md](PROTOCOL.md) is the wire-format reference for 4.0 and 5.0.

## Archive

[archive/](archive/) keeps superseded reports (earlier sleep/strain audits and research, the WHOOP export scoring analysis, HR-broadcast research, the BLE narrative, the phase-1 BLE audit). They are not maintained; several describe behavior that has since changed.
