# renovate-configs

Shared Renovate policy for all Proto CodeCare client repos. The Renovate runner workflow lives in
[`proto_codecare`](https://github.com/ekawijayasusilo/proto_codecare). This folder holds what it uses: the presets client
repos extend, the runner's global config, and the Android tooling sync script.

```txt
renovate-configs/
  default, base, github-actions,      ◄── extends ─────────── client repos' .github/renovate.json5
  dart, allowlist, flutter.json5
  runner                              ◄── globalExtends ───── proto_codecare runner
  scripts/sync-android-tooling.sh     ◄── curl at same tag ── flutter.json5 postUpgradeTasks
```

## Which presets to extend

Reference format: `github>ekawijayasusilo/proto_codecare_scripts//version-control/renovate-configs/<name>#vX.Y.Z`.

| Repo type | `extends` |
|---|---|
| Flutter app or package | `default` + `flutter.json5` |
| Pure Dart package | `default` + `dart` |
| Anything else (Android-only, web, tooling) | `default` |

A Flutter repo can copy [`examples/flutter-app.renovate.json5`](examples/flutter-app.renovate.json5) to
`.github/renovate.json5`. `flutter.json5` must be referenced **with** its extension.

## Preset catalogue

| File | Kind | Goal | Use when |
|---|---|---|---|
| `default.json` | preset | Entry point: `base` + `github-actions` | Every repo |
| `base.json` | preset | Shared policy: `config:recommended`, semantic commits, schedule (before 6am Jakarta), 7-day age, dashboard, alerts | Via `default` |
| `github-actions.json` | preset | Own `proto_codecare` / `proto_codecare_scripts` refs: patch automerge, no age gate | Via `default` |
| `flutter.json5` | preset | Flutter rules: SDK group, workspace lockfile fix, Android tooling sync, Gradle off. Extends `dart` | Flutter apps and packages |
| `dart.json` | preset | Dart rules: pin, test-utility automerge, package-family groups. Extends `allowlist` | Pure Dart repos (Flutter repos get it via `flutter`) |
| `allowlist.json` | preset | Named pub packages whose patch/minor updates automerge | Via `dart` |
| `runner.json` | **global** preset | Runner-only options incl. `allowedCommands` | Only the runner, via `globalExtends`. Never in `extends` |
| `scripts/sync-android-tooling.sh` | script | Bumps AGP / Kotlin / Gradle to the Flutter SDK's template versions | Run by `flutter.json5`; or by hand after a manual Flutter bump |

Notable behaviour:

- **Dart + Flutter SDK** bumps come in one PR (`renovate/dart-and-flutter-sdk`), never automerged, no age gate. Check
  by hand that the Dart version matches the one bundled with the new Flutter.
- **Pub workspaces:** after any pub bump Renovate runs `flutter pub get` in the package's folder, so the root
  `pubspec.lock` is updated too.
- **Android sync:** Flutter SDK bumps also run the sync script (see below).
- **Gradle managers are off:** they propose versions above what the Flutter SDK supports. The sync script replaces them.
- **Own releases** (`proto_codecare`, `proto_codecare_scripts`) skip the 7-day age gate; patches automerge.

## Allowlist rules

`allowlist.json` lists pub packages whose patch and minor updates automerge in every client.

- Only small, independent packages every client can take unattended (formatting, date/calendar helpers). Automerge
  still waits for the 7-day age and green CI.
- Never grouped families (bloc, firebase, widgetbook) or packages that add lints (`very_good_analysis`).
- Never `intl`: the Flutter SDK pins it through `flutter_localizations`, so bumps fail to resolve.
- A package only one repo wants automerged goes in that repo's own config. Adding it here needs a release.

## Security split

> **Note:** Renovate cannot fix pub (Dart/Flutter) vulnerabilities. Flutter repos keep **Dependabot alerts + security
> updates** on (`setup-github-repo.sh --dependabot`), plus proto_codecare's `dependabot.yaml` stub (security PRs only).

Renovate's `vulnerabilityAlerts` still covers GitHub Actions and other ecosystems it supports. Its bypass of the 7-day
age gate for alerts applies only to those ecosystems.

## Runner config

`runner.json` is **global** config: the runner loads it at startup with `RENOVATE_GLOBAL_EXTENDS` (no checkout
needed). It sets `platform: github`, autodiscovers the repos the GitHub App is installed on, skips repos without a
committed config (`requireConfig: required`, `onboarding: false`), and lists `allowedCommands`.

Only global config can allow commands, so a client repo can never grant itself command execution. Renovate runs the
commands without a shell (no pipes), which is why the sync script is downloaded and run in two steps.

> **Warning:** a new command in a preset needs its regex in `allowedCommands` **in the same release**. Otherwise
> Renovate refuses to run it. Adding commands never breaks older presets.

## Android sync script

`scripts/sync-android-tooling.sh` raises three versions in a Flutter client to what the pinned Flutter SDK's app
template uses. The source of truth is
`flutter/flutter/<version>/packages/flutter_tools/lib/src/android/gradle_utils.dart`.

| Flutter constant | Updates |
|---|---|
| `templateAndroidGradlePluginVersion` | `com.android.application` in `android/settings.gradle.kts` |
| `templateKotlinGradlePluginVersion` | `org.jetbrains.kotlin.android` in `android/settings.gradle.kts` |
| `templateDefaultGradleVersion` | `distributionUrl` in `android/gradle/wrapper/gradle-wrapper.properties` |

- Reads the exact `environment.flutter` pin from the root `pubspec.yaml`. Works from any folder in the repo.
- Only raises versions, so a newer manual bump is kept. Re-running is a no-op.
- Skips repos without `android/`. Fails, with a message, on Groovy-only builds, a missing pattern, a renamed Flutter
  constant or a pinned `distributionSha256Sum`. Renovate then shows an "artifact update problem" on the PR.

Local use after a manual Flutter bump, from the client repo:

```bash
curl -fsSL https://raw.githubusercontent.com/ekawijayasusilo/proto_codecare_scripts/vX.Y.Z/version-control/renovate-configs/scripts/sync-android-tooling.sh | bash
```

> **Warning:** a version bump alone isn't always enough. AGP 9 also needs build-script changes (drop
> `kotlin-android`, `kotlinOptions` → `kotlin { compilerOptions }`, Java 17). When the client's Android build check
> goes red on an SDK PR, do that migration by hand on the Renovate branch.

## Versioning

- Always reference an **exact tag** (`#vX.Y.Z`), never `main`: one broken commit would hit every repo at once.
  Renovate bumps the tag for you; patch releases automerge.
- Tags come from release-please. `flutter.json5` at tag `vN` always downloads the sync script from the same `vN`.
- **Never move or delete a tag:** the runner executes the script fetched by tag.
- Release rules: behaviour change for consumers is `feat:` or `fix:`; breaking (removed preset, renamed path, stricter
  rule) is `feat!:`; docs-only is `docs:` (no release).
