# Coxswain as an MCP server

Coxswain is a project-management MCP server: Claude Code sessions and agents share one task store, claim work from it without colliding, and leave notes for each other. **Using it**: build once, then register the binary with any MCP client. `--dir` is the folder the shared store lives in; `--agent` is the default name of the session using this server.

```bash
./build.sh mcp                                                                  # build/coxswain_mcp
claude mcp add coxswain -- "$PWD/build/coxswain_mcp" --dir ~/coxswain-tasks --agent me   # Claude Code; other clients: command + args
build/coxswain_mcp --tools > MCP_TOOLS.md                                       # regenerate the tool reference (./build.sh docs)
```

Needs Odin (`dev-2026-07`); there is no other dependency. Run every `./build.sh` target from the repo root.

**Dev and prod.** `build/coxswain_mcp` is the development build, rebuilt freely. For other sessions use the installed "prod" copy, which a rebuild never touches:

```bash
./build.sh install-mcp        # builds with the git revision and replaces ~/.local/bin/coxswain_mcp by rename (running servers are unaffected)
claude mcp add --scope user coxswain -- ~/.local/bin/coxswain_mcp --dir ~/coxswain-tasks
~/.local/bin/coxswain_mcp --version
```

Run `install-mcp` again when a change should reach those sessions; they pick it up the next time they start (an MCP client launches the binary per session). `COXSWAIN_PREFIX` and `COXSWAIN_TASKS` change the two folders. Register the dev build under another name (`coxswain-dev`) with its own `--dir` to try changes without touching real tasks.

**Web view.** `./build.sh web` builds `build/coxswain_web`; `build/coxswain_web --dir ~/coxswain-tasks` serves a read-only page of projects, milestones, tasks and agents at http://127.0.0.1:8787/ (`--port` changes it). It never writes and listens on loopback only.

**Who is acting.** Every tool that needs an agent takes an `agent` argument, else falls back to the server's `--agent`. A server registered without `--agent` (one shared registration for many sessions) therefore needs `agent` on each call. Only a task's assignee may release or complete it, unless `force` is true.

The reference for every tool (name, what it does, input schema) is [MCP_TOOLS.md](MCP_TOOLS.md), generated from the code; a test fails if it is stale (`./build.sh docs` fixes that).

## What the tools are for

| Group | Tools | Use |
|---|---|---|
| Making tasks | `task_create`, `task_update`, `task_move`, `task_block`, `task_unblock` | A task has a title, description, priority (higher is more important), optional project and milestone, and `blocked_by` (ids that must be finished before it can be claimed). |
| Finding work | `task_next`, `task_list`, `task_search`, `task_get`, `task_history` | `task_next` shows the best claimable task (highest priority, then lowest id; with `claim` true it claims it atomically). `task_list` filters by status, assignee, project or milestone; `task_search` looks for text in titles, descriptions and notes. |
| Doing work | `task_claim`, `task_note`, `task_complete`, `task_release` | Claim before working, so two sessions never take the same task (the second is refused). Add notes for handoffs and findings. Complete with a note saying what was done, or release it if you are giving it up. |
| Changing course | `task_cancel`, `task_reopen` | Nothing is ever deleted. A cancelled task no longer blocks anything; reopen a done or cancelled task to bring it back. |
| Projects | `project_create/list/rename/delete`, `milestone_create/rename/set_done/delete` | Named groups (never numbered). A milestone belongs to one project. Deleting refuses while tasks are in it; renaming carries the tasks along. `project_list` shows task counts by status and each milestone's done flag. |
| Agents | `agent_register`, `agent_heartbeat`, `agent_list`, `task_release_stale`, `agent_unregister` | Say who is around and what they are doing. An agent is active when seen within `stale_after` seconds (default 300). `task_release_stale` gives back tasks held by an agent that went quiet (list first, then `release` true). |
| Releases | `ship_today`, `ship_schedule`, `ship_list`, `ship_reschedule`, `ship_update`, `ship_complete`, `ship_cancel` | The release schedule, with one rule: **at most one release a day**. Every release that is not cancelled holds a calendar day (local time), and no two hold the same one. Book with `ship_schedule` (no date = next free day; a taken day is refused with the next free one). Ask `ship_today` before publishing anything, and call `ship_complete` the moment it goes live: it refuses if today already has a release, and before the release's own day unless `force`. |

Limits keep the store small: titles 200, descriptions 10,000, notes 4,000 and `doing` lines 200 bytes; names 64; 10,000 tasks, 200 notes per task, 200 agents, 2,000 releases. A tool over a limit refuses and names it.

## A typical session

1. `agent_register` with a name and a `doing` line (once per session; other tools that name a registered agent also count as a heartbeat, so call `agent_heartbeat` during long stretches with no other call).
2. `task_next` for your project (add `claim` true to take it), or `task_list` and `task_claim`.
3. Work. Use `task_note` for anything another session should know: a finding, a decision, a question.
4. `task_complete` with a note, or `task_release` if you cannot finish. Create follow-ups with `task_create`, using `blocked_by` for ordering.
5. `agent_unregister` when the session ends, after releasing or completing what it holds.

A paste-in block for other repos' CLAUDE.md files that says this to a session is in [CLAUDE_SNIPPET.md](CLAUDE_SNIPPET.md).

## The store on disk

State is one JSON file, `tasks.json`, in the `--dir` folder, shared by every session. Each session runs its own server process, so nothing lives in memory between calls: a tool takes a lock, loads the file, runs, and saves only if it changed something. On Linux the lock is an exclusive `flock` on `tasks.flock` in that folder; the kernel drops it when its holder dies, so there are no stale locks. Other platforms use a `tasks.lock` directory with a 30 second stale cutoff. A tool waits up to 15 seconds for the lock, then refuses. Saves go through a temp file and a rename, so a reader never sees half a file.

`tasks.json` carries a `version`. A file without one is read as is; a newer version than the server knows is refused and left untouched, as is a file that is not valid JSON, so a person can look at it. Back it up like any other file you care about; it is plain text and diffs well.

`./build.sh race [procs] [tasks]` is the multi-process proof: N real server processes race to claim the same tasks, and each must be won exactly once.
