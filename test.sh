#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEST_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-usage-tests.XXXXXX")
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT HUP INT TERM
cd "$PROJECT_DIR"

xcrun swiftc -O -swift-version 5 Sources/UsageModels.swift Sources/UsageProvider.swift \
  Tests/UsageProviderTests.swift -o "$TEST_BUILD_DIR/provider"
"$TEST_BUILD_DIR/provider"
xcrun swiftc -O -swift-version 5 Sources/LocalUsageHistory.swift \
  Tests/LocalUsageHistoryTests.swift -o "$TEST_BUILD_DIR/history"
"$TEST_BUILD_DIR/history"
xcrun swiftc -O -swift-version 5 Sources/UsageModels.swift Sources/UsageProvider.swift \
  Sources/LocalUsageHistory.swift Sources/UsageForecast.swift Tests/UsageForecastTests.swift \
  -o "$TEST_BUILD_DIR/forecast"
"$TEST_BUILD_DIR/forecast"
xcrun swiftc -O -swift-version 5 Sources/LocalUsageHistory.swift Sources/ModelUsageRates.swift \
  Tests/ModelUsageRatesTests.swift -o "$TEST_BUILD_DIR/rates"
"$TEST_BUILD_DIR/rates"
