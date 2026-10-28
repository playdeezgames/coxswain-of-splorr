# Contributing

**Short version: please fork it.**

Coxswain is published so that you can take it and make your own thing to your own liking. It is built to the maintainer's own taste, and the maintainer is picky about what comes in. Pull requests and feature requests are not sought, will often be declined, and may go unanswered. That's not personal; it just isn't a collaborative project. Forking is the intended way to use it, and the [MIT license](LICENSE) is there to make that easy.

If you find a bug, you are welcome to open an issue, but there is no promise it will be looked at on any schedule. A fix in your own fork is always an option.

## Making it your own

The code is small and has no dependencies, which is meant to make it easy to bend. The notes below are for working in a fork.

You need the [Odin](https://odin-lang.org) compiler at the version in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) (`ODIN_VERSION`). Run everything from the repo root.

```bash
./build.sh check     # type-check the server, the stdio binary and the web view
./build.sh test      # unit tests
./build.sh race      # N real processes race to claim the same tasks; each must be won exactly once
./build.sh mcp       # build/coxswain_mcp
```

Run one test: `odin test mcp_server -define:ODIN_TEST_NAMES=mcp_server.test_claim_flow`.

[CLAUDE.md](CLAUDE.md) describes the architecture: `mcp_server/` is the library (tools, store, locking), `coxswain_mcp/` is the stdio loop, `coxswain_web/` is the read-only web view, and tools are rows in a table, one `*_tools()` proc per file.

Things that are easy to trip over when you change it:

- **Tools:** a refusal is `fail(text)`, never a crash. After adding or changing a tool run `./build.sh docs` to regenerate `MCP_TOOLS.md`, or `test_tool_docs_current` fails.
- **The on-disk format:** if an older server would misread the file, bump `STORE_VERSION` in `mcp_server/store.odin` and migrate in `store_load`. Newer files must stay refused, never rewritten.
- **Odin version:** keep `ODIN_VERSION` in `ci.yml` and the mentions in `README.md`, `MCP.md` and `CLAUDE.md` equal.
- **Locking and claims:** run `./build.sh race` after touching them; it is the real proof that a task is won exactly once.

Rename the server (`SERVER_NAME` in `mcp_server/server.odin`) if your fork should sit beside the original in an MCP client.
