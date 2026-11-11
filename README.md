# Package conveyor

**One packaging conveyor every project calls, not copies.** A project keeps one short declaration and
calls the conveyor at a pinned version; the conveyor builds, verifies, signs and publishes - Arch
(pacman) and Alpine (apk, for postmarketOS) repositories first.

Status: **designed**, from the delivery machinery of snapall and lab-agent. Its idea, decisions
(with what was rejected) and path are in [`data/`](data), shown in the
[Open Commons Observatory](https://open-commons-observatory.github.io/).
