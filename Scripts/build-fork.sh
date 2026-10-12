#!/bin/zsh
# Builds a Release copy of this fork signed with Charles's Developer ID, without a provisioning profile.
#   scripts/build-fork.sh            build into build/fork
#   scripts/build-fork.sh --install  also replace /Applications/VirtualBuddy Snapshots.app
set -euo pipefail

ROOT=${0:A:h:h}
DERIVED="$ROOT/build/fork"
IDENTITY="DE12DC552E67ADE20F1687B576E0AA5627ACF1E6" # Developer ID Application: Charles Krivan (RLHAQ44Q53)
APP_NAME="VirtualBuddy Snapshots.app"

xcodebuild build \
  -project "$ROOT/VirtualBuddy.xcodeproj" \
  -scheme VirtualBuddy \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM=RLHAQ44Q53 \
  PROVISIONING_PROFILE_SPECIFIER= \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  | grep -E "error:|warning: .*[Ss]napshot|BUILD (SUCCEEDED|FAILED)" || true

PRODUCT="$DERIVED/Build/Products/Release/VirtualBuddy.app"
[[ -d "$PRODUCT" ]] || { echo "Build failed"; exit 1; }

codesign --verify --deep --strict "$PRODUCT"
echo "Built $PRODUCT"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/$APP_NAME"
  ditto "$PRODUCT" "/Applications/$APP_NAME"
  echo "Installed /Applications/$APP_NAME"
fi
