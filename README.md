# coxswain-of-splorr

A small project-management [MCP](https://modelcontextprotocol.io) server for coordinating work between Claude Code sessions and other agents. Many sessions share one task store; they claim tasks without colliding, leave notes for each other, and keep a release calendar with a one-release-a-day rule.

- **Tasks**: priorities, projects and milestones, dependencies (`blocked_by`), notes, history, search. Nothing is ever deleted; tasks are cancelled or reopened.
- **Claims are atomic**: of two agents claiming the same task, the second is refused (an exclusive file lock on Linux; see [MCP.md](MCP.md)).
- **Agents**: register, heartbeat, and release claims held by agents that went quiet.
- **Releases**: `ship_*` tools enforce at most one public release per calendar day.
- **No dependencies**: written in [Odin](https://odin-lang.org) with a hand-written JSON-RPC layer. State is a single `tasks.json`.
- **`coxswain_web`**: an optional read-only web view of the store, listening on `127.0.0.1` only.

## Quickstart

You need the Odin compiler, release `dev-2026-07` (the version CI uses). Linux is the supported platform; other platforms build but use a weaker lock (see [MCP.md](MCP.md)).

```bash
git clone https://github.com/playdeezgames/coxswain-of-splorr.git
cd coxswain-of-splorr
./build.sh test                      # run the tests
./build.sh mcp                       # build/coxswain_mcp
claude mcp add coxswain -- "$PWD/build/coxswain_mcp" --dir ~/coxswain-tasks --agent me
```

`--dir` is the folder the shared store lives in (created on first use); `--agent` is the default name of the session. Any MCP client that can launch a stdio server works, not just Claude Code.

To let your sessions use it, paste [CLAUDE_SNIPPET.md](CLAUDE_SNIPPET.md) into the CLAUDE.md of each repo that should track its work here.

## Web view

```bash
./build.sh web
build/coxswain_web --dir ~/coxswain-tasks --port 8787    # then open http://127.0.0.1:8787/
```

It shows projects, milestones, tasks and agents, never writes, and refuses anything but `GET`.

## Docs

- [MCP.md](MCP.md): building, registering (dev and prod builds), the tools by group, a typical session, the on-disk store.
- [MCP_TOOLS.md](MCP_TOOLS.md): every tool's description and input schema (generated; `./build.sh docs`).
- [CLAUDE_SNIPPET.md](CLAUDE_SNIPPET.md): the block for other repos' CLAUDE.md.
- [CLAUDE.md](CLAUDE.md): architecture notes for working on this repo.

## Development

```bash
./build.sh check     # type-check
./build.sh test      # unit tests
./build.sh race      # N real processes race to claim the same tasks
./build.sh docs      # regenerate MCP_TOOLS.md after changing any tool
```

CI runs check, test and race on every push and pull request.

## License

MIT, see [LICENSE](LICENSE).
