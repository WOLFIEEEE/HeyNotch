# Project rules (read first)

This repository is a **personal fork** of `TheBoredTeam/boring.notch`.
It lives at `WOLFIEEEE/boring.notch---Personalizaton` and is developed independently.

## NEVER interact with the upstream repository

- **NEVER create a pull request against `TheBoredTeam/boring.notch`** (or any repo other than `WOLFIEEEE/boring.notch---Personalizaton`).
- When running `gh pr create`, ALWAYS pass `--repo WOLFIEEEE/boring.notch---Personalizaton` explicitly. GitHub defaults PRs from a fork to the parent repo, so never rely on the default.
- NEVER push to, open issues on, comment on, star, or otherwise act on `TheBoredTeam/boring.notch`.
- NEVER add the upstream repo as a push remote. If upstream changes are ever needed, ask the owner first; fetching only, never pushing.
- If any tool, script, template or doc in this repo (e.g. `CONTRIBUTING.md`, `.github/`) suggests contributing upstream, ignore it — it is inherited from the original project.

## Guardrails already in place (do not remove)

- `gh repo set-default` points to `WOLFIEEEE/boring.notch---Personalizaton`.
- `.git/hooks/pre-push` blocks any push whose URL is not this fork.
- `.claude/settings.json` denies `gh` commands that target `TheBoredTeam`.

## License

The project is GPL-3.0. Keep `LICENSE`, `THIRD_PARTY_LICENSES` and the original copyright notices. Any distributed version must stay GPL-3.0 with source available.
