# Vendored skills

The skills in this directory come from two upstream projects, vendored as plain files rather than installed as live Claude Code plugins — the VSCode extension environment used for this repo does not expose the `/plugin` marketplace commands.

## spec-kit (`speckit-*`)

Installed via the `specify` CLI (`uv tool install specify-cli --from git+https://github.com/github/spec-kit.git`, then `specify init --here --integration claude`). Source: https://github.com/github/spec-kit (MIT).

Templates under `.specify/templates/overrides/` and the `speckit-specify`/`speckit-plan`/`speckit-tasks` skill logic here have been rewritten for this repo — see [AGENT.md](../../AGENT.md) §9 — to talk about datasets/entities/medallion layers instead of generic software-engineering user stories, APIs, and `src/models/services`. Re-running `specify init` or `specify upgrade` would overwrite these customizations; don't, without re-applying them.

## superpowers (everything else)

Copied unmodified from https://github.com/obra/superpowers (MIT License, © Jesse Vincent), version `6.3.0`, commit `b36e0829c6d0140e93cfef2ca599b1b07d4a7797` (2026-08-12).

Not vendored: the plugin's `hooks/` (session-start enforcement hook) and the per-harness adapter files, since we're running Claude Code natively rather than through the plugin wrapper. The skills rely on being surfaced via their own `description` frontmatter (see `using-superpowers/SKILL.md`), which works the same whether installed as a plugin or as plain project skills.

To pick up upstream updates later: re-clone the tag/commit you want and re-copy the `skills/` subfolders here.
