package mcp_server

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Runs one tool call through the JSON-RPC layer; returns the result text and isError.
call :: proc(s: ^Server, name, args_json: string) -> (text: string, is_error: bool) {
	msg := fmt.tprintf(`{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":%s,"arguments":%s}}}}`, quote(name), args_json)
	reply, ok := handle_message(s, transmute([]u8)msg)
	if !ok {
		return "no reply", true
	}
	v, _ := json.parse(transmute([]u8)reply, .JSON, false, context.temp_allocator)
	result := v.(json.Object)["result"].(json.Object)
	content := result["content"].(json.Array)[0].(json.Object)
	return content["text"].(json.String), bool(result["isError"].(json.Boolean))
}

temp_server :: proc(label, agent: string) -> Server {
	dir := fmt.tprintf("/tmp/coxswain_test_%d_%s", os.get_pid(), label)
	os.remove_all(dir)
	s: Server
	server_init(&s, dir, agent)
	return s
}

@(test)
test_initialize_and_list :: proc(t: ^testing.T) {
	s: Server
	server_init(&s, "", "")
	defer server_destroy(&s)
	reply, ok := handle_message(&s, transmute([]u8)string(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}`))
	testing.expect(t, ok && strings.contains(reply, `"protocolVersion":"2025-03-26"`))
	_, ok = handle_message(&s, transmute([]u8)string(`{"jsonrpc":"2.0","method":"notifications/initialized"}`))
	testing.expect(t, !ok, "notifications get no reply")
	reply, _ = handle_message(&s, transmute([]u8)string(`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`))
	testing.expect(t, strings.contains(reply, `"task_claim"`))
}

@(test)
test_claim_flow :: proc(t: ^testing.T) {
	s := temp_server("claim", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}

	text, bad := call(&s, "task_create", `{"title":"first"}`)
	testing.expect(t, !bad, text)
	_, bad = call(&s, "task_create", `{"title":"second","blocked_by":[1]}`)
	testing.expect(t, !bad)
	text, bad = call(&s, "task_create", `{"title":"x","blocked_by":[9]}`)
	testing.expect(t, bad, "unknown dependency is refused")

	text, bad = call(&s, "task_claim", `{"id":2}`)
	testing.expect(t, bad && strings.contains(text, "blocked by"), text)

	text, bad = call(&s, "task_claim", `{"id":1}`)
	testing.expect(t, !bad && strings.contains(text, `"assignee":"alice"`), text)
	text, bad = call(&s, "task_claim", `{"id":1,"agent":"bob"}`)
	testing.expect(t, bad && strings.contains(text, "already claimed by alice"), text)
	text, bad = call(&s, "task_complete", `{"id":1,"agent":"bob"}`)
	testing.expect(t, bad, "only the assignee completes")

	text, bad = call(&s, "task_complete", `{"id":1,"note":"done it"}`)
	testing.expect(t, !bad && strings.contains(text, `"status":"done"`) && strings.contains(text, "done it"), text)

	text, bad = call(&s, "task_claim", `{"id":2,"agent":"bob"}`)
	testing.expect(t, !bad, text)
	text, _ = call(&s, "task_list", `{"assignee":"bob"}`)
	testing.expect(t, strings.contains(text, `"title":"second"`) && !strings.contains(text, `"first"`), text)
}

@(test)
test_agent_required :: proc(t: ^testing.T) {
	s := temp_server("noagent", "")
	defer {os.remove_all(s.dir); server_destroy(&s)}
	call(&s, "task_create", `{"title":"a"}`)
	text, bad := call(&s, "task_claim", `{"id":1}`)
	testing.expect(t, bad && strings.contains(text, "agent is required"), text)
}

// MCP_TOOLS.md is generated; regenerate it with `./build.sh docs` after changing any tool.
@(test)
test_tool_docs_current :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("MCP_TOOLS.md", context.temp_allocator)
	testing.expect(t, err == nil, "MCP_TOOLS.md missing (run tests from the repo root)")
	testing.expect(t, string(data) == tool_reference_markdown(), "MCP_TOOLS.md is stale: run ./build.sh docs")
}

@(test)
test_agent_heartbeat :: proc(t: ^testing.T) {
	s := temp_server("heartbeat", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}

	text, bad := call(&s, "agent_heartbeat", `{}`)
	testing.expect(t, bad && strings.contains(text, "not registered"), text)

	text, bad = call(&s, "agent_register", `{"doing":"writing tests"}`)
	testing.expect(t, !bad && strings.contains(text, `"active":true`), text)
	call(&s, "task_create", `{"title":"a"}`)
	call(&s, "task_claim", `{"id":1}`)
	text, bad = call(&s, "agent_heartbeat", `{"doing":"still going"}`)
	testing.expect(t, !bad && strings.contains(text, "still going") && strings.contains(text, `"claimed":[1]`), text)

	// Make alice look old by rewriting her last_seen in the store.
	{
		testing.expect(t, store_lock(&s))
		st, _ := store_load(&s)
		st.agents[0].last_seen -= 1000
		store_save(&s, st)
		store_unlock(&s)
	}
	text, _ = call(&s, "agent_list", `{}`)
	testing.expect(t, strings.contains(text, `"active":false`), text)
	text, _ = call(&s, "agent_list", `{"stale_after":5000}`)
	testing.expect(t, strings.contains(text, `"active":true`), text)

	text, bad = call(&s, "agent_unregister", `{}`)
	testing.expect(t, !bad, text)
	text, _ = call(&s, "agent_list", `{}`)
	testing.expect(t, text == "[]", text)
}
