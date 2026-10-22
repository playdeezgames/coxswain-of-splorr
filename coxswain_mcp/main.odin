// Runs Coxswain as an MCP server over stdio: one JSON-RPC message per line on stdin, one reply per
// line on stdout (diagnostics go to stderr). Usage:
//
//     coxswain_mcp [--dir <folder>] [--agent <name>] | --tools | --version
//
// --dir is the folder holding the shared task store (default: the working directory); --agent is this
// session's default name when a tool call does not give one.
//
//     claude mcp add coxswain -- ./build/coxswain_mcp --dir ~/coxswain-tasks --agent <name>
package main

import mcp "../mcp_server"
import "core:bufio"
import "core:fmt"
import "core:os"

// The longest message accepted (one line).
MAX_MESSAGE :: 4 << 20

main :: proc() {
	dir, agent := "", ""
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "--version":
			fmt.println(mcp.SERVER_VERSION)
			return
		case args[i] == "--tools":
			fmt.print(mcp.tool_reference_markdown())
			return
		case args[i] == "--dir" && i + 1 < len(args):
			dir = args[i + 1]
			i += 1
		case args[i] == "--agent" && i + 1 < len(args):
			agent = args[i + 1]
			i += 1
		case:
			fmt.eprintfln("usage: coxswain_mcp [--dir <folder>] [--agent <name>] | --tools | --version")
			os.exit(2)
		}
	}
	server: mcp.Server
	mcp.server_init(&server, dir, agent)

	reader: bufio.Reader
	bufio.reader_init_with_buf(&reader, os.to_stream(os.stdin), make([]u8, MAX_MESSAGE))
	for {
		line, err := bufio.reader_read_slice(&reader, '\n')
		if len(line) > 0 {
			if reply, ok := mcp.handle_message(&server, line); ok {
				fmt.println(reply)
			}
			free_all(context.temp_allocator)
		}
		if err != nil {
			if err == .Buffer_Full {
				fmt.eprintfln("message longer than %d bytes", MAX_MESSAGE)
			}
			break
		}
	}
	mcp.server_destroy(&server)
}
