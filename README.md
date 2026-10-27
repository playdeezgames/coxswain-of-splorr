# coxswain-of-splorr

A shared task board for AI coding sessions, delivered as an [MCP](https://modelcontextprotocol.io) server.

## What it is for

If you run more than one Claude Code session at a time (one per repo, or several agents on the same project), they cannot see each other. They duplicate work, trample the same task, forget what a previous session found, and lose the plan when a context window fills up.

Coxswain gives all of those sessions one shared place to keep the plan:

- **A task list that outlives any session.** Work is written down as tasks with a priority, dependencies, notes and a history, so a fresh session can pick up where the last one stopped.
- **Claims that cannot collide.** A session claims a task before working on it. If two sessions try to claim the same one at the same moment, exactly one wins and the other is told to pick something else.
- **Handoffs.** Sessions leave notes on tasks (a finding, a decision, a question) for whoever works on it next, human or agent.
- **Visibility.** Agents register and say what they are doing; a session that crashed or went quiet can have its claims released.
- **A release calendar.** If you publish things (games, packages, builds), the `ship_*` tools enforce at most one public release per calendar day across all your projects, and sessions are told to ask before publishing.

You, the human, stay the coordinator: you create or approve the tasks, and the sessions work through them. The name is the rowing term: the coxswain steers and calls the stroke, and doesn't pull an oar.

It is a small tool by design: one Odin binary with no dependencies, and all state in a single `tasks.json` you can read, diff, back up and edit by hand.

## How it fits together

```
Claude Code session A ──stdio──> coxswain_mcp ─┐
Claude Code session B ──stdio──> coxswain_mcp ─┼──> ~/coxswain-tasks/tasks.json
Another MCP client    ──stdio──> coxswain_mcp ─┘          ^
                                                          └── coxswain_web (optional, read-only)
```

Each session launches its own `coxswain_mcp` process, and they all point at the same folder with `--dir`. There is no daemon and no network service. A short-lived file lock makes every operation atomic, and nothing is kept in memory between calls.

## Setting it up

### 1. Build it

You need the [Odin](https://odin-lang.org) compiler, release `dev-2026-07` (the version CI uses). Linux is the supported platform; other platforms build, but use a weaker lock (see [MCP.md](MCP.md)).

```bash
git clone https://github.com/playdeezgames/coxswain-of-splorr.git
cd coxswain-of-splorr
./build.sh test        # optional: run the tests
./build.sh mcp         # builds build/coxswain_mcp
```

### 2. Pick where the tasks live

Choose one folder for the shared store, for example `~/coxswain-tasks`. It is created on first use. Every session that should share tasks must use the same folder. Keep it outside your project repos unless you want the task file under version control.

### 3. Register it with your MCP client

**Claude Code**, for one session name:

```bash
claude mcp add coxswain -- "$PWD/build/coxswain_mcp" --dir ~/coxswain-tasks --agent me
```

**Claude Code, for every session on the machine.** Install a stable copy, so rebuilding the repo never disturbs running sessions, and register that user-wide:

```bash
./build.sh install-mcp      # copies the binary to ~/.local/bin/coxswain_mcp
claude mcp add --scope user coxswain -- ~/.local/bin/coxswain_mcp --dir ~/coxswain-tasks
```

Without `--agent`, each session passes its own `agent` name on every call, which is what you want when one registration serves many sessions.

**Other MCP clients** that can launch a stdio server take the same command and arguments. In the common JSON form:

```json
{
  "mcpServers": {
    "coxswain": {
      "command": "/home/you/.local/bin/coxswain_mcp",
      "args": ["--dir", "/home/you/coxswain-tasks", "--agent", "me"]
    }
  }
}
```

Check the install with `coxswain_mcp --version`, and list the tools with `coxswain_mcp --tools`.

### 4. Tell your sessions how to use it

A registered server only gives a session the tools. To make sessions actually use them, paste [CLAUDE_SNIPPET.md](CLAUDE_SNIPPET.md) into the `CLAUDE.md` of each repo that should track its work here. It tells a session to register, claim before working, leave notes, and complete or release what it holds. Fill in the project name and give each parallel session its own name.

## A typical workflow

1. **Plan.** Ask a session to create a project, its milestones and tasks (`project_create`, `milestone_create`, `task_create`), or write the tasks yourself in conversation. Use `blocked_by` for ordering and `priority` for importance.
2. **Work.** Start a session in a repo. It registers, asks `task_next` for the best claimable task, claims it, does the work, and adds notes as it learns things.
3. **Finish or hand off.** It calls `task_complete` with a note saying what changed and what was verified, or `task_release` with a note saying where it stopped, and creates follow-up tasks for anything it found but didn't do.
4. **Run in parallel.** Start more sessions on other repos or on the same one. Each claims different tasks; a claim that loses the race is refused and the session picks another.
5. **Look in.** Ask any session to list tasks and agents, or open the web view (below).

If a session dies while holding a claim, `agent_list` shows it has gone quiet and `task_release_stale` gives its tasks back.

## Web view

An optional read-only page of projects, milestones, tasks and agents:

```bash
./build.sh web
build/coxswain_web --dir ~/coxswain-tasks --port 8787     # then open http://127.0.0.1:8787/
```

It listens on `127.0.0.1` only, answers `GET` only and never writes to the store.

## The store

All state is one file, `tasks.json`, in the `--dir` folder (plus a `tasks.flock` lock file). It is plain JSON with a format version: a newer version than the server knows, or a file that is not valid JSON, is refused and left untouched. Back it up like any file you care about.

Nothing is ever deleted. Tasks are cancelled or reopened, so ids and history stay stable. Field sizes and counts are capped, and a tool over a cap refuses and names the limit.

## Docs

- [MCP.md](MCP.md): building, registering (dev and prod builds), the tools by group, a typical session, the on-disk store.
- [MCP_TOOLS.md](MCP_TOOLS.md): every tool's description and input schema (generated by `./build.sh docs`).
- [CLAUDE_SNIPPET.md](CLAUDE_SNIPPET.md): the block for other repos' `CLAUDE.md`.
- [CLAUDE.md](CLAUDE.md): architecture notes for working on this repo.

## Development

```bash
./build.sh check     # type-check
./build.sh test      # unit tests
./build.sh race      # N real processes race to claim the same tasks
./build.sh docs      # regenerate MCP_TOOLS.md after changing any tool
```

CI runs check, test and race on every push and pull request. Forks are welcome: it has no dependencies beyond Odin.

## License

MIT, see [LICENSE](LICENSE).
