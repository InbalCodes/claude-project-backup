# Vendored: claude-code-export-import

The three `.py` files and `LICENSE` in this folder are vendored, unmodified,
from:

https://github.com/Dangelo123/claude-code-export-import

Commit: `0fdab31aa50c2bf37f6e6e3c2cf3d22779dd6f62`

MIT licensed (see `LICENSE`). This is a third-party, unofficial,
reverse-engineered tool for migrating Claude desktop app session state
(including the app's internal sidebar index) between machines. It is used
here as the "full desktop-app fidelity" path in `migrate_gui.ps1`'s restore
flow — optional, unchecked by default, and not a replacement for the manual
`claude --resume` workaround documented in `SKILL.md`, which remains the
primary supported path.

For updates, issues, or to audit the full project (docs, tests, GUI), see
the source repository above rather than this vendored subset — only the
files actually needed at runtime (`batch.py`, `claude_session_port.py`,
`localstorage_paths.py`) are included here; `gui.py`, `docs/`, `README.md`,
and the test suite were intentionally left out since this skill's own
`migrate_gui.ps1` is the interface.
