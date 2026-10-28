#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# This repository has several GitHub Git dependencies. On machines where
# github.com HTTPS is unreliable, rewrite them to SSH for this process only.
# The global Git configuration is intentionally left alone.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="url.git@github.com:.insteadOf"
export GIT_CONFIG_VALUE_0="https://github.com/"

concurrency="${CONCURRENCY:-2}"
skip_pub_get="${SKIP_PUB_GET:-0}"

if [[ "$skip_pub_get" != "1" ]]; then
  echo "==> flutter pub get"
  flutter pub get
fi

echo "==> flutter test --no-pub --concurrency=$concurrency $*"
flutter test --no-pub "--concurrency=$concurrency" "$@"
