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
- State is shared between sessions, and each session runs its own server process, so nothing lives in memory between calls. `with_store` (`tools.odin`) takes the lock, loads `tasks.json`, runs the tool body, and saves only if the body asks. On Linux the lock is an exclusive `flock` on `tasks.flock` (`lock_linux.odin`): the kernel drops it when its holder dies, so there are no stale locks and no stealing. Waiters retry with jitter for up to 15 s. Other platforms fall back to a `tasks.lock` directory with a 30 s stale cutoff (`lock_other.odin`), whose stale steal is not race-free. Saves go through a temp file and a rename. Claims are therefore atomic: of two agents claiming one task, the second is refused.
- Agent identity: a tool's `agent` argument, else the server's `--agent` flag (`acting_agent` in `server.odin`). Only a task's assignee may release or complete it, unless `force` is true.
- Task model (`store.odin`): `id`, `title`, `description`, `status` (open, claimed, done), `assignee`, `blocked_by` (ids; a task is not claimable while one is unfinished) and `notes`. Tools are in `tools_tasks.odin`: `task_create/list/get/update/claim/release/complete/note` (`task_update` edits title/description only, by anyone).
- Projects and milestones (`Store.projects/milestones`, `tools_projects.odin`): both are identified by name (unique; a milestone's name is unique within its project), never by number. A task has optional `project` and `milestone` strings; a milestone requires a project, and `check_placement` (`tools_tasks.odin`) validates both on `task_create` and `task_move`. `project_delete` and `milestone_delete` refuse while tasks are still in them rather than orphaning or cascading. Tools: `project_create/list/delete`, `milestone_create/delete`, `task_move`; `task_list` filters by `project`/`milestone`.
- Agent registry (`Store.agents`, `tools_agents.odin`): `agent_register/heartbeat/list/unregister`. An agent is `name`, `doing`, `last_seen` (unix seconds). `agent_list` marks an agent `active` when seen within `stale_after` seconds (default 300) and shows the tasks it has claimed. Heartbeats are explicit; other tools do not refresh `last_seen`. Tests that share a process need distinct store folders (`temp_server(label, agent)`), since they run in parallel.
- Odin gotchas hit here: store data is on the temp allocator (freed per message by the stdio loop), and the `tools()` table allocates with the default allocator on purpose, so a test's tracking allocator doesn't free it under other tests.
