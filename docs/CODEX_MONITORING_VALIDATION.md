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

At the time of the September 6 test report, the candidate had not yet replaced
the running app; it was subsequently opened and showed a real task. No real Hook trust was
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

## Post-candidate change (2026-09-11)

The candidate above polled the sessions root every 1 s (active) / 3 s (idle).
On the release branch this was replaced by an FSEvents subscription plus a
single expiry deadline (`CodexSessionLogWatcher`, `CodexSessionChangeSignal`,
`CodexSessionMonitorSchedule`; interface contract v6.93.0). The read budgets,
parser and reconciliation rules are unchanged. The 2026-09-06 candidate bundle
therefore no longer matches the source; live acceptance must use a rebuilt
candidate.

## Rebuilt candidate and runtime verification (2026-09-11)

The event-driven candidate was rebuilt, opened, and restarted on the Mac.
Its source remains uncommitted on `chore/release-0.4.0`, based on `6a490aa`.

- The initial focused run reproduced a missing-directory subscription failure.
  The fix binds existing directories by device/inode, permits explicit recovery
  after subscription failure, and signals a final scan after re-subscription.
- Filesystem wakes now force bounded discovery of older date directories, even
  within the ten-second discovery cache window. An uncached old session that
  resumes cannot be left waiting indefinitely for another filesystem event.
- Cancelled or timed-out approvals immediately release cached terminal state;
  history publication remains owned by the existing monitor task.
- **58 focused tests passed; 1029 full tests passed, with zero failures.** The
  authoritative wrapper also passed all five stability groups (20 version-probe,
  10 hermetic-listener, 20 tmux, 5 Hook-trust, and 20 sleep/wake rounds).
- Localization, legal/data-flow, performance-analysis, repository script syntax,
  and release-foundation checks passed. The complete security gate passed its
  source checks but still stops at the unchanged **0.3.0 Allow receipt**, which
  does not match VERSION **0.4.0**. The later Deny/accessibility receipt gates
  were not reached and must not be reported as passing.
- Universal production bundle: six Mach-O files with arm64+x86_64, dependency
  closure and strict deep ad-hoc signature passed. Eight isolated launch-smoke
  samples completed with readiness, normal AppKit termination and exit 0.
- Native UI verification showed two running Codex sessions, including the
  current DevLand task and the older joint task, plus one ended response.
  Monitoring off/on showed the correct stopped/monitoring states; restarting
  the exact candidate restored task visibility and the loopback listener.
  The monitoring preference was restored to on. No Hook authorization was made.

Candidate:
`/Volumes/T7 Shield/MacMini/CodexFiles/DevIsland-Optimization/qa/codex-event-monitoring-20260911/build/Dev Island.app`

Executable SHA-256:
`2260e3676cba429010ffb0152aabf1380a9932872f486993e237f83bcb9412e7`

Tests, gate logs, source manifest, build/smoke evidence and process measurements:
`/Volumes/T7 Shield/MacMini/CodexFiles/DevIsland-Optimization/qa/codex-event-monitoring-20260911/`

Old/new process samples are observations with real Codex activity, not controlled
idle comparisons. Idle energy acceptance, a newly created real task, actual
response-end/interruption transitions, and current-candidate explicit Hook
authorization / Allow / Deny / accessibility acceptance remain outstanding.
Automated fixtures and previously accepted 0.3.0 receipts do not replace them.


## Persistent-writer correction and replacement candidate (2026-09-11)

The directory-only candidate above was found to miss appends while Codex kept
its rollout writer open. Both directory FSEvents and FileEvents delivered zero
callbacks in the isolated persistent-writer diagnostic; a real ten-second
window changed four files by 26,604 bytes without either stream notifying.
The earlier 0.226% CPU observation must not be treated as an optimization result:
it included a monitor that could miss updates. The original evidence is retained.

The replacement (interface contract v6.94.0) keeps directory discovery and adds
at most 64 active event-only vnode subscriptions to exact discovered files.
No-follow opens and device/inode checks bind the subscriptions; one event-driven
window merges callbacks, with no periodic polling. Cancel handlers close their
own descriptors, and new subscriptions schedule a reread to cover the setup gap.

- The open-writer regression failed twice before the fix, then passed.
  **62 focused and 1033 full tests passed**, plus all five authoritative stability
  groups. Localization, legal/data-flow, performance-analysis, script syntax and
  release foundation passed. The legal gate's stale v6.93 pin was corrected.
- Full security again reached the unchanged 0.3.0 Allow receipt and rejected its
  VERSION mismatch. This is not a successful full security/receipt acceptance.
- The replacement universal production build and signature/dependency checks
  passed. Its isolated eight-sample launch smoke exited normally with status 0.
- Native UI showed two running Codex tasks. Two read-only checkpoints found the
  current task's source timestamp advancing as the same rollout inode grew and
  retained an open writer; the App was not restarted or toggled between them.
- Turning monitoring off released all 64 rollout descriptors; turning it on
  restored 64. Normal quit removed the process/listener, and relaunch restored
  the two running sessions and listener. The preference remains enabled.

Replacement App:
`/Volumes/T7 Shield/MacMini/CodexFiles/DevIsland-Optimization/qa/codex-event-monitoring-20260911/build-open-writer-fix/Dev Island.app`

Executable SHA-256:
`52f648568553f4f889e54a9ee8545abfac2f778f3994fd6b22cdb7694fd5bea7`

See `VALIDATION_OPEN_WRITER_FIX.md` in the evidence directory for the final quiet
sample, parser compatibility checks and remaining real acceptance boundaries.


The acceptance packagers now also recognize exactly `source=vscode` with CLI
`0.153.4`, retaining Codex Desktop originator, user-task and UUID checks. All
legacy source classifications and decision-evidence constraints remain intact.
A portable synthetic regression runs before the existing receipt gates:
**70 parser checks passed**. This is format compatibility evidence only; no real
approval was requested, no transcript was rewritten and no receipt was accepted.


The post-fix quiet-input attempt was **invalid**: despite 45 seconds of controller
silence, no observed build processes and an unlocked screen, three rollout files
grew by 366,465 bytes during the 30-second sample. FSEvents remained at zero;
metadata checks correctly rejected the window. Average CPU was 0.543% under that
activity, not an idle-energy result. A controlled quiet window and matched old/new
comparison remain outstanding. Full security passed the new 70 parser checks and
then stopped at the unchanged old Allow receipt as expected.

## Committed candidate, idle comparison and on-machine authorization (2026-09-12)

- `chore/release-0.4.0` @ `15d7469` (pushed; CI resolve/security source checks pass and stop
  only at the 0.3.0 receipt vs VERSION mismatch). Universal production build:
  `CodexFiles/DevIsland-Optimization/qa/release-0.4.0-candidate-20260912/build/Dev Island.app`,
  main executable SHA-256 `654528afe56cdbdeece28ab78a622ef17d8876f5ed95d48fc39047d60331508a`.
- Idle comparison in one quiet window (each app alone, 10 s warm-up, 45 s sample, no Codex
  session changed): old polling `6a490aa` 1.279 % CPU / 0.864 package-idle wakeups per second /
  73,728 bytes written; new event-driven `15d7469` 0.631 % CPU / 0.089 per second / 0 bytes.
  Protocol and raw summaries live in `idle-comparison/` next to the build.
- Dev Island's five Codex Hook entries were authorized on this Mac through the same
  `review()` → `authorize(_:)` path the Settings sheet uses; the post-write review reports
  `alreadyAuthorized = true` and `IslandCoreCLI local-hook-status` reports `codex=connected`.
  Other trust records were left untouched. Records: `evidence/live-0.4.0/hook-authorization-*-20260912.txt`.
- Still open: real Allow / Deny / accessibility receipts for this build, and Sparkle keys.

