# Running proof — CodexBar PR #4800 (`usage_updated` raw-plan provenance) shipped CLI + data-model compatibility

Evidence for the two blocker items on PR #4800 (fixes CodexBar #4775): a **real hook delivery from the
shipped CLI** with the plan fields in both JSON stdin and environment, plus an **upgrade/data-model
compatibility** check against a payload written by the released v0.81.0 build.

- Workflow run (green): https://github.com/LeoLin990405/codexbar-proof-runner/actions/runs/40463376774
- PR head: `a67d8017f` (`feat/4775-hook-plan-observations`, unchanged; no PR branch was touched)
- Proof branch: `proof/4800-plan-hooks` head `84587cf83` (parent `a67d8017f`)

## Hosting disclosure

GitHub Actions is disabled by GitHub automation for the contributor fork `LeoLin990405/CodexBar`
(`HTTP 422: Actions has been disabled for this repository`), so the run executed on the scratch public
repository `LeoLin990405/codexbar-proof-runner` (same GitHub account) with the **same PR-head tree**.
Only the CI hosting repo differs; the runner is GitHub-hosted `macos-26` (arm64).

## Provenance / what was added

The proof branch adds only fork-only files on top of the PR head: `Proof/ProofPlanCompat/` (a
package-internal compatibility harness target), `Proof/fake-codex` (fake app-server used by the
workflow), `.github/workflows/proof-4800-plan-hooks.yml`, the fork-only `ProofPlanCompat` product/target
entries in `Package.swift`, and an env-gated widget-extension skip in `Scripts/package_app.sh`.
`git diff a67d8017f..84587cf83 -- Sources Tests docs CHANGELOG.md` is empty: production code is identical
to the PR head. Proof commits: `84587cf83 → a67d8017f`.

## 1) Shipped-CLI `usage_updated` hook delivery — REAL, not simulated

Built binary: **CodexBarCLI 0.82.1** (`terminal/cli-version.txt`) from the PR head, packaged as the app's
helper. The workflow then ran the shipped command:

```
HOME=<temp> CODEXBAR_CONFIG=<proof config> CODEX_CLI_PATH=<fake app-server> \
  CodexBarCLI hooks watch --provider codex --interval 60 --verbose
```

The config is a normal `~/.config/codexbar/config.json`-shaped file: Codex enabled with `source: "cli"`,
hooks enabled, one `usage_updated` rule running:

```
/bin/sh -c 'cat > <case>/payload.json; env | grep "^CODEXBAR_" | sort > <case>/env.txt'
```

The shipped CLI fetched the Codex provider through the real `CodexCLIUsageStrategy` → production
`UsageFetcher.loadLatestCLIAccountSnapshot()` → `CodexRPCClient`, launched the (fake) `codex` app-server
and dispatched the hook through the production `HookTransitionDetector` + `HookRunner`. The terminal logs
(`terminal/plan-cli.log`) show the production path:

```
... com.steipete.codexbar.codex-rpc: binary=/tmp/codexbar-4800/fake-codex Codex RPC started
... com.steipete.codexbar.subprocess: binary=sh label=hook usage_updated timeout=10.0 Subprocess start
... com.steipete.codexbar.subprocess: binary=sh duration_ms=24 label=hook usage_updated status=0 Subprocess exit
... com.steipete.codexbar.hooks: event=usage_updated provider=codex ran hook
Watching 1 provider(s) every 60s: codex
Press Ctrl-C to stop.
usage_updated codex usage=12%
```

**Case A — plan observation present** (fake app-server returns `rateLimits.planType = "pro"` and a
ChatGPT account with `planType = "pro"`). Real hook delivery:

`hook-delivery/plan/payload.json` (stdin):
```json
{"account":"proof-runner@example.com","event":"usage_updated","plan":"pro",
 "planObservedAt":"2026-10-27T06:58:07Z","planSource":"local_rpc",
 "provider":"codex","resetAt":"2026-10-27T07:58:07Z",
 "secondaryResetAt":"2026-10-28T06:58:07Z","secondaryUsagePercent":0.4,
 "secondaryWindowMinutes":10080,"timestamp":"2026-10-27T06:58:07Z",
 "usagePercent":0.125,"windowMinutes":300}
```

`hook-delivery/plan/env.txt`:
```
CODEXBAR_EVENT=usage_updated
CODEXBAR_PLAN=pro
CODEXBAR_PLAN_OBSERVED_AT=2026-10-27T06:58:07Z
CODEXBAR_PLAN_SOURCE=local_rpc
CODEXBAR_PROVIDER=codex
... (windows/timestamps as usual)
```

**Case B — no plan observation** (same fake app-server returns rate limits without `planType` and an
API-key account). Real hook delivery omits the fields entirely:

`hook-delivery/absent/payload.json` has **no** `plan`, `planSource`, or `planObservedAt` keys, and
`hook-delivery/absent/env.txt` has **no** `CODEXBAR_PLAN*` variables. All 13 automated assertions in
`hook-delivery/hook-assertions.json` PASS (13/13).

The same build's shipped CLI JSON output shows the underlying snapshot field:
`cli-json/new-cli-usage-plan.json` contains
`"planObservation":{"source":"local_rpc","observedAt":"2026-10-27T06:58:13Z","rawPlan":"pro"}`;
`cli-json/new-cli-usage-absent.json` omits it.

Harness disclosure: the local Codex app-server is impersonated by `harness/fake-codex` (a small
Python JSON-RPC responder put on `CODEX_CLI_PATH`) because the runner has no Codex credentials. Everything
after that process boundary — provider strategy selection, RPC wire protocol, snapshot construction,
hook transition detection, rule matching, subprocess execution, JSON/env mapping — is the shipped PR-head
code. The proof config/hook rule was written by the workflow exactly as a user would configure it.

## 2) Data-model compatibility — released v0.81.0 payload through the new build's Codable model

The workflow downloaded the **released v0.81.0 CLI**
(`CodexBarCLI-v0.81.0-macos-arm64.tar.gz`, reports `CodexBar 0.81.0`) and drove it through the same fake
app-server path to write a **release-era usage payload** (`cli-json/old-cli-usage.json`). That payload
contains no `planObservation` field (grep count 0).

The fork-only `ProofPlanCompat` harness (source in `compat/harness-main.swift`, target added on the proof
branch only) then:

- decodes that old payload with the **new build's `UsageSnapshot` Codable model** → success,
  `planObservation == nil`;
- confirms data is retained: primary `12.5%`, secondary `40%`, `updatedAt` preserved, identity
  `loginMethod = "pro"`;
- re-encodes the snapshot with the new model → `planObservation` key absent (no placeholder/default added);
- decodes the same snapshot through `CLIUsageCache` (the persisted shape the shipped CLI reads) → success,
  `planObservation == nil`;
- maps it through `HookEvent.usageUpdated` → plan/planSource/planObservedAt omitted from JSON and env.

Result: `compat/compat-report.json` (plus `COMPAT OK` in `compat/compat-report.err`'s companion stdout).

Harness disclosure: the payload is real released-build output, but the decoder is the fork-only harness.
The shipped CLI's `CLIUsageCache` fallback cannot be triggered on a GitHub-hosted macOS runner: it is
gated to sessions without graphic access and to a locked-keychain credential failure
(`CLIUsageCache.fallbackReader`: `guard config.shareUsageWithCLI, !hasGraphicSession()`), so the harness
calls the same public Codable/`CLIUsageCache` types directly and is labeled as such.

## Files

| Path | Contents |
| --- | --- |
| `terminal/` | Raw shipped-CLI terminal logs (`plan-cli.log`, `absent-cli.log`), CLI versions, `hooks --help`/`usage --help`. |
| `hook-delivery/plan/` | Real hook stdin JSON, CODEXBAR_* env, CLI log for the plan-present delivery. |
| `hook-delivery/absent/` | Same for the no-plan-observation delivery (fields omitted). |
| `hook-delivery/hook-assertions.json` | 13/13 field assertions over both deliveries. |
| `cli-json/` | New-build CLI usage JSON (plan + absent), released v0.81.0 CLI usage JSON + stderr. |
| `compat/` | `compat-report.json` (old payload decode/round-trip/CLIUsageCache/hook mapping) and harness source. |
| `harness/` | Fake app-server, fork-only compat harness source, `Package.swift` and the proof workflow. |
| `build/` | App + harness build logs. |
| `git-head.txt` | Proof branch commit chain (`84587cf83` → PR head `a67d8017f`). |

No credentials, cookies, tokens, or personal data are involved: the run starts from an empty temp HOME
and config, and the only provider data is generated by the fake app-server.
