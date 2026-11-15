#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Auto-locate JDK 17+ if default java is older (e.g. macOS JDK 8)
resolve_java_home() {
  if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
    local ver
    ver="$("${JAVA_HOME}/bin/java" -version 2>&1 | head -n1 | sed -E 's/.*"([0-9]+).*/\1/')"
    if [[ "${ver:-0}" -ge 17 ]]; then
      echo "$JAVA_HOME"
      return 0
    fi
  fi

  local candidates=(
    "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
    "/opt/homebrew/opt/openjdk@17"
    "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
    "/opt/homebrew/opt/openjdk@21"
    "/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
  )

  for cand in "${candidates[@]}"; do
    if [[ -x "${cand}/bin/java" ]]; then
      echo "$cand"
      return 0
    fi
  done

  if /usr/libexec/java_home -v 17+ >/dev/null 2>&1; then
    /usr/libexec/java_home -v 17+
    return 0
  fi

  return 1
}

if ! RESOLVED_JAVA_HOME="$(resolve_java_home)"; then
  echo "ERROR: JDK 17+ is required for Gradle + d8. Install with: brew install openjdk@17" >&2
  exit 1
fi

export JAVA_HOME="$RESOLVED_JAVA_HOME"
export PATH="$JAVA_HOME/bin:$PATH"

if [[ -z "${ANDROID_HOME:-}" ]]; then
  if [[ -d "$HOME/Library/Android/sdk" ]]; then
    export ANDROID_HOME="$HOME/Library/Android/sdk"
  elif [[ -d "$HOME/Android/Sdk" ]]; then
    export ANDROID_HOME="$HOME/Android/Sdk"
  else
    echo "ERROR: ANDROID_HOME is not set and default Android SDK directory was not found." >&2
    exit 1
  fi
fi

cd "$PROJECT_DIR"
echo "Using JAVA_HOME=$JAVA_HOME"
echo "Using ANDROID_HOME=$ANDROID_HOME"

./gradlew --no-daemon test verifyDexArtifact "$@"

DIST_JAR="$PROJECT_DIR/build/dist/android-daemon.jar"
echo "Build complete: $DIST_JAR ($(wc -c < "$DIST_JAR" | tr -d ' ') bytes)"
