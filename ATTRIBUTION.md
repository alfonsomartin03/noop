# Project history and attribution

## Project history

This is a standalone repository maintained by Alfonso Martin. It began as a fork
of [`muftiarfan/noop`](https://github.com/muftiarfan/noop), and is now separate
from GitHub's fork network. Its inherited Git history remains intact, including
earlier project commits recorded under the [`NoopApp`](https://github.com/NoopApp)
author identity. Subsequent commits remain attributed to their authors in Git
history. The project name and inherited code history are retained with credit to
the original project authors and the direct parent repository.

## Protocol research and software

NOOP builds on open-source reverse-engineering and interoperability work:

- [`johnmiddleton12/my-whoop`](https://github.com/johnmiddleton12/my-whoop) —
  WHOOP 4.0 BLE protocol research and Swift code adapted in the `WhoopProtocol`
  and `WhoopStore` packages and collection layer.
- [`b-nnett/goose`](https://github.com/b-nnett/goose) — WHOOP 5.0 / MG protocol
  research, including the `fd4b0001-…` service family, CRC16-Modbus header, and
  "puffin" packet types used by the WHOOP 5.0 path.
- [`groue/GRDB.swift`](https://github.com/groue/GRDB.swift) — SQLite persistence
  through Swift Package Manager.
- [`weichsel/ZIPFoundation`](https://github.com/weichsel/ZIPFoundation) — ZIP
  archive support through Swift Package Manager.

The source parent did not include a project-wide license file, and this repository
does not add or claim one. Third-party components retain their own copyright and
license terms; see their repositories and package metadata for details.

## Product and data notice

NOOP is an independent, unofficial project and is not affiliated with, endorsed
by, or connected to WHOOP, Inc. "WHOOP" identifies the hardware with which the
software interoperates. NOOP is not a medical device; derived health metrics are
approximations and are not clinically validated.
