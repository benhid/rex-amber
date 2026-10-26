# Amber

Built for [Rex](https://www.superlogical.com/rex), Amber reviews your Claude Code sessions when they go idle and suggests changes to your project's instructions.

> [!NOTE]
> Amber is in beta. It evolves as Rex does, and some things can still go wrong.

## Requirements

- macOS with [Rex](https://www.superlogical.com/rex).
- [Claude Code](https://claude.com/claude-code) 2.1.295 or later, signed in. Earlier versions don't report their status to the terminal, and Amber depends on that status.
- `jq` and `shasum` (both ship with macOS).

## Install

```sh
git clone https://github.com/benhid/rex-amber ~/.config/rex/amber
echo 'require("amber.action")' >> ~/.config/rex/init.lua
rex config reload
```

Then run **Enable Amber** from Rex's command palette.

To update, run `git pull` in that folder. To uninstall, run **Disable Amber**, delete the folder and remove the `require` line from `init.lua`.

## How it works

```
Claude Code ──(program status, OSC 7501)──▶ Rex ──(terminal.program_status_changed)──▶ amber.lua
                                                                                          │
                                       idle 10 min ──▶ new part of the transcript ──▶ claude -p (reviewer)
                                                                                          │
                                                          .claude-suggestions/*.md ◀──────┘
```

Claude Code tells Rex whether it's working or waiting for you. Amber listens to that in every pane. When a pane has been waiting for 10 minutes and its project has a `.claude/CLAUDE.md`, Amber takes the part of the conversation it hasn't read yet and hands it to a second Claude, the reviewer, which writes any suggestions into `.claude-suggestions/`. You go through them with `/review-suggestions`.

The reviewer's instructions are in [`review-prompt.md`](review-prompt.md).

## What it writes in your projects

| Path | What |
|---|---|
| `.claude-suggestions/*.md` | One suggestion per file: frontmatter with the target file, session and date, then a summary, the evidence, and a diff. |
| `.claude-suggestions/rejected/` | Suggestions you rejected, with your reason, so similar ones aren't suggested again. |
| `.claude-suggestions/.observations.md` | Weak signals waiting to repeat in another session. |
| `.claude-suggestions/.progress.json` | Review progress per session and the last audited `CLAUDE.md`. Per-machine state. |
| `.claude/skills/review-suggestions/SKILL.md` | The `/review-suggestions` skill, copied from [`review-suggestions.md`](review-suggestions.md) and refreshed when it changes. |

Commit `.claude-suggestions/` if you want your team to see pending and rejected suggestions, but add `.claude-suggestions/.progress.json` to your `.gitignore`: it changes on every review and only makes sense on your machine.

## The reviewer

Each review runs `claude -p` in the project directory, with Claude Sonnet by default, on your own Claude account or API key, so it counts toward your usage. It's [limited on purpose](amber.lua#L252-L269).

To use another model, change the default on [this line of `amber.lua`](amber.lua#L15), for example to `"claude-haiku-4-5"`, then run **Disable Amber** and **Enable Amber** in Rex so it takes effect.

## Limitations

- Only idle panes are reviewed. Whatever was said after the last idle period, right before closing a pane, isn't.

## License

[MIT](LICENSE)
