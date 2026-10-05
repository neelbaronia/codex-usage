# API-equivalent token estimates

Codex Usage bundles a **Standard short-context API list-price snapshot**, checked on **October 5, 2026**. It estimates recorded token usage in USD. It does not report your Codex subscription charge, credits consumed, an API invoice, or money saved.

`Sources/ModelPricing.swift` performs the calculation locally without an API key or a pricing network request. The verification date is not a price's effective date. The same snapshot applies to the entire selected history; it does not reconstruct historical rate changes.

## Rates and sources

USD per one million tokens. The main source is the [official OpenAI API pricing table](https://developers.openai.com/api/docs/pricing), using **Standard**, **short context** prices. Older Codex-specific rates were independently checked on the [GPT-5.2-Codex](https://developers.openai.com/api/docs/models/gpt-5.2-codex), [GPT-5.1-Codex](https://developers.openai.com/api/docs/models/gpt-5.1-codex), and [GPT-5.1-Codex-Max](https://developers.openai.com/api/docs/models/gpt-5.1-codex-max) model pages.

| Exact model ID | Uncached input | Cached input | Output |
| --- | ---: | ---: | ---: |
| gpt-6-astra | $10 | $1 | $50 |
| gpt-6.1-sol | $2 | $0.10 | $10 |
| gpt-6-sol | $2 | $0.20 | $10 |
| gpt-6-luna | $0.10 | $0.01 | $0.50 |
| gpt-5.6-sol | $4 | $0.40 | $20 |
| gpt-5.6-terra | $2 | $0.20 | $12 |
| gpt-5.6-luna | $0.20 | $0.02 | $1.20 |
| gpt-5.5 | $5 | $0.50 | $30 |
| gpt-5.4 | $2.50 | $0.25 | $15 |
| gpt-5.4-mini | $0.75 | $0.075 | $4.50 |
| gpt-5.4-nano | $0.20 | $0.02 | $1.25 |
| gpt-5.3-codex | $1.75 | $0.175 | $14 |
| gpt-5.2-codex | $1.75 | $0.175 | $14 |
| gpt-5.1-codex | $1.25 | $0.125 | $10 |
| gpt-5.1-codex-max | $1.25 | $0.125 | $10 |
| gpt-5.2 | $1.75 | $0.175 | $14 |
| gpt-5.1 | $1.25 | $0.125 | $10 |
| gpt-5 | $1.25 | $0.125 | $10 |
| gpt-5-mini | $0.25 | $0.025 | $2 |
| gpt-5-nano | $0.05 | $0.005 | $0.40 |
| gpt-4.1 | $2 | $0.50 | $8 |
| gpt-4.1-mini | $0.40 | $0.10 | $1.60 |
| gpt-4.1-nano | $0.10 | $0.025 | $0.40 |

GPT-5.6 Sol uses promotional API pricing announced as available at least through November 21, 2026. Review the source when updating the bundled snapshot.

## Calculation and limits

Logged input includes the cached subset. Output already includes reasoning tokens.

```text
USD = ((input − cached input) × input rate
       + cached input × cached rate
       + output × output rate) / 1,000,000
```

For example, 300,000 input tokens including 200,000 cached tokens, plus 10,000 output tokens on `gpt-6-astra`, estimate to **$1.70** under this baseline. Cached input and reasoning are not added a second time.

The three counters do not establish per-request context size or cache-write counts. The calculation therefore excludes long-context premiums and separate cache-write premiums. It never selects a request context tier from a repository or session token total. This can understate API cost. Fast/Ultrafast mode, Batch/Flex discounts, regional processing, tools, media generation, storage, tax, and negotiated prices are also excluded.

Model IDs must match this table exactly. No friendly names, guessed aliases, case normalization, or unverified dated snapshots are accepted. Other models remain unpriced and should still appear in token totals; dollar totals that omit them must be marked partial. Invalid counters also return an unpriced result, rather than zero: counts must be finite, nonnegative whole numbers no greater than `2^53 − 1`, with cached input no greater than inclusive input.
