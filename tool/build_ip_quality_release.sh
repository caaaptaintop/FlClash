#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v rustup >/dev/null && [[ -x /opt/homebrew/opt/rustup/bin/rustup ]]; then
  export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
fi
export RUSTUP_TOOLCHAIN="$(awk -F '"' '/^channel =/{print $2}' plugins/rust_api/rust/rust-toolchain.toml)"
flutter pub get
dart run intl_utils:generate
flutter build macos --release --dart-define=SAFE_MODE=false --dart-define=APP_ENV=stable
