---
name: review-suggestions
description: Review the changes Amber suggests to this project's Claude Code instructions (CLAUDE.md files and skills), waiting in .claude-suggestions/. Apply the ones the user accepts and set aside the ones they reject. Use when the user runs /review-suggestions, asks to review Amber's or CLAUDE.md suggestions, or asks what Amber suggested.
---

# Review suggestions

Amber reviews this project's Claude Code sessions and leaves suggested changes in `.claude-suggestions/`, one file per suggestion: frontmatter with the target `file`, the `session` it came from and when it was `created`, then a summary heading, why, and a diff. The target is usually `.claude/CLAUDE.md`, but it can also be a folder's `CLAUDE.md` or a skill in `.claude/skills/`, and it may not exist yet.

The user decides what goes into their instructions. Never apply a suggestion they haven't accepted in this conversation.

## 1. Present

List `.claude-suggestions/*.md`, leaving out `rejected/` and the hidden files (`.progress.json`, `.observations.md`). If there are none, say there's nothing to review and stop.

Show every suggestion, oldest first, numbered:

- its summary
- the target file, and whether it's new
- why, as written in the file
- its diff in a `diff` block

If two suggestions overlap or contradict each other, say so next to them, so the user doesn't accept both.

Then ask which to apply: all, some by number, or none. The user can also ask to change one before applying it ("the 2nd, but say yarn"). Wait for the answer.

## 2. Apply the accepted ones

For each accepted suggestion:

1. Read the current target file. If it doesn't exist, create it, with its folders, from the diff's added lines.
2. Apply the diff exactly, or with the change the user asked for.
3. If the diff no longer matches because the file changed since, don't guess: show the change you would make now and apply it only after the user confirms.
4. Delete the suggestion file. Its change now lives in the target, and git keeps the history.

Don't rewrite or reorder anything else in the target.

## 3. Set aside the rejected ones

Move each rejected suggestion to `.claude-suggestions/rejected/`, creating the folder if needed. Amber reads that folder so it doesn't suggest the same thing again.

If the user said why they rejected it, append it to the file:

```markdown
## Rejected

<their reason, in their words>
```

The reason teaches Amber to avoid similar suggestions too, not just that exact one, so ask for one in a few words if they gave none, but don't insist.

Leave suggestions the user didn't decide on where they are.

## 4. Wrap up

Show the resulting diff of every changed file and say how many suggestions were applied, rejected, and left pending. Don't commit: the user does that.

Only touch the files the suggestions target and the suggestion files. Never edit `.progress.json` or `.observations.md`: they're Amber's own records.
