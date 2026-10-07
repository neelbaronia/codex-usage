# Codex Usage

<img src="Resources/AppIcon.png" width="128" alt="Codex Usage: chat knot inside an allowance ring">

A small native macOS menu bar app showing the remaining **Codex account allowance** for the account already signed into Codex. A monochrome ChatGPT mark sits inside a remaining-usage ring, alongside the percentage. Click it for a compact instrument panel with warm aluminum housing, an inset olive readout, and tactile controls; expand **Model token rates** for more detail. Switch between **Remaining Allowance** and **Token Usage** without leaving the panel. The panel keeps the same warm appearance in light and dark mode.

The Remaining Allowance tab displays live Codex subscription limits. Token Usage summarizes locally recorded input, cached input, and output tokens. The app does not measure actual API billing, API credit balances, or every ChatGPT product's limits. The menu bar uses the lowest known remaining percentage among the main Codex bucket's windows; the popover shows each available window separately.

## Download for Mac

**[Download the latest release](https://github.com/neelbaronia/codex-usage/releases/latest)**

1. Under **Assets**, download **`Codex-Usage-1.6.2-macos-universal-r3.dmg`**.
2. Open the DMG and drag **Codex Usage** onto **Applications**, then eject the disk image.
3. Open Codex Usage. Its logo and remaining percentage appear in your Mac's menu bar; there is no Dock window.
4. Have the Codex CLI or Codex desktop app installed and signed in with your ChatGPT account. The widget uses that existing sign-in; no API key or separate account is needed.

A ZIP containing the same app is also available. Extract it and move **Codex Usage.app** to **Applications**. GitHub's source-code archives are for building the app yourself.

The download contains both Apple silicon and Intel executables and targets **macOS 13 or later**. You do not need Xcode or Node to run the widget. The current release has been tested on Apple silicon with macOS 26; Intel and earlier supported macOS versions are cross-compiled, not yet tested on physical machines. Your installed Codex version has its own system requirements.

### First launch

Release **1.6.2 is Developer ID signed and notarized by Apple**. The app and disk image each have their Apple notarization ticket attached. Both the DMG and its app pass Gatekeeper as **Notarized Developer ID**. macOS may still show its normal confirmation that the app was downloaded from the internet; choose **Open** to launch it. See [Apple's explanation of notarized apps](https://support.apple.com/en-us/102445).

Version 1.4.1 was ad hoc signed and not notarized. Download 1.4.2 or later for the notarized release. Builds you compile yourself or download from CI remain ad hoc signed by default.

### Updates and checksums

To update, choose **Settings → Quit** in the widget, download the newer release, and replace the app in Applications. Updates are manual. Your login remains in Codex, and widget preferences are stored locally.

The release includes a matching **.dmg.sha256** file for the DMG. Put it beside the DMG and run:

```sh
shasum -a 256 -c Codex-Usage-1.6.2-macos-universal-r3.dmg.sha256
```

The ZIP uses **SHA256SUMS.txt**. Put it beside the ZIP and run:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

## Build from source

Requires macOS, Xcode Command Line Tools with a current Swift compiler, and an installed, signed-in Codex CLI or desktop app for live usage. The offline tests do not need a Codex account.

```sh
git clone https://github.com/neelbaronia/codex-usage.git
cd codex-usage
/bin/sh build.sh
mkdir -p "$HOME/Applications"
ditto "build/Codex Usage.app" "$HOME/Applications/Codex Usage.app"
open "$HOME/Applications/Codex Usage.app"
```

Quit an existing copy before replacing it. The default build targets your Mac's architecture with a macOS 13 deployment target. To create and verify the universal release ZIP and checksums:

```sh
/bin/sh package-release.sh
```

The release script writes to `dist/`; the universal app is built separately from the normal local build. Signing defaults to ad hoc. A maintainer can explicitly supply `CODE_SIGN_IDENTITY` to select a valid Developer ID Application certificate, enable hardened runtime, and obtain a secure timestamp. Public notarized releases require the separate workflow in [RELEASING.md](RELEASING.md); a normal local or CI build is not notarized.

## Use

- Usage refreshes on startup, every five minutes, and when the Mac wakes. Opening an older result also triggers a refresh.
- Click the menu bar indicator, then **Settings → Refresh now** for a manual update. Settings also contains **Open Codex**, **Launch at login**, and **Quit**.
- The headline matches the most limiting allowance shown in the menu bar; other reported windows remain visible below it. **Model token rates** expands the model selector, recorded rates, and forecast details. The expanded/collapsed choice is remembered.
- Timeline markers show the local date and clock time for the estimated allowance limit and reset, with a short time-zone label when space allows. The forecast stays anchored to its allowance reading. Window names come from the durations reported by Codex.
- **Launch at login** is optional. If macOS requests approval, use **Allow in Login Items…** or System Settings → General → Login Items.
- Missing usage appears as unknown or unavailable, never as an unused allowance. A failed refresh preserves the last successful result, shows an error and update time, and marks the menu bar percentage with `!`. Old data is also marked stale; a passed reset time does not imply a fresh quota.

## Token history

**Token Usage** shows total input + output tokens, an activity chart, the cached-input subset, and totals by model. Choose **7 days**, **30 days**, or **All available**. The shorter ranges include today and the preceding 6 or 29 days in your Mac's time zone. All available means retained local history, not the age of your account.

Opening Token Usage starts a background scan. Remaining Allowance stays available while it loads. Subsequent range changes use cached summaries; the regular five-minute refresh and **Settings → Refresh now** update history too. No Node runtime, API key, or separate service is needed. Cached input is part of input and reasoning is part of output, so neither is counted twice.

## Estimated runway

The compact timeline places **Now**, the **estimated limit**, and **Reset** on a proportional line with local dates. Weekday labels and day ticks mark local midnight, including daylight-saving transitions. Hover over it or use accessibility tools for full dates and times. Expand **Model token rates** to choose a model (or the recent account pace, when available). An estimate after reset is labeled **End without reset**, since the allowance renews first; very distant estimates use an arrow at the chart edge. When a model's runway is unavailable, today and reset still appear. The projected end is anchored to the live reading's timestamp and changes when new readings arrive.

The popover combines the live remaining allowance with the last seven days of local model/token metadata. It shows an overall estimate from the account's recent percentage consumption, and a separate scenario for each model used alone at its observed pace. Estimates are conditional: keep a similar pace, concurrency, reasoning/speed settings, and input/cache/output mix. They are not a guaranteed token balance.

The model estimate uses account-wide quota snapshots in chronological order. It accepts only non-overlapping periods with one known model, at least 30 minutes of observations, and at least two percentage points consumed. One-minute guards around the period reject overlapping model activity. A model needs at least three usable periods before showing a forecast; otherwise it says **Runway unavailable**. Cached input is part of input and reasoning is part of output, so neither is counted twice.

**Recorded token pace** is independent of the runway estimate. Every model with local activity shows recorded tokens/hour; hover over its row for tokens/day and its total. Rates use the full seven-day reporting window (or a shorter available window), including idle time and all concurrent runs. These are usage averages, not model generation speed or official subscription quota costs. Rates still appear when models overlap or the allowance service is unavailable. Runway uses the pace from isolated calibration periods, so it may differ from a simple division by the full-week rate.

Remaining tokens = remaining percentage × sampled tokens ÷ sampled percentage consumed. Remaining hours use those tokens at the sampled token rate. The displayed range covers observed faster/slower periods plus meter rounding; it is not a confidence interval. Model differences are measured from history, not inferred from API prices. [OpenAI's pricing documentation](https://learn.chatgpt.com/docs/pricing#what-are-the-usage-limits-for-my-plan) explains that credit prices alone do not determine subscription usage.

Reset-time drift is tolerated, but actual meter decreases split the observations. Estimates are withheld for stale data, restricted accounts, and expired windows. Incomplete or ambiguous history also disables model calibration, because missing activity could hide another model. If the overall estimate extends past the next reset, the widget says it is likely to last until reset. Banked resets are never included as extra capacity or consumed automatically.

Local history may miss other devices, cloud runs, deleted sessions, or other account features. Those can consume the same allowance and confound a model estimate. The first history scan can take a moment; later scans reuse unchanged files in memory. Usage remains available while history is loading.

## Data and privacy

No API key or separate login is needed. Each refresh launches a temporary local `codex app-server` process and reads `account/rateLimits/read` through Codex's existing authentication. Codex contacts OpenAI to retrieve the current limits. The widget does not read or copy authentication files, upload session history, generate model output, purchase credits, or consume a reset.

The widget reads local session logs for numerical usage, model metadata, and recorded working directories. It retains only that metadata in memory, without saving prompts, responses, or usage history of its own. Server diagnostics are discarded; displayed errors use fixed messages rather than raw account details. Quitting stops future refreshes.

## Troubleshooting

If usage is unavailable, open Codex, confirm that the intended ChatGPT account is signed in, and refresh. API-key-only authentication may not expose subscription allowance. Network failures time out after about 25 seconds.

The app searches `PATH`, common Homebrew/local locations, nvm's installed Node versions, and Codex/ChatGPT desktop app bundles in `/Applications` and `~/Applications`. It uses a native Codex executable, so Finder does not need your shell's Node setup. If no executable is found, install or update Codex and try again.

To uninstall, open **Settings**, turn off **Launch at login**, click **Quit**, and move **Codex Usage.app** from your Applications folder to the Trash.

## Checks

Run all offline checks with `/bin/sh test.sh`. CI runs the same checks and verifies the universal package.

Individual suites:

```sh
xcrun swiftc -swift-version 5 Sources/UsageModels.swift Sources/UsageProvider.swift Tests/UsageProviderTests.swift -o /tmp/codex-usage-provider-tests
/tmp/codex-usage-provider-tests
```

Add `--live` to the final command to also verify the current signed-in account's limits. Tests cover missing data, multiple buckets, percentage conversion, protocol framing, sanitized failures, timeout behavior, and process cleanup.

History and forecast checks:

```sh
xcrun swiftc -O -swift-version 5 Sources/LocalUsageHistory.swift Tests/LocalUsageHistoryTests.swift -o /tmp/codex-local-history-tests
/tmp/codex-local-history-tests
xcrun swiftc -O -swift-version 5 Sources/UsageModels.swift Sources/UsageProvider.swift Sources/LocalUsageHistory.swift Sources/UsageForecast.swift Tests/UsageForecastTests.swift -o /tmp/codex-usage-forecast-tests
/tmp/codex-usage-forecast-tests
xcrun swiftc -O -swift-version 5 Sources/LocalUsageHistory.swift Sources/ModelUsageRates.swift Tests/ModelUsageRatesTests.swift -o /tmp/codex-model-usage-rates-tests
/tmp/codex-model-usage-rates-tests
```

The history and forecast test binaries accept `--live`. History checks cover streaming, cache refresh, forks, duplicate requests, malformed metadata, and legacy counter handling. Forecast checks cover model isolation, reset drift and decreases, meter rounding, idle periods, stale inputs, and missing/ambiguous data. Token-rate checks cover mixed models, idle reporting time, input/cache/output accounting, partial history, and invalid data. Analytics checks cover calendar boundaries, empty ranges, repository identity, partial pricing, cached-input accounting, and daily/model/repository reconciliation. Pricing checks cover every bundled rate, unknown models, and invalid counters.

## Branding assets

The monochrome mark is bundled locally as a vector PDF; the app does not fetch logos at runtime. Source and license attribution are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

MIT. See [LICENSE](LICENSE). This is an independent utility, not an official OpenAI product. Third-party names and marks remain the property of their owners.
