#!/usr/bin/env bash
# Usage: ./build.sh <target>
#   check       type-check every package
#   test        run every package's tests (from the repo root)
#   mcp         build/coxswain_mcp, the MCP server
#   docs        regenerate MCP_TOOLS.md from the tool table
#   install-mcp a stable copy in ~/.local/bin/coxswain_mcp for other sessions
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-test}" in
	check)  odin check mcp_server -no-entry-point; odin check coxswain_mcp ;;
	test)   odin test mcp_server ;;
	mcp)    mkdir -p build && odin build coxswain_mcp -out:build/coxswain_mcp ;;
	docs)   mkdir -p build && odin build coxswain_mcp -out:build/coxswain_mcp && build/coxswain_mcp --tools > MCP_TOOLS.md ;;
	install-mcp)
		bin="${COXSWAIN_PREFIX:-$HOME/.local/bin}"
		tasks="${COXSWAIN_TASKS:-$HOME/coxswain-tasks}"
		version="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
		mkdir -p build "$bin" "$tasks"
		odin build coxswain_mcp -out:build/coxswain_mcp-prod -define:COXSWAIN_VERSION="$version"
		cp build/coxswain_mcp-prod "$bin/.coxswain_mcp.new" && mv -f "$bin/.coxswain_mcp.new" "$bin/coxswain_mcp"
		echo "installed $bin/coxswain_mcp ($version); tasks in $tasks"
		echo "register it:  claude mcp add --scope user coxswain -- $bin/coxswain_mcp --dir $tasks --agent <name>" ;;
	*) echo "unknown target $1" >&2; exit 2 ;;
esac
