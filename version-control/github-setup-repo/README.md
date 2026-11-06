# github-setup-repo

Applies standard settings to an existing **public** GitHub repo: squash-only merges, a `main` ruleset, read-only `GITHUB_TOKEN`, Dependabot, secret scanning, and more. Needs `gh` logged in as a repo admin. Safe to re-run.

```bash
./setup-github-repo.sh --repo OWNER/NAME            # prompts for the rest
./setup-github-repo.sh --repo OWNER/NAME --yes --approvals 1 --secrets-file .env.github
./setup-github-repo.sh --help
```

> **Note:** Re-running rewrites the rulesets from the flags given. Options you leave out fall back to their defaults (e.g. 0 approvals), so pass the same flags each time.

## Files

| File | Purpose |
|---|---|
| `setup-github-repo.sh` | The script |
| `.env.github.example` | Secrets/variables file format. Copy to `.env.github` (gitignored) |
| `tests/test-setup-github-repo.sh` | Offline test using a stub `gh`: `bash tests/test-setup-github-repo.sh` |
