#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
node scripts/tests/localization.cjs
for file in shell/ui/*.js; do node --check "$file"; done
if [[ $(uname -s) == Darwin ]]; then
  swift build --product DigUpApp
  bin_dir="$(swift build --show-bin-path)"
  mkdir -p .build/localization-checks
  swiftc -parse-as-library Sources/DigUpApp/Localization.swift scripts/tests/LocalizationChecks.swift \
    -o .build/localization-checks/check
  for language in en zh-Hans; do
    .build/localization-checks/check "$bin_dir/DigUp_DigUpApp.bundle" \
      -AppleLanguages "($language)" "--expect=$language"
  done
fi
