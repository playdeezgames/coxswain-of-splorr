# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`coxswain-of-splorr` is a project-management MCP (Model Context Protocol) server for coordinating tasks between Claude Code sessions and agents.

## Commands

Odin `dev-2026-07`; there is no MCP library, so the JSON-RPC layer is hand-written. Run everything from the repo root (a test reads `MCP_TOOLS.md` by relative path).

```bash
./build.sh check         # type-check mcp_server and coxswain_mcp
./build.sh test          # odin test mcp_server
./build.sh mcp           # build/coxswain_mcp (dev build)
./build.sh race [procs] [tasks]   # multi-process claim test (scripts/race.sh): N real server processes race to claim the same tasks; each must be won exactly once
./build.sh docs          # regenerate MCP_TOOLS.md; do this after changing any tool, or test_tool_docs_current fails
./build.sh install-mcp   # stable copy in ~/.local/bin/coxswain_mcp (tasks in ~/coxswain-tasks) so rebuilds don't disturb other sessions
odin test mcp_server -define:ODIN_TEST_NAMES=mcp_server.test_claim_flow   # one test
```

Run the server: `build/coxswain_mcp --dir <task folder> --agent <name>` (also `--tools`, `--version`).

## Architecture

Modelled on the sibling repo `/home/yermom/git/anvil-of-splorr` (`mcp_server/`, `anvil_mcp/`, `MCP.md`).
- `mcp_server/` is a library with no I/O of its own besides the store: `handle_message(&server, bytes) -> (reply, ok)` takes one JSON-RPC 2.0 line (notifications give `ok = false`). Tests call it through the `call` helper in `server_test.odin`.
- `coxswain_mcp/main.odin` is only the stdio loop: one message per line, replies on stdout, logs on stderr.
- Tools are a table of `{name, description, schema text, run}`, one `*_tools()` proc per file, joined once (thread-safely) by `tools()` in `tools.odin`. A refusal is `fail(text)` (MCP `isError`), never a crash. `MCP_TOOLS.md` is generated from the table.
- State is shared between sessions, and each session runs its own server process, so nothing lives in memory between calls. `with_store` (`tools.odin`) takes the lock, loads `tasks.json`, runs the tool body, and saves only if the body asks. On Linux the lock is an exclusive `flock` on `tasks.flock` (`lock_linux.odin`): the kernel drops it when its holder dies, so there are no stale locks and no stealing. Waiters retry with jitter for up to 15 s. Other platforms fall back to a `tasks.lock` directory with a 30 s stale cutoff (`lock_other.odin`), whose stale steal is not race-free. Saves go through a temp file and a rename. `tasks.json` carries a `version` (`STORE_VERSION` in `store.odin`): a file without one is version 0 and is read as is; a newer or negative one is refused untouched. Version 2 added task priority, 4 the `cancelled` status (tools in `tools_lifecycle.odin`: `task_block/unblock/cancel/reopen`; nothing is ever deleted, and a cancelled task no longer blocks), 3 5 the milestone `done` flag, 3 the per-task history log (`record` in `tools_tasks.odin`; every mutating task tool calls it on success). Bump it and migrate in `store_load` when the format changes incompatibly. Claims are therefore atomic: of two agents claiming one task, the second is refused.
- Size caps (`limits.odin`): title 200, description 10,000, note 4,000, doing 200, agent name 64 bytes; 10,000 tasks, 200 notes per task, 200 agents. Over a cap a tool refuses (`too_long`, `check_note`) and never truncates; names of projects and milestones use `MAX_NAME`. The system-written stale-release note is exempt.
- Agent identity: a tool's `agent` argument, else the server's `--agent` flag (`acting_agent` in `server.odin`). Only a task's assignee may release or complete it, unless `force` is true.
- Task model (`store.odin`): `id`, `title`, `description`, `status` (open, claimed, done), `assignee`, `blocked_by` (ids; a task is not claimable while one is unfinished) and `notes`. Tools are in `tools_tasks.odin`: `task_create/list/get/update/claim/release/complete/note/next/history` (`task_update` edits title/description only, by anyone).
- Projects and milestones (`Store.projects/milestones`, `tools_projects.odin`): both are identified by name (unique; a milestone's name is unique within its project), never by number. A task has optional `project` and `milestone` strings; a milestone requires a project, and `check_placement` (`tools_tasks.odin`) validates both on `task_create` and `task_move`. `project_delete` and `milestone_delete` refuse while tasks are still in them rather than orphaning or cascading. Tools: `project_create/list/rename/delete`, `milestone_create/rename/delete`, `milestone_set_done` (a flag you set, shown by `project_list`; it does not touch tasks), `task_move`; a rename rewrites every task and milestone that used the old name and logs a `moved` event on each task; `task_list` filters by `project`/`milestone`; `task_search` finds text in titles, descriptions and notes (case-insensitive).
- Release schedule (`Store.ships`, `tools_ships.odin`, store version 6): `ship_today/schedule/list/reschedule/complete/cancel`. The rule is one release per calendar day: every non-cancelled ship holds one local day (`date`, YYYY-MM-DD), enforced by `day_holder` on schedule, reschedule and complete; completing sets the date to today, and `force` only waives "before its day", never the one-a-day rule. `Server.today` overrides the clock in tests.
- Agent registry (`Store.agents`, `tools_agents.odin`): `agent_register/heartbeat/list/unregister`. An agent is `name`, `doing`, `last_seen` (unix seconds). `agent_list` marks an agent `active` when seen within `stale_after` seconds (default 300) and shows the tasks it has claimed. Heartbeats are explicit; other tools do not refresh `last_seen`. Tests that share a process need distinct store folders (`temp_server(label, agent)`), since they run in parallel.
- Odin gotchas hit here: store data is on the temp allocator (freed per message by the stdio loop), and the `tools()` table allocates with the default allocator on purpose, so a test's tracking allocator doesn't free it under other tests.
- CI (`.github/workflows/ci.yml`): on every push and pull request it installs the pinned Odin release (`ODIN_VERSION`, keep it equal to the version in Commands above) and runs `./build.sh check`, `test` and `race`. Usage docs for people are `MCP.md`; `CLAUDE_SNIPPET.md` is the block other repos paste into their CLAUDE.md.
