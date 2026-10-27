# CLAUDE.md snippet for sessions using Coxswain

Paste the block below into the `CLAUDE.md` of any repo whose sessions share tasks through the `coxswain` MCP server (see [MCP.md](MCP.md) for installing and registering it). Replace `<project>` with the project's name in the store and `<name>` with a name for the session; use a different `<name>` for each session working in parallel.

````markdown
## Tasks (coxswain MCP)

This repo's work is tracked as tasks in the shared `coxswain` store, project `<project>`.

- At the start of a session, call `agent_register` with agent `<name>` and a `doing` line. Pass `agent: "<name>"` on every coxswain call unless the server was registered with `--agent`.
- Find work with `task_next` (project `<project>`), or `task_list` and pick one. **Claim before working** (`task_claim`, or `task_next` with `claim` true); if the claim is refused, someone else has it: pick another task.
- While working, add a `task_note` for anything another session needs to know (a finding, a decision, a question). During long stretches with no coxswain calls, send `agent_heartbeat`.
- When done, `task_complete` with a note saying what changed and what was verified. If you cannot finish, `task_release` it with a note saying where you stopped. Never leave a claimed task you are no longer working on.
- Put follow-up work in `task_create` (project `<project>`, `blocked_by` for ordering) rather than doing it unasked. Do not touch tasks in other projects.
- **One release a day.** Before publishing anything to itch (or any public release), call `ship_today`: if `may_ship_now` is false, do not publish. Releases are booked with `ship_schedule` and recorded with `ship_complete` right when they go live; if that is refused, do not publish (or pull it down) and tell the user.
- At the end of a session, `agent_unregister`.
````
