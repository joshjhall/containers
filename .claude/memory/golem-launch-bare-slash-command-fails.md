---
name: golem-launch-bare-slash-command-fails
description: "golem-launch.sh passes bare /next-issue but plugin registers namespaced /workflow:next-issue; non-interactive launch prompt can't expand the prefix → \"Unknown command / unknown skill\", golem idles at empty prompt"
metadata:
  node_type: memory
  type: project
  originSessionId: 49200d0c-5fc2-4361-8381-0c9003b78835
---

`golem-launch.sh launch {N}` (workflow plugin, librarian 0.4.0) starts the
golem tmux session with an initial prompt of bare
`/next-issue {N} --autonomous` (and `; /ship-issue --autonomous`). But the
workflow plugin registers its skills **namespaced**: `/workflow:next-issue`,
`/workflow:ship-issue`. In an interactive session the bare `/next-issue` only
works because typing it opens an **autocomplete dropdown** that expands to
`/workflow:next-issue`. A launch prompt delivered non-interactively (via the
`claude "..."` positional arg or `tmux send-keys ... Enter`) gets **no
autocomplete expansion**, so the bare form doesn't resolve →
`● Unknown command: /next-issue` / `● Args from unknown skill: {N} --autonomous`,
and the golem falls idle at an empty `❯` prompt. Looks like a stall in
golem-status.sh ("possible stall — no progress for Nm").

**Why:** Two independent failure modes hit the 4-golem dispatch of #678/#576/#667/#592:

1. The workflow plugin was installed/refreshed (19:59) over an hour AFTER the
   golems launched (18:45), so at first launch the skill genuinely didn't exist.
2. Even after the plugin was present, the bare `/next-issue` still failed —
   the real bug is the missing `/workflow:` namespace.

**How to apply:** When launching golems (or writing the initial prompt), use the
**namespaced** command: `/workflow:next-issue {N} --autonomous` and
`/workflow:ship-issue --autonomous`. To recover a golem already idling on the
"Unknown command" error, `tmux send-keys -t golem-{N} "/workflow:next-issue {N}
--autonomous" Enter` into the live session. Note: recovering this way breaks the
shell `;`-chained `/ship-issue` backstop (there's no `;` when you send a single
command into a running REPL), so if `/next-issue` exits without shipping, send
`/workflow:ship-issue --autonomous` manually. Verify a fresh worktree session
resolves the command first with a throwaway probe session +
`tmux capture-pane`. Relates to [[golem-supervised-auto-mode]] and
[[golem-push-gate-under-auto]].
