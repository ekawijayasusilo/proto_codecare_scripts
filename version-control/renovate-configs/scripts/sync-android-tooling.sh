#!/usr/bin/env bash
# Sync a Flutter client repo to its pinned Flutter SDK:
# - Dart: set environment.sdk in every pubspec that pins Flutter to the Dart version that Flutter release bundles.
# - Android: raise AGP, Kotlin and Gradle to the versions the Flutter SDK's app template uses (never lowers them).
# Renovate runs it on Flutter SDK bumps (see ../flutter.json5); run it by hand after a manual bump.
# Run from anywhere inside the client repo. Needs bash, git, curl, awk, sed, sort.
set -euo pipefail

die() { echo "sync-android-tooling: $*" >&2; exit 1; }

# env_value PUBSPEC KEY: environment.KEY, quotes stripped (the flutter: key under dependencies has no version).
env_value() {
  awk -v key="$2:" '
    { sub(/\r$/, "") }
    /^environment:/ { env = 1; next }
    env && /^[^[:space:]#]/ { exit }
    env && $1 == key { gsub(/["\047]/, "", $2); print $2; exit }
  ' "$1"
}
exact() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

cd "$(git rev-parse --show-toplevel)"

# Dart runs first: the Android part may exit early. Every pubspec, not only the one Renovate is processing:
# pub get in a workspace resolves all members, so one stale sdk: pin fails it.
# Set, not raise: a Dart-only hotfix (3.14.1) must go back to the bundled version (3.14.0).
# shortcut: pubspecs that pin sdk: but not flutter: (pure-Dart workspace members) are not synced; add them if a client has one.
RELEASES_URL=https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json
releases=""
while IFS= read -r pubspec; do
  pin_flutter=$(env_value "$pubspec" flutter)
  exact "$pin_flutter" || continue
  have_dart=$(env_value "$pubspec" sdk)
  if ! exact "$have_dart"; then
    echo "Dart: sdk '$have_dart' in $pubspec is not an exact X.Y.Z, skipping"
    continue
  fi
  [[ -n $releases ]] || releases=$(curl -fsSL "$RELEASES_URL") || die "cannot fetch $RELEASES_URL"
  # Pretty-printed JSON, one key per line. Beta entries read "3.15.0 (build ...)": keep the first token.
  want_dart=$(awk -F'"' -v want="$pin_flutter" '
    /\{/ { ch = v = d = "" }
    $2 == "channel" { ch = $4 }
    $2 == "version" { v = $4 }
    $2 == "dart_sdk_version" { split($4, a, " "); d = a[1] }
    /\}/ && ch == "stable" && v == want && d != "" { print d; exit }
  ' <<<"$releases")
  [[ -n $want_dart ]] || die "Flutter $pin_flutter (from $pubspec) not found on the stable channel of $RELEASES_URL"
  if [[ $have_dart == "$want_dart" ]]; then
    echo "Dart $have_dart already matches Flutter $pin_flutter ($pubspec)"
    continue
  fi
  sed -i.bak -E "/^environment:/,/^[^[:space:]#]/s/^([[:space:]]+sdk:[[:space:]]*[\"']?)${have_dart//./\\.}/\1$want_dart/" "$pubspec" &&
    rm "$pubspec.bak"
  echo "Dart $have_dart → $want_dart ($pubspec)"
done < <(git ls-files ':(glob)**/pubspec.yaml')

if [[ ! -d android ]]; then
  echo "no android/, skipping"
  exit 0
fi

# shortcut: Kotlin DSL files only, add Groovy patterns if a client still uses settings.gradle.
SETTINGS=android/settings.gradle.kts
WRAPPER=android/gradle/wrapper/gradle-wrapper.properties
[[ -f $SETTINGS ]] || die "$SETTINGS not found"
[[ -f $WRAPPER ]] || die "$WRAPPER not found"

flutter=$(env_value pubspec.yaml flutter)
exact "$flutter" ||
  die "environment.flutter in pubspec.yaml must be an exact X.Y.Z, got '$flutter'"

url="https://raw.githubusercontent.com/flutter/flutter/$flutter/packages/flutter_tools/lib/src/android/gradle_utils.dart"
src=$(curl -fsSL "$url") || die "cannot fetch $url"

# Flutter internals, can be renamed in any release.
template() {
  local v
  v=$(sed -nE "s/^const $1 = '([^']+)';.*/\1/p" <<<"$src")
  [[ -n $v ]] || die "const $1 not found in gradle_utils.dart for Flutter $flutter (renamed?)"
  echo "$v"
}
want_agp=$(template templateAndroidGradlePluginVersion)
want_kotlin=$(template templateKotlinGradlePluginVersion)
want_gradle=$(template templateDefaultGradleVersion)

# current FILE SED_REGEX LABEL: the version captured as \1, or fail.
current() {
  local v
  v=$(sed -nE "s/$2/\1/p" "$1" | tr -d '\r' | head -n1)
  [[ -n $v ]] || die "$3 version not found in $1"
  echo "$v"
}
AGP_LINE='id\("com\.android\.application"\)'
KOTLIN_LINE='id\("org\.jetbrains\.kotlin\.android"\)'
GRADLE_LINE='^distributionUrl='
VERSION='[[:space:]]*version[[:space:]]*\(?"([^"]+)".*' # version "x" or version("x")
have_agp=$(current "$SETTINGS" ".*$AGP_LINE$VERSION" AGP)
have_kotlin=$(current "$SETTINGS" ".*$KOTLIN_LINE$VERSION" Kotlin)
have_gradle=$(current "$WRAPPER" "$GRADLE_LINE.*gradle-([^-]+)-(all|bin)\.zip.*" Gradle)

newer() { [[ $1 != "$2" && $(printf '%s\n' "$1" "$2" | sort -V | tail -n1) == "$2" ]]; }

if newer "$have_gradle" "$want_gradle" && grep -q '^distributionSha256Sum' "$WRAPPER"; then
  die "$WRAPPER has distributionSha256Sum, which won't match Gradle $want_gradle. Update both by hand."
fi

changed=false
# raise LABEL FILE LINE_REGEX HAVE WANT: replace HAVE with WANT on the matching line, only upwards.
raise() {
  newer "$4" "$5" || return 0
  # -i.bak works with both GNU and BSD sed.
  sed -i.bak -E "/$3/s/([^0-9.])${4//./\\.}([^0-9.])/\1$5\2/" "$2" && rm "$2.bak"
  echo "$1 $4 → $5"
  changed=true
}
raise AGP "$SETTINGS" "$AGP_LINE" "$have_agp" "$want_agp"
raise Kotlin "$SETTINGS" "$KOTLIN_LINE" "$have_kotlin" "$want_kotlin"
raise Gradle "$WRAPPER" "$GRADLE_LINE" "$have_gradle" "$want_gradle"
$changed || echo "already up to date (Flutter $flutter: AGP $have_agp, Kotlin $have_kotlin, Gradle $have_gradle)"
