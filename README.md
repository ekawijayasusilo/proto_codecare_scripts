# proto_codecare_scripts
Collections of shared scripts for Proto CodeCare

## setup-github-repo.sh

Applies standard settings to an existing **public** GitHub repo: squash-only merges, a `main` ruleset, read-only `GITHUB_TOKEN`, Dependabot, secret scanning, and more. Needs `gh` logged in as a repo admin. Safe to re-run.

```bash
./setup-github-repo.sh --repo OWNER/NAME            # prompts for the rest
./setup-github-repo.sh --repo OWNER/NAME --yes --approvals 1 --secrets-file .env.github
./setup-github-repo.sh --help
```

For the secrets file format, see `.env.github.example`. Run the offline test with `bash tests/test-setup-github-repo.sh`.
