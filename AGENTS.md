# Package conveyor

One packaging conveyor every project calls, not copies (README.md). Its decisions, backlog and record are in `data/`.

**Owner**: `conveyor-builder` - the builder session of the package conveyor: its workflows, their test (`tests/alpine/run.sh`), their tags and their record.

A change to a workflow that a project calls (`@v1`) keeps every existing caller working unchanged; `v1` moves only to a compatible release, after landing (decision 2026-11-11-a-tag-only-after-landing). `tests/alpine/run.sh` needs docker, yq, jq, curl and openssl.
