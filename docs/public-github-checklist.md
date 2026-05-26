# Public GitHub Checklist

Before pushing this repo to a public remote, verify:

- `.env` is not tracked.
- `logs/`, `runtime/`, and `staging/` are not tracked.
- `secrets/` contains only `.gitkeep` in Git.
- No real `rclone` config, OAuth token, or restic password file is tracked.
- No restore output, backup manifest with local-only paths, or ad-hoc test artifact is tracked.
- `git status --short` shows only the files you intend to publish.

Helpful checks:

```bash
git status --short
git ls-files
./scripts/public-repo-check.sh
rg -n --hidden -S "password|secret|token|api[_-]?key|BEGIN .*KEY|PRIVATE KEY|C:\\\\Users\\\\|/c/Users/|/Users/|/home/" .
```

Expected sensitive locations stay local-only:

- `.env`
- `secrets/` contents other than `.gitkeep`
- `rclone.conf`
- `logs/`
- `runtime/`
- `staging/`
