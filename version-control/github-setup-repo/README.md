# github-setup-repo

Applies standard settings to an existing **public** GitHub repo: squash-only merges, a `main` ruleset, read-only `GITHUB_TOKEN`, Dependabot, secret scanning, and more. Needs `gh` logged in as a repo admin. Safe to re-run.

```bash
./setup-github-repo.sh --repo OWNER/NAME            # prompts for the rest
./setup-github-repo.sh --repo OWNER/NAME --yes --approvals 1 --secrets-file .env.github
./setup-github-repo.sh --help
```

`--dependabot` (on by default) also enables the **dependency graph**. GitHub's API has no separate switch for it: the graph comes with Dependabot alerts.

`--required-checks "build / build,lint"` sets the `main` ruleset's required status checks to exactly that list. Names are check names as shown on a PR, and all are expected from GitHub Actions. Leave the flag out to keep the current checks. The script can't remove checks; do that in the UI.

`--code-scanning-gate` adds a `code_scanning` rule to the `main` ruleset: PRs with new **high or critical** CodeQL security alerts (or CodeQL errors) can't merge. CodeQL must run on PRs, either through `--codeql` or the repo's own CodeQL workflow; otherwise PRs wait for results. Leave the flag out to keep the current rule. Don't add other SARIF uploaders, e.g. Scorecard, as gating tools.

> **Warning:** A required check must run on every PR. If its workflow has a `paths:` filter, PRs that don't touch those paths wait forever.

> **Note:** Re-running rewrites the rules the script sets from the flags given. Options you leave out fall back to their defaults (e.g. 0 approvals), so pass the same flags each time. Rules the script doesn't set (e.g. required checks added in the UI) and parameters it doesn't send are kept.

## Files

| File | Purpose |
|---|---|
| `setup-github-repo.sh` | The script |
| `.env.github.example` | Secrets/variables file format. Copy to `.env.github` (gitignored) |
