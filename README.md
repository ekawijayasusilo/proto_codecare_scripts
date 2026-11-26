# proto_codecare_scripts
Collections of shared scripts for Proto CodeCare

## Structure

Scripts are grouped by area (`<area>/<tool>/`). Each tool folder is self-contained, with its own README, examples, and tests.

```txt
version-control/
  github-setup-repo/     Apply standard settings to a GitHub repo
  renovate-configs/      Renovate presets, runner config, Android sync script
```

## Conventions

- `.env*` files are gitignored in every folder. Commit only `*.example` templates.
- Releases are per folder (release-please packages). Only `version-control/renovate-configs` is released for now
  (tags `vX.Y.Z`); commits elsewhere never trigger a release. A new released tool gets its own package with
  component tags (e.g. `fastlane-v1.0.0`).
