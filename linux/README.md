# ClaudeNotch for Linux

The Linux edition of ClaudeNotch. Same idea as the macOS app: Claude Code's
permission prompts, questions and session status appear in a small card at
the top centre of the screen, so you can approve or deny without going back to
the terminal.

It speaks the same hook protocol as the macOS app (HTTP hooks to
`127.0.0.1:53127`), so the entries it writes into `~/.claude/settings.json` are
the same ones.

Status: early. See "What works" below.

## Layout

    claudenotch/   the app (Python 3.10+, GTK 3 through PyGObject)
    tests/         unit and integration tests, no display needed
    test-env/      a Docker image with Xvfb that runs the real UI headless
    packaging/     builds the .deb
