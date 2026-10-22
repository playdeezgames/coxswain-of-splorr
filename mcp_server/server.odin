// Coxswain as an MCP server: JSON-RPC 2.0 messages in, replies out, with no I/O of its own except
// the task store (store.odin). The stdio loop lives in ../coxswain_mcp; everything here is testable by
// passing handle_message message text.
//
// Every session launches its own server process, so nothing is kept in memory between calls: each
// tool locks the on-disk store, loads it, changes it and saves it.
package mcp_server

import "core:encoding/json"
import "core:fmt"
import "core:strings"

SERVER_NAME :: "coxswain-of-splorr"
// "dev" unless built with -define:COXSWAIN_VERSION=<text>.
SERVER_VERSION :: #config(COXSWAIN_VERSION, "dev")

@(rodata)
PROTOCOL_VERSIONS := [?]string{"2025-06-18", "2025-03-26", "2024-11-05"}

ERR_PARSE :: -32700
ERR_INVALID_REQUEST :: -32600
ERR_METHOD_NOT_FOUND :: -32601
ERR_INVALID_PARAMS :: -32602

Server :: struct {
	dir:   string, // the folder holding the task store; owned
	agent: string, // this session's default agent name ("" = tools must be told); owned
	lock:  int, // the store lock this server holds while a tool runs (see lock_*.odin)
}

server_init :: proc(s: ^Server, dir, agent: string) {
	s^ = {}
	s.dir = strings.clone(dir)
	s.agent = strings.clone(agent)
}

server_destroy :: proc(s: ^Server) {
	delete(s.dir)
	delete(s.agent)
	s^ = {}
}

// The text and kind of a tool's answer, on the temp allocator.
Tool_Result :: struct {
	text:     string,
	is_error: bool,
}

Tool :: struct {
	name:        string,
	description: string,
	schema:      string, // the input schema, as JSON text
	run:         proc(s: ^Server, args: json.Object) -> Tool_Result,
}

ok_result :: proc(text: string) -> Tool_Result {
	return {text = text}
}

// A refusal: becomes an MCP isError result, never a crash.
fail :: proc(text: string) -> Tool_Result {
	return {text = text, is_error = true}
}

// --- Messages ----------------------------------------------------------------------------------

// Handles one JSON-RPC message (without its trailing newline). Returns the reply text, or ok = false
// when there is nothing to send (a notification). All text is on the temp allocator.
handle_message :: proc(s: ^Server, message: []u8) -> (reply: string, ok: bool) {
	value, perr := json.parse(message, .JSON, false, context.temp_allocator)
	if perr != .None {
		return error_reply("null", ERR_PARSE, "parse error"), true
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return error_reply("null", ERR_INVALID_REQUEST, "a request is a JSON object"), true
	}
	id_value, has_id := obj["id"]
	id := "null"
	if has_id {
		id = id_text(id_value)
	}
	method, has_method := obj["method"].(json.String)
	if !has_method {
		return has_id ? error_reply(id, ERR_INVALID_REQUEST, "no method") : "", has_id
	}
	if !has_id {
		return "", false // a notification, such as notifications/initialized
	}
	params, _ := obj["params"].(json.Object)
	switch method {
	case "initialize":
		return result_reply(id, initialize_result(params)), true
	case "ping":
		return result_reply(id, "{}"), true
	case "tools/list":
		return result_reply(id, tools_list_result()), true
	case "tools/call":
		return handle_tool_call(s, id, params)
	}
	return error_reply(id, ERR_METHOD_NOT_FOUND, fmt.tprintf("unknown method %s", method)), true
}

initialize_result :: proc(params: json.Object) -> string {
	version := PROTOCOL_VERSIONS[0]
	if asked, ok := params["protocolVersion"].(json.String); ok {
		for v in PROTOCOL_VERSIONS {
			if v == asked {
				version = v
			}
		}
	}
	return fmt.tprintf(
		`{{"protocolVersion":%s,"capabilities":{{"tools":{{}}}},"serverInfo":{{"name":%s,"version":%s}}}}`,
		quote(version),
		quote(SERVER_NAME),
		quote(SERVER_VERSION),
	)
}

tools_list_result :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"tools":[`)
	for tool, i in tools() {
		if i > 0 {
			strings.write_string(&b, ",")
		}
		fmt.sbprintf(&b, `{{"name":%s,"description":%s,"inputSchema":%s}}`, quote(tool.name), quote(tool.description), tool.schema)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

handle_tool_call :: proc(s: ^Server, id: string, params: json.Object) -> (reply: string, ok: bool) {
	name, has_name := params["name"].(json.String)
	if !has_name {
		return error_reply(id, ERR_INVALID_PARAMS, "a tool call needs a name"), true
	}
	args, _ := params["arguments"].(json.Object)
	for tool in tools() {
		if tool.name == name {
			res := tool.run(s, args)
			return result_reply(id, tool_result_json(res)), true
		}
	}
	return error_reply(id, ERR_INVALID_PARAMS, fmt.tprintf("unknown tool %s", name)), true
}

tool_result_json :: proc(r: Tool_Result) -> string {
	return fmt.tprintf(`{{"content":[{{"type":"text","text":%s}}],"isError":%v}}`, quote(r.text), r.is_error)
}

result_reply :: proc(id, result: string) -> string {
	return fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"result":%s}}`, id, result)
}

error_reply :: proc(id: string, code: int, message: string) -> string {
	return fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"error":{{"code":%d,"message":%s}}}}`, id, code, quote(message))
}

// A JSON string literal (quoted and escaped).
quote :: proc(text: string) -> string {
	out, _ := json.marshal(text, {}, context.temp_allocator)
	return string(out)
}

// A request id as it should be echoed: whole numbers print without a fraction.
id_text :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.Float:
		if f64(i64(x)) == f64(x) {
			return fmt.tprintf("%d", i64(x))
		}
	}
	return to_json(v)
}

to_json :: proc(v: json.Value) -> string {
	out, err := json.marshal(v, {}, context.temp_allocator)
	return err == nil ? string(out) : "null"
}

// --- Arguments ---------------------------------------------------------------------------------

arg_string :: proc(args: json.Object, key: string) -> (value: string, ok: bool) {
	value, ok = args[key].(json.String)
	return
}

arg_bool :: proc(args: json.Object, key: string) -> bool {
	value, _ := args[key].(json.Boolean)
	return bool(value)
}

arg_int :: proc(args: json.Object, key: string) -> (value: int, ok: bool) {
	return json_int(args[key])
}

// A whole number held in a JSON value.
json_int :: proc(v: json.Value) -> (value: int, ok: bool) {
	#partial switch x in v {
	case json.Integer:
		return int(x), true
	case json.Float:
		if f64(i64(x)) == f64(x) {
			return int(x), true
		}
	}
	return 0, false
}

// A required string argument, or the failure naming it.
need_string :: proc(args: json.Object, key: string) -> (value: string, res: Tool_Result, ok: bool) {
	v, has := arg_string(args, key)
	if !has {
		return "", fail(fmt.tprintf("%s is required (a string)", key)), false
	}
	return v, {}, true
}

// A required integer argument, or the failure naming it.
need_int :: proc(args: json.Object, key: string) -> (value: int, res: Tool_Result, ok: bool) {
	v, has := arg_int(args, key)
	if !has {
		return 0, fail(fmt.tprintf("%s is required (an integer)", key)), false
	}
	return v, {}, true
}

// Who is acting: the `agent` argument, else the server's --agent default.
acting_agent :: proc(s: ^Server, args: json.Object) -> (name: string, res: Tool_Result, ok: bool) {
	if a, has := arg_string(args, "agent"); has && a != "" {
		return a, {}, true
	}
	if s.agent != "" {
		return s.agent, {}, true
	}
	return "", fail("agent is required: pass it, or start the server with --agent <name>"), false
}

// --- Documentation -----------------------------------------------------------------------------

// The tool reference as Markdown, from the tool table itself (so it cannot drift): `coxswain_mcp
// --tools` prints it, and MCP_TOOLS.md is a copy that a test keeps in step.
tool_reference_markdown :: proc(allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "# Coxswain MCP tools\n\nGenerated by `coxswain_mcp --tools`; do not edit by hand.\n\n")
	for tool in tools() {
		fmt.sbprintf(&b, "## `%s`\n\n%s\n\nInput schema: `%s`\n\n", tool.name, tool.description, tool.schema)
	}
	return strings.to_string(b)
}
