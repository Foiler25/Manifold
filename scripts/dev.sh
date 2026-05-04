#!/usr/bin/env bash
# dev.sh — start/stop Manifold during local development.
#
# Workaround for the Xcode 26 scheme-detection issue with
# file-system-synchronized groups, where the Xcode IDE may not
# show the Manifold scheme in its picker even though
# `xcodebuild -list` sees it. This script does what `Cmd-R` would
# do, end-to-end.
#
# Usage:
#   ./scripts/dev.sh start   # build + launch (default if no arg)
#   ./scripts/dev.sh stop    # quit any running instance
#   ./scripts/dev.sh restart # stop + start
#   ./scripts/dev.sh status  # check whether Manifold is running

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CMD="${1:-start}"

stop_manifold() {
  if pgrep -x Manifold >/dev/null; then
    echo "==> Stopping Manifold"
    pkill -x Manifold
    # Wait up to 3s for clean shutdown, then SIGKILL if still running.
    for _ in 1 2 3; do
      pgrep -x Manifold >/dev/null || return 0
      sleep 1
    done
    echo "   (didn't stop cleanly; sending SIGKILL)"
    pkill -9 -x Manifold || true
  else
    echo "==> Manifold is not running"
  fi
}

start_manifold() {
  echo "==> Resolving SPM dependencies"
  xcodebuild -resolvePackageDependencies -project Manifold.xcodeproj >/dev/null

  echo "==> Building Manifold (Debug)"
  xcodebuild -scheme Manifold -configuration Debug -destination 'platform=macOS' build \
      2>&1 | grep -E "error:|warning:|BUILD" || true

  APP_PATH="$(
    find "$HOME/Library/Developer/Xcode/DerivedData" \
      -path '*Manifold-*/Build/Products/Debug/Manifold.app' \
      -not -path '*Index*' \
      2>/dev/null | head -1
  )"

  if [[ -z "$APP_PATH" ]]; then
    echo "error: couldn't find built Manifold.app under DerivedData" >&2
    exit 1
  fi

  # Kill any stale instance before launching the new build.
  pkill -x Manifold 2>/dev/null || true
  sleep 1

  echo "==> Launching $APP_PATH"
  open "$APP_PATH"
  echo "==> Manifold is starting (cable-connector icon in the menu bar)."
}

status_manifold() {
  if pgrep -x Manifold >/dev/null; then
    echo "Manifold is running:"
    pgrep -lf '/Manifold.app/Contents/MacOS/Manifold' | head -3
  else
    echo "Manifold is not running"
  fi
}

case "$CMD" in
  start)   start_manifold ;;
  stop)    stop_manifold ;;
  restart) stop_manifold; start_manifold ;;
  status)  status_manifold ;;
  *)
    echo "Usage: $(basename "$0") {start|stop|restart|status}" >&2
    exit 2
    ;;
esac
