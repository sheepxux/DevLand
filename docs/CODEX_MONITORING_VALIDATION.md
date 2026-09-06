# Codex monitoring candidate validation

2026-09-06 · branch `codex/codex-session-monitoring` · product candidate 0.4.0

The candidate separates default read-only session monitoring from actual Hook
approval requests. Explicit in-app authorization reviews the exact installed
commands, uses official vendor keys/hashes and configuration revision checks,
and verifies the saved trust. It currently supports signed Codex CLI 0.153.4
with the default Codex home; other setups retain manual authorization.

## Verified

- Final full Swift suite: **1002 tests, 0 failures**. The final added regression
  proves a cancelled approval releases an already-observed terminal state on
  the next poll, even if the log bytes have not changed.
- Authoritative stability checks: 20 version-probe rounds / 240 processes,
  10 hermetic-listener rounds, 20 tmux cleanup rounds, 5 Codex trust-process
  rounds, and 20 sleep/wake rounds passed. These preceded the final cached-state
  regression and custom-home refusal; those changes then passed the full suite.
- Three opt-in visual snapshot tests passed. English Settings and Chinese
  Welcome snapshots were inspected for the initial layout. These are offscreen
  renderings, not evidence of a real authorization click.
- Localization, legal/data-flow, repository script syntax, source security
  assertions, runtime log privacy, GitHub-control fixtures, release foundation,
  performance-analysis and signal-sound gates passed.
- Universal production bundle built and ad-hoc signature validation passed.
  Both arm64 and x86_64 slices are present; bundle dependency checks passed.
- Production-hermetic launch smoke: isolated app/home, eight samples, clean
  exit 0, normal termination. This proves startup/cleanup only; it is not a
  live monitoring or performance acceptance claim.
- Read-only inspection of the installed signed CLI confirmed the current five
  Hook definitions and config-layer/key/hash schema match this implementation.

## Remaining live acceptance

The complete security command stops at the checked-in Codex Allow receipt:
its product version differs from VERSION. Separately running the remaining
gates also found that the Deny and system-accessibility receipts carry older
versions. None of these receipts or their accepted markers was rewritten.

The candidate has not replaced the user's running app. No real Hook trust was
changed. A fresh helper verifying saved trust does not prove the existing
Codex desktop task has reloaded it. Current-candidate passive monitoring,
explicit user authorization, Allow/Deny continuation and accessibility still
need real interaction evidence before release acceptance.

## Local artifacts

- Candidate: `/Volumes/T7 Shield/MacMini/Projects/Dev-Island-Codex-Monitoring/build/Dev Island.app`
- Logs, snapshots and candidate executable hash:
  `/Volumes/T7 Shield/MacMini/CodexFiles/DevIsland-Optimization/qa/codex-monitoring-20260906/`
- Design and public research references: [Codex field notes](codex-integration-field-notes.md)

Package.resolved was repaired because the baseline omitted Hummingbird's
transitive swift-configuration dependency on this toolchain. Existing dependency
versions were retained; the resolver also removed two unused SQLite pins.
