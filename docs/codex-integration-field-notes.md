# Codex integration field notes

Implementation review: 2026-09-06. This describes the current development
worktree; current-candidate real Allow/Deny acceptance remains outstanding.
Historical receipts and automated fixtures do not close that gate.

## Decision summary

Codex has two independent local channels. Passive JSONL monitoring discovers
work without requiring Hook trust. Synchronous Hooks carry real approval
requests and decisions. A running card does not prove that approval Hooks are
authorized or that a command has been approved.

| Surface | Scope | Dev Island decision |
| --- | --- | --- |
| Local session JSONL | Existing desktop/CLI rollout records | Enabled by default, read-only, bounded, independently switchable; discover work and response outcomes without waiting for Hooks |
| Local Hooks | Lifecycle events and synchronous PermissionRequest | Real decisions use the loopback exchange; logs never manufacture approval requests or Allow/Deny actions |
| App Server Hook/config methods | hooks/list, config/read, config/batchWrite in a verified local child | Check trust read-only; after the user reviews exact commands and clicks authorization, write only those trust entries and verify again |
| Full App Server thread control | Threads and live turns owned by a particular server instance | Future work; a separate server does not automatically subscribe to the desktop application's existing live runtime |
| Codex SDK | Clients that drive Codex through a local runtime | Not a Codex Cloud task-list API |
| Codex Cloud / Responses background jobs | Separate hosted product and API surfaces | No current connector for existing Codex Cloud tasks; do not relabel generic Responses jobs as Codex sessions |

## Passive task monitoring

CodexSessionLogMonitor reads $CODEX_HOME/sessions when CODEX_HOME is an
absolute path, otherwise ~/.codex/sessions. It does not edit Codex files,
enable Hooks, change sandbox/approval settings, or create a Codex task. The
monitoring switch controls this channel independently of Hooks and pending
decisions.

The scanner refreshes recent date directories and performs bounded discovery
of the wider date tree: a conversation resumed today may still use a rollout
in its original creation-date directory. Entry/file/byte budgets are finite.
Large files use a bounded metadata header and recent suffix instead of loading
a complete transcript. Directory-relative, no-follow descriptors reject
symlink substitutions. Partial JSONL records wait for their newline; oversized
or malformed records are discarded. A deliberate gap resets turn ordering
while preserving validated metadata, so a later turn whose start fell in the
skipped span can still be observed.

CodexSessionLogParser recognizes metadata, task starts, human user messages,
current item lifecycle records, response completion and interruption.
Metadata alone does not create a running card. Subagent/helper origins,
including memory and chronicle work, are excluded. A failed individual tool is
recoverable activity, not proof that the response failed. A completed response
is labeled **Response finished**; interruption remains **Interrupted** instead
of turning green. Known old-turn terminal records cannot overwrite a newer
turn. Unknown records do not become user actions.

Freshness uses actual recorded event time, never read time or mtime. Running
observations expire after thirty minutes without a recognized event; terminal
observations expire after two hours. Far-future records are rejected before
parser state changes, so they cannot block subsequent valid events. Initial
discovery does not replay historical status changes as fresh notifications.

The task projection contains validated IDs, an absolute project directory when
valid, state/phase/timestamps, and a bounded title. The title may be the first
human message line after metadata filtering, limited to 120 characters and
512 UTF-8 bytes, with the project name as fallback. That title and ordinary
task fields can enter existing local task history. Raw prompts, complete
transcripts, reasoning and tool-output payloads are not stored as task history
or sent to a Dev Island service. Framing temporarily holds bounded record bytes
in memory while parsing.

CodexSessionReconciler merges this projection with the live Hook snapshot.
Hook jump context is retained, actual pending decisions remain authoritative,
and approving/denying cannot be undone by an older connector snapshot.
Cancellation and generation checks fence late monitor results across
disable/re-enable and shutdown.

## Real approval Hooks and in-island authorization

Dev Island writes only its managed groups in ~/.codex/hooks.json, preserving
other keys and Hooks. Lifecycle events use short loopback posts.
PermissionRequest uses the existing bounded synchronous exchange to return
Codex's allow/deny response. Timeout, exit or listener failure returns a
neutral result and lets Codex use its native path. A command string, log status
or task title never establishes an approval request.

Codex trust belongs to the exact definition hash. Installing a command does
not prove authorization, and a changed command requires review again. The
supported flow is:

1. Install/update Dev Island's managed definitions as needed.
2. In Dev Island, open Codex authorization review and inspect every event and
   its exact command.
3. Click the explicit authorization control in that review.
4. Re-read trust and show success only for the same enabled definitions.

The writer is version-gated to locally verified **codex-cli 0.153.4**. It uses
the OpenAI-signed application's bundled executable and official App Server
config/batchWrite operation. Review obtains hooks/list metadata and the user
configuration layer's version from config/read. Before writing, it rechecks
commands, hashes and version, rejects expired or changed reviews, and upserts
only those opaque keys under hooks.state with expectedVersion and
reloadUserConfig. A fresh hooks/list must report those same commands/hashes as
trusted; a write acknowledgement alone is not activation evidence.
In-app authorization currently supports the default Codex home only. If
CODEX_HOME points monitoring at another directory, authorization refuses to
write the default home's trust records; custom-home setup remains manual.

This requires the user's explicit review action. It does not silently grant
trust, overwrite unrelated entries, alter approval_policy or sandbox mode, or
take control of an existing Codex task. Unsupported versions retain passive
monitoring and use manual authorization in the **Codex CLI**: open its
**/hooks** interface, review only Dev Island's current entries, then check again
in Dev Island. Typing /hooks into an ordinary desktop chat is not a supported
authorization step. Do not invent a desktop Settings location that has not
been verified in the installed version.

The read-only check still distinguishes installed configuration from proven
authorization. Missing, disabled, changed, untrusted, mismatched, unavailable
or unexpected schema results cannot report Hook authorization as connected.
Passive monitoring and authorization are shown separately so an untrusted
Hook does not make observable work disappear.

## Bounded local App Server process

The boundary accepts only the bundled codex executable from an installed
com.openai.codex application signed by OpenAI team 2DC432GLL2. It does not
search PATH or run package-manager shims. A minimal environment, narrow stdio
requests, finite request/response limits, nonblocking descriptors and a
monotonic deadline bound the exchange. Response, timeout, overflow, I/O failure
and early exit use bounded process-group cleanup. stderr is discarded; raw
exchange bytes are not logged or retained as diagnostic output.

The trust probe is read-only. The separate authorization service is the new
writer and runs only after the reviewed user action. Neither path creates a
task, subscribes to another server's runtime, or contacts a Dev Island backend.

## What the Vibe Island references establish

Public [v0.7.0 release notes](https://github.com/edwluo/vibe-island-updates/releases/tag/v0.7.0)
describe Codex JSONL session monitoring alongside automatic Hook setup, and
[v1.0.33](https://github.com/edwluo/vibe-island-updates/releases/tag/v1.0.33)
describes one-click authorization. These establish advertised behavior, not
access to product source or proof of its internal authorization mechanism.
Dev Island is independently implemented from the observed local Codex schema
and verified vendor protocol. We do not claim that Vibe Island is exempt from
trust or that its private implementation was copied.

## Remaining acceptance

- Verify new and older resumed desktop tasks appear while Hooks are untrusted,
  with correct response-finished/interrupted behavior.
- Review exact commands in the island, authorize on the supported version and
  prove Codex accepts those same definitions after the write.
- On the current packaged candidate, trigger a real approval and click
  **Allow** once; prove the requested command continues and bind the
  receipt/screenshots to that candidate.
- Repeat with **Deny**, proving Codex refuses that request; exercise native
  fallback for timeout or listener failure.
- Verify monitoring opt-out, restart, cancellation and unsupported-version CLI
  fallback without changing the user's approval/sandbox preferences.

These real integration checks remain outstanding. Green unit tests, old-version
receipts or a waiting-card screenshot do not establish the current candidate's
complete approval round trip.

## Sources

- [Codex Hooks](https://learn.chatgpt.com/docs/hooks)
- [Review and trust Hooks](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks)
- [Hook configuration locations](https://learn.chatgpt.com/docs/config-file/config-advanced#hooks)
- [Codex App Server](https://learn.chatgpt.com/docs/app-server)
- [Codex SDK](https://learn.chatgpt.com/docs/codex-sdk)
- [Codex Cloud](https://learn.chatgpt.com/docs/cloud#getting-started)
- [OpenAI Webhooks](https://developers.openai.com/api/docs/guides/webhooks)
