# Running-app evidence — CodexBar #4726 / PR #4733 (all refresh states)

Genuine screenshots and runtime evidence from the **freshly built CodexBar app** running in a real
Aqua session on a GitHub-hosted `macos-26` runner, showing the real status-item menu card for a user
provider plugin across the refresh states requested for issue #4726. Not offscreen rendering: the
app was built from the PR tree, launched, the production status-item menu was opened through the
production `StatusItemController.openMenuFromShortcut()` path, and the live menu window was captured
with `screencapture -l <windowNumber>`.

All four states were produced through the **production refresh path**
(`UsageStore.refreshUserPlugin` + `ProviderPluginApprovalStore`) against a local loopback fixture
server that returns usage for the successful refresh and HTTP 500 for the failing refresh. The
retained-usage state waits ~70 s between the successful and failing refresh so the card shows a
non-zero capture age.

## Hosting disclosure

GitHub Actions has been **disabled by GitHub automation for the contributor fork
`LeoLin990405/CodexBar`** ("HTTP 422: Actions has been disabled for this repository"; the
`PUT /actions/permissions` re-enable API has no effect). The proof therefore ran on a **scratch
public repository owned by the same GitHub account**, `LeoLin990405/codexbar-proof-runner`, using
the **exact same workflow, harness and PR-head tree**. Only the CI hosting repository differs from
the fork; the runner is still GitHub-hosted `macos-26`.

## Provenance and commit linkage

- **Workflow run (green):** https://github.com/LeoLin990405/codexbar-proof-runner/actions/runs/39911014019
- **Proof branch:** `proof/4733-app-proof` in `LeoLin990405/codexbar-proof-runner`, head `2656f6fac`.
  - `2656f6fac` (state-coverage harness revision) -> `a6df2a4ef` (parent is the **current PR head
    `4fa967943`**) -> `4fa967943` (`fix/plugin-card-stale-error`).
- **Production tree under test is identical to PR head `4fa967943`:** `git diff
  4fa967943..2656f6fac` adds only fork-only files (this workflow, the DEBUG-only screenshot harness,
  DEBUG-gated wiring in `CodexbarApp.swift`, and an env-gated `Scripts/package_app.sh` option); no
  production path, resource, test, docs or CHANGELOG change is added by the proof commits.
- The follow-up commit `4fa967943` over the originally requested `532eb8664` is the
  height-fingerprint/localization change only; the card layout and rendered content are identical,
  so screenshots taken on this head match the reviewed behavior exactly.
- **App:** debug build (harness is `#if DEBUG`), ad-hoc signed, version `0.80.1`, build `174`,
  bundle id `com.steipete.codexbar.debug`, embedded git commit `2656f6fac`.
- **Runner:** macOS 26.x, Xcode 26.6, Swift 6.3.3, 1024x768 Aqua session.

## States and what the card shows

| File | State | Card content |
| --- | --- | --- |
| `01-success.png` | Successful refresh (`{"used":42}` from loopback) | `Primary 58% left` usage row, no error row, no last-known line (`card.usageState=current`). |
| `02-success-failure.png` | Success, then later refresh fails (HTTP 500) | Retained `Primary 58% left` row **plus** red `Usage request failed (HTTP 500): fixture endpoint stopped responding.` **plus** `Showing last-known usage captured 1 minute ago.` (`card.usageState=lastKnown`, `isStale=true`). |
| `03-failure-only.png` | Initial refresh fails with no cached snapshot | Red error only; no usage rows, no last-known line (`card.usageState=none`, `showsUsageRows=false`). |
| `04-recovery.png` | Success -> failure -> success | Back to `Primary 58% left`, no error row, no last-known line (`card.usageState=current`). The window capture is intentionally identical to the success state; the recovery sequence is recorded in `evidence/marker-state-recovery.json` steps and the desktop screenshot timestamp differs. |

Every marker JSON records the production card presentation via
`UserPluginMenuCardContent.make(snapshot:error:isRefreshing:)`: `card.usageState`, `card.isStale`,
`card.showsUsageRows`, `card.errorText`, `card.lastKnownText`, `card.placeholderText` and
`card.fingerprint`, plus the per-step refresh history (`steps`), final snapshot/error, app commit
and the `CGWindowList` status-item/window data.

## What is harness-driven (disclosure)

- The user plugin `fixture-stale-proof.js` is a local mock installed in the real plugin directory
  (`~/.config/codexbar/providers/`) and discovered by the production loader. It requests the
  declared loopback `BASE_URL` and reports `usedPercent: 42`.
- The harness enables/selects the plugin and records the production typed approval binding for the
  loopback origin (`ProviderPluginApprovalStore.record`), then calls the production
  `UsageStore.refreshUserPlugin` for each refresh step. The loopback fixture server is started by
  the workflow; `/tmp/codexbar-proof/server_mode` selects success or HTTP-500 responses.
- The harness opens the real status-item menu with production `openMenuFromShortcut()`; the card is
  rendered by the production `UserPluginMenuCardView`.
- No store state is seeded for these captures: snapshots and errors are published by the production
  refresh path. Only the fixture plugin and the local HTTP server are test scaffolding.

No personal information, credentials, cookies or non-public endpoints are involved: the runner
starts with no provider configuration, the plugin is a local mock and the server is loopback-only.

## Files

| Path | Contents |
| --- | --- |
| `0[1-4]-*.png` | WindowServer captures of the real menu window per state (`screencapture -l`), incl. shadow. |
| `zooms/*.png` | 2x crops of the same captures for legibility. |
| `screens/*.png` | Full 1024x768 desktop captures (menu attached to the real menu bar). |
| `raw/` | Unmodified raw captures (menu window + full screen, rounds 1-2), `CGWindowList` dumps, window ids. |
| `evidence/marker-state-*.json` | Handshake JSON per state with steps, snapshot/error state and production card content. |
| `evidence/runtime-evidence-*.txt`, `evidence/app-*.log` | Runtime output printed by the built app per state. |
| `evidence/fixture-stale-proof.js`, `evidence/fixture_server.py`, `evidence/fixture-server.log` | Test scaffolding actually used by the run. |
| `evidence/build-package.log` | Full build/package log (`swift build` + app packaging + ad-hoc codesign). |
| `evidence/capture-trace.txt` | Workflow capture trace with per-state runtime evidence and `PROOF CAPTURE OK`. |
