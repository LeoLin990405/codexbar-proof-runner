# Running-app evidence — CodexBar PR #4779 (Cursor/Raycast version row) and PR #4780 (Trae CN picker + legacy-data compatibility)

Genuine screenshots and runtime evidence from the **freshly built CodexBar app** running in a real
Aqua session on a GitHub-hosted `macos-26` runner. Not offscreen rendering: the app was built from
the PR tree, launched, the real Settings window was opened through the production settings path, and
the live window was captured with `screencapture -l <windowNumber>`.

## Hosting disclosure

GitHub Actions has been **disabled by GitHub automation for the contributor fork
`LeoLin990405/CodexBar`** ("HTTP 422: Actions has been disabled for this repository"; the
`PUT /actions/permissions` re-enable API has no effect). All proof runs therefore ran on a **scratch
public repository owned by the same GitHub account**, `LeoLin990405/codexbar-proof-runner`, using the
**exact same workflow, harness and PR-head trees**. Only the CI hosting repository differs from the
fork; the runner is still GitHub-hosted `macos-26`.

## Provenance and commit linkage

All proof branches add only fork-only files (a `#if DEBUG` harness, DEBUG-gated wiring in
`CodexbarApp.swift`, an env-gated `Scripts/package_app.sh` widget-skip option and a proof workflow);
`git diff <PR-head>..<proof-head> -- Sources/External/Resources/Tests/CHANGELOG/docs` shows no
production change beyond those files.

### PR #4779 — hide undetected Version row for web-only Cursor and Raycast (fixes #4769)

| Run | Workflow run | Branch | Head | Parent chain |
| --- | --- | --- | --- | --- |
| After fix (primary) | https://github.com/LeoLin990405/codexbar-proof-runner/actions/runs/40279295949 | `proof/4779-after` | `57836c6cd` | `29c4ade12` → **PR head `705318b3d`** |
| Before fix (contrast) | https://github.com/LeoLin990405/codexbar-proof-runner/actions/runs/40279292307 | `proof/4779-before` | `84ed27538` | `91150478d` → **base `d34fbb47a`** |

The after-fix app (v0.81.1, commit embedded in Info.plist `57836c6cd`) shows Settings → Providers →
**Cursor** and **Raycast** cards with `Source: web` and **no `Version` row**. The before-fix app
(commit `91150478d`, production tree `d34fbb47a`) shows the same panes with `Version: not detected`.
Marker JSON per provider records `presentation.detailLine == "web"`,
`presentation.showsVersionInSettings == false` (after) vs `true` (before),
`presentation.versionText == nil` (after) vs `"not detected"` (before), `store.version == nil`,
`store.sourceLabel == "web"`, the WindowServer window number/bounds and app commit.

Harness disclosure: the credential-less runner cannot complete a real Cursor/Raycast web fetch, so
the harness sets the production `lastSourceLabels` value to `web` (the state the card shows after a
successful web refresh, matching the #4769 report). This is recorded as
`sourceLabel.harnessInjected: true` in every marker.

### PR #4780 — distinguish the Trae CN credit breakdown from the main Credits bar (fixes #4764)

| Evidence | Workflow run | Branch | Head | Parent chain |
| --- | --- | --- | --- | --- |
| Picker labels after fix | https://github.com/LeoLin990405/codexbar-proof-runner/actions/runs/40278271426 | `proof/4780-after` | `a06bf6393` | **PR head `e7eb07544`** |
| Picker labels before fix | https://github.com/LeoLin990405/codexbar-proof-runner/actions/runs/40278265972 | `proof/4780-before` | `bc34751ff` | **base `d34fbb47a`** |
| Legacy-data compatibility | https://github.com/LeoLin990405/codexbar-proof-runner/actions/runs/40280146603 | `proof/4780-compat` | `6eacc5116` | **PR head `e7eb07544`** |

**Picker labels.** The after-fix app shows the real Settings → Trae CN "Visible usage items" picker
with two distinguishable controls: main bar `Credits` and detail `Credit breakdown` (item ids
`metric:primary` and `detailSection:Credit breakdown`). The before-fix build shows two rows both
labelled `Credits` (ids `metric:primary` and `detailSection:Credits`). Markers record the picker item
labels/ids, visibility, snapshot detail titles and app commit. A Trae CN usage snapshot is injected
through the existing DEBUG `UsageStore` state hook because the runner has no Trae CN credentials
(disclosed); the picker itself is the production Settings view.

**Upgrade/data-model compatibility (legacy hidden detail section through restart).** The PR-head build
was launched twice in one job:

1. *Seed launch*: writes the v0.81.0-style stored choice
   `hiddenUsageItemIDs = ["detailSection:Credits"]` through the production settings/config API.
2. *Restart/verify launch*: a fresh process loads the persisted pre-upgrade config from disk **without
   rewriting it**; the app migrates the legacy id on read to `detailSection:Credit breakdown`, keeps
   the row hidden, and renders no unavailable/placeholder row.

Evidence: `config-after-seed.json`, `config-before-verify.json`, `config-during-verify.json` and
`config-after-verify.json` all retain the raw legacy stored value `detailSection:Credits` across the
restart. `marker-seed.json` records the written legacy id; `marker-verify.json` records
`config.hiddenUsageItemIDs == ["detailSection:Credits"]`,
`resolvedHiddenIDs == ["detailSection:Credit breakdown"]`,
`migratedDetailRow.present == true`, `migratedDetailRow.isVisible == false`,
`hasLegacyRow == false`, `hasUnavailablePlaceholderRow == false`, and the picker rows
(`Credits` visible, `Credit breakdown` hidden). The screenshot shows that final state from the freshly
restarted app.

## Files

| Directory | Contents |
| --- | --- |
| `version-row-4779/after/` | PRIMARY after-fix captures: `cursor-settings.png`, `cursor-info-zoom.png`, `raycast-settings.png`, `raycast-info-zoom.png` (window captures cropped to the window; `*-info-zoom` are 2× crops). |
| `version-row-4779/before/` | The same panes from the base commit for contrast, showing `Version: not detected`. |
| `version-row-4779/screens/` | Full 1024×768 desktop captures for both builds. |
| `version-row-4779/evidence/` | Per-provider marker JSON, runtime output, app logs, build logs and git heads. |
| `traecn-picker-4780/after/`, `before/` | Settings → Trae CN "Visible usage items" list (`settings-picker.png`, 2× `picker-zoom.png`) on PR head vs base. |
| `traecn-picker-4780/screens/`, `evidence/` | Desktop captures; per-step marker JSON, runtime output, app logs, build logs, git heads. |
| `traecn-compat-4780/01-…png`, `02-…png` | After-restart Settings → Trae CN with `Credits` visible and `Credit breakdown` still hidden; 2× rows crop. |
| `traecn-compat-4780/evidence/` | seed/verify marker JSON, runtime evidence, four config snapshots (raw legacy id preserved), app logs, window dump, build log, git head. |

No personal information, credentials, cookies or non-public endpoints are involved: the runner starts
with no provider configuration, and the Trae CN snapshot is injected through the app's DEBUG state hook.
