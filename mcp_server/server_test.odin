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

@(test)
test_projects_and_milestones :: proc(t: ^testing.T) {
	s := temp_server("projects", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}

	text, bad := call(&s, "task_create", `{"title":"x","project":"nope"}`)
	testing.expect(t, bad && strings.contains(text, "no project nope"), text)

	_, bad = call(&s, "project_create", `{"name":"web"}`)
	testing.expect(t, !bad)
	text, bad = call(&s, "project_create", `{"name":"web"}`)
	testing.expect(t, bad && strings.contains(text, "already exists"), text)
	text, bad = call(&s, "milestone_create", `{"project":"nope","name":"m1"}`)
	testing.expect(t, bad, text)
	_, bad = call(&s, "milestone_create", `{"project":"web","name":"m1"}`)
	testing.expect(t, !bad)
	_, bad = call(&s, "milestone_create", `{"project":"web","name":"m2"}`)
	testing.expect(t, !bad)
	text, bad = call(&s, "milestone_create", `{"project":"web","name":"m1"}`)
	testing.expect(t, bad, "duplicate milestone in a project is refused")

	text, bad = call(&s, "task_create", `{"title":"a","project":"web","milestone":"m1"}`)
	testing.expect(t, !bad && strings.contains(text, `"milestone":"m1"`), text)
	text, bad = call(&s, "task_create", `{"title":"b","milestone":"m1"}`)
	testing.expect(t, bad && strings.contains(text, "needs a project"), text)
	text, bad = call(&s, "task_create", `{"title":"c","project":"web","milestone":"zzz"}`)
	testing.expect(t, bad && strings.contains(text, "no milestone zzz"), text)
	call(&s, "task_create", `{"title":"loose"}`)

	text, _ = call(&s, "task_list", `{"project":"web"}`)
	testing.expect(t, strings.contains(text, `"title":"a"`) && !strings.contains(text, "loose"), text)
	text, bad = call(&s, "task_list", `{"milestone":"m1"}`)
	testing.expect(t, bad, "milestone filter needs a project")

	// Moving: only milestone keeps the project; a new project clears the milestone.
	text, bad = call(&s, "task_move", `{"id":1,"milestone":"m2"}`)
	testing.expect(t, !bad && strings.contains(text, `"milestone":"m2"`), text)
	text, bad = call(&s, "task_move", `{"id":2,"project":"web","milestone":"m1"}`)
	testing.expect(t, !bad && strings.contains(text, `"project":"web"`), text)
	text, bad = call(&s, "task_move", `{"id":2,"milestone":""}`)
	testing.expect(t, !bad && strings.contains(text, `"milestone":""`) && strings.contains(text, `"project":"web"`), text)
	call(&s, "project_create", `{"name":"other"}`)
	text, bad = call(&s, "task_move", `{"id":1,"project":"other"}`)
	testing.expect(t, !bad && strings.contains(text, `"milestone":""`), text)
	text, bad = call(&s, "task_move", `{"id":1,"project":""}`)
	testing.expect(t, !bad && strings.contains(text, `"project":""`), text)

	text, _ = call(&s, "project_list", `{}`)
	testing.expect(t, strings.contains(text, `"name":"web"`) && strings.contains(text, `"open":1`), text)

	text, bad = call(&s, "milestone_create", `{"project":"web","name":"m3"}`)
	call(&s, "task_move", `{"id":1,"project":"web","milestone":"m3"}`)
	text, bad = call(&s, "milestone_delete", `{"project":"web","name":"m3"}`)
	testing.expect(t, bad && strings.contains(text, "still has 1"), text)
	text, bad = call(&s, "project_delete", `{"name":"web"}`)
	testing.expect(t, bad && strings.contains(text, "still has"), text)
	call(&s, "task_move", `{"id":1,"project":""}`)
	call(&s, "task_move", `{"id":2,"project":""}`)
	_, bad = call(&s, "project_delete", `{"name":"web"}`)
	testing.expect(t, !bad)
	text, _ = call(&s, "project_list", `{}`)
	testing.expect(t, !strings.contains(text, "m1"), "milestones go with their project")
}

@(test)
test_task_update :: proc(t: ^testing.T) {
	s := temp_server("update", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}
	call(&s, "task_create", `{"title":"old","description":"old text"}`)

	text, bad := call(&s, "task_update", `{"id":1}`)
	testing.expect(t, bad, "needs something to change")
	text, bad = call(&s, "task_update", `{"id":1,"title":"  "}`)
	testing.expect(t, bad && strings.contains(text, "title is empty"), text)
	text, bad = call(&s, "task_update", `{"id":9,"title":"x"}`)
	testing.expect(t, bad && strings.contains(text, "no task 9"), text)

	text, bad = call(&s, "task_update", `{"id":1,"title":"new"}`)
	testing.expect(t, !bad && strings.contains(text, `"title":"new"`) && strings.contains(text, "old text"), text)
	text, bad = call(&s, "task_update", `{"id":1,"description":""}`)
	testing.expect(t, !bad && strings.contains(text, `"title":"new"`) && strings.contains(text, `"description":""`), text)
}

// A lock file left by a crashed process must not block anyone: the kernel drops the flock with the
// process, so there is nothing stale to clean up.
@(test)
test_leftover_lock_files_do_not_block :: proc(t: ^testing.T) {
	s := temp_server("leftover", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}
	os.make_directory_all(s.dir)
	_ = os.write_entire_file(fmt.tprintf("%s/tasks.flock", s.dir), []u8{})
	os.make_directory(fmt.tprintf("%s/tasks.lock", s.dir)) // the old scheme's leftover
	text, bad := call(&s, "task_create", `{"title":"a"}`)
	testing.expect(t, !bad, text)
	text, bad = call(&s, "task_create", `{"title":"b"}`)
	testing.expect(t, !bad, "the lock is released after each call")
}

// Every way tasks.json can be unusable must give a refusal naming the file, from reads and writes
// alike, and must leave the file exactly as it was.
@(test)
test_corrupt_store_is_refused_and_kept :: proc(t: ^testing.T) {
	s := temp_server("corrupt", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}
	os.make_directory_all(s.dir)
	path := fmt.tprintf("%s/tasks.json", s.dir)

	bad_files := [?]string {
		"",                                         // empty
		"   \n",                                    // blank
		`{"next_id": 3, "tasks": [{"id": 1, "ti`,   // truncated
		"not json at all",
		`[1, 2, 3]`,                                // valid JSON, wrong shape
		`{"next_id": "three", "tasks": []}`,        // wrong field type
		`{"next_id": 2, "tasks": [{"id": "x"}]}`,   // wrong type inside a task
		"\x00\x01\x02\xff",                         // binary
		`{"version": 999, "next_id": 2, "tasks": []}`, // from a newer server
		`{"version": -1, "next_id": 2, "tasks": []}`,
	}
	for content in bad_files {
		testing.expectf(t, os.write_entire_file(path, transmute([]u8)content) == nil, "could not write the fixture")
		for tool_call in ([?][2]string{{"task_list", `{}`}, {"task_create", `{"title":"x"}`}, {"project_create", `{"name":"p"}`}, {"agent_register", `{}`}}) {
			text, bad := call(&s, tool_call[0], tool_call[1])
			testing.expectf(t, bad && strings.contains(text, path) && strings.contains(text, "untouched"), "%q: %s -> %s", content, tool_call[0], text)
		}
		after, err := os.read_entire_file(path, context.temp_allocator)
		testing.expectf(t, err == nil && string(after) == content, "%q was modified", content)
	}

	// No temp files are left behind by the refusals.
	infos, _ := os.read_all_directory_by_path(s.dir, context.temp_allocator)
	for info in infos {
		testing.expectf(t, !strings.has_suffix(info.name, ".tmp"), "left a temp file %s", info.name)
	}

	// Once a person fixes the file, the server works with it again.
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string(`{"next_id":5,"tasks":[]}`)) == nil)
	text, bad := call(&s, "task_create", `{"title":"after repair"}`)
	testing.expect(t, !bad && strings.contains(text, `"id":5`), text)
}

@(test)
test_unreadable_store_is_refused :: proc(t: ^testing.T) {
	s := temp_server("unreadable", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}
	call(&s, "task_create", `{"title":"a"}`)
	path := fmt.tprintf("%s/tasks.json", s.dir)
	testing.expect(t, os.chmod(path, {}) == nil)
	text, bad := call(&s, "task_list", `{}`)
	os.chmod(path, {.Read_User, .Write_User})
	testing.expect(t, bad && strings.contains(text, "could not be read"), text)
	text, bad = call(&s, "task_list", `{}`)
	testing.expect(t, !bad, text)
}

@(test)
test_task_next :: proc(t: ^testing.T) {
	s := temp_server("next", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}

	text, bad := call(&s, "task_next", `{}`)
	testing.expect(t, !bad && strings.contains(text, "no claimable"), text)

	call(&s, "project_create", `{"name":"p"}`)
	call(&s, "task_create", `{"title":"first"}`)
	call(&s, "task_create", `{"title":"second","blocked_by":[1]}`)
	call(&s, "task_create", `{"title":"third","project":"p"}`)

	text, _ = call(&s, "task_next", `{}`)
	testing.expect(t, strings.contains(text, `"title":"first"`), text)
	text, _ = call(&s, "task_next", `{}`)
	testing.expect(t, strings.contains(text, `"status":"open"`), "peeking does not claim")
	text, _ = call(&s, "task_next", `{"project":"p"}`)
	testing.expect(t, strings.contains(text, `"title":"third"`), text)
	text, bad = call(&s, "task_next", `{"milestone":"m"}`)
	testing.expect(t, bad, "milestone needs project")

	text, bad = call(&s, "task_next", `{"claim":true}`)
	testing.expect(t, !bad && strings.contains(text, `"title":"first"`) && strings.contains(text, `"assignee":"alice"`), text)
	text, _ = call(&s, "task_next", `{"claim":true,"agent":"bob"}`)
	testing.expect(t, strings.contains(text, `"title":"third"`) && strings.contains(text, `"assignee":"bob"`), "second is still blocked by the claimed first")
	text, _ = call(&s, "task_next", `{}`)
	testing.expect(t, strings.contains(text, "no claimable"), text)
}

// Any successful task tool that names a registered agent counts as a heartbeat; nothing registers one.
@(test)
test_task_calls_refresh_last_seen :: proc(t: ^testing.T) {
	s := temp_server("refresh", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}

	call(&s, "task_create", `{"title":"a"}`)
	call(&s, "task_create", `{"title":"b"}`)
	call(&s, "task_claim", `{"id":1}`)
	text, _ := call(&s, "agent_list", `{}`)
	testing.expect(t, text == "[]", "claiming does not register an agent")

	call(&s, "agent_register", `{}`)
	age_alice :: proc(s: ^Server) {
		testing.expect(nil, store_lock(s))
		st, _ := store_load(s)
		st.agents[0].last_seen -= 1000
		store_save(s, st)
		store_unlock(s)
	}
	fresh :: proc(s: ^Server) -> bool {
		text, _ := call(s, "agent_list", `{}`)
		return strings.contains(text, `"active":true`)
	}

	calls := [?]struct {
		tool, args: string,
	}{
		{"task_note", `{"id":1,"text":"hi"}`},
		{"task_update", `{"id":1,"title":"a2"}`},
		{"task_release", `{"id":1}`},
		{"task_claim", `{"id":1}`},
		{"task_complete", `{"id":1}`},
		{"task_next", `{"claim":true}`},
	}
	for c in calls {
		age_alice(&s)
		testing.expect(t, !fresh(&s), c.tool)
		_, bad := call(&s, c.tool, c.args)
		testing.expect(t, !bad, c.tool)
		testing.expect(t, fresh(&s), c.tool)
	}

	// A refused call does not count, and someone else's call does not touch alice.
	age_alice(&s)
	_, bad := call(&s, "task_claim", `{"id":2,"agent":"bob"}`)
	testing.expect(t, !fresh(&s), "bob's claim leaves alice alone")
	_, bad = call(&s, "task_claim", `{"id":2}`)
	testing.expect(t, bad && !fresh(&s), "a refused claim is not a heartbeat")
}

@(test)
test_release_stale :: proc(t: ^testing.T) {
	s := temp_server("stale", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}

	for title in ([?]string{"a", "b", "c", "d"}) {
		call(&s, "task_create", fmt.tprintf(`{{"title":"%s"}}`, title))
	}
	call(&s, "agent_register", `{}`)
	call(&s, "agent_register", `{"agent":"bob"}`)
	call(&s, "task_claim", `{"id":1}`)
	call(&s, "task_claim", `{"id":2,"agent":"bob"}`)
	call(&s, "task_claim", `{"id":3,"agent":"ghost"}`) // never registered
	{
		testing.expect(t, store_lock(&s))
		st, _ := store_load(&s)
		st.agents[1].last_seen -= 1000 // bob is stale, alice is not
		store_save(&s, st)
		store_unlock(&s)
	}

	text, bad := call(&s, "task_release_stale", `{}`)
	testing.expect(t, !bad && strings.contains(text, `"released":false`) && strings.contains(text, `"id":2`) && !strings.contains(text, `"id":1`), text)
	testing.expect(t, strings.contains(text, `"unregistered":[3]`), text)
	text, _ = call(&s, "task_get", `{"id":2}`)
	testing.expect(t, strings.contains(text, `"status":"claimed"`), "listing does not release")

	text, bad = call(&s, "task_release_stale", `{"stale_after":-1}`)
	testing.expect(t, bad, text)

	text, bad = call(&s, "task_release_stale", `{"release":true}`)
	testing.expect(t, !bad && strings.contains(text, `"released":true`), text)
	text, _ = call(&s, "task_get", `{"id":2}`)
	testing.expect(t, strings.contains(text, `"status":"open"`) && strings.contains(text, "released: bob"), text)
	text, _ = call(&s, "task_get", `{"id":1}`)
	testing.expect(t, strings.contains(text, `"status":"claimed"`), "alice is fresh")
	text, _ = call(&s, "task_get", `{"id":3}`)
	testing.expect(t, strings.contains(text, `"status":"claimed"`), "unregistered claims stay")

	text, _ = call(&s, "task_release_stale", `{"release":true}`)
	testing.expect(t, strings.contains(text, `"stale":[]`), text)
}

@(test)
test_store_version :: proc(t: ^testing.T) {
	s := temp_server("version", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}
	os.make_directory_all(s.dir)
	path := fmt.tprintf("%s/tasks.json", s.dir)
	read :: proc(path: string) -> string {
		data, _ := os.read_entire_file(path, context.temp_allocator)
		return string(data)
	}
	has_version :: proc(text: string) -> bool {
		return strings.contains(text, fmt.tprintf(`"version": %d`, STORE_VERSION))
	}

	// A new store is written with the current version.
	call(&s, "task_create", `{"title":"a"}`)
	testing.expect(t, has_version(read(path)), read(path))

	// A file from before versions existed is read as it is, and reading alone leaves it alone.
	old := `{"next_id":3,"tasks":[{"id":2,"title":"old","status":"Open"}]}`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)old) == nil)
	text, bad := call(&s, "task_list", `{}`)
	testing.expect(t, !bad && strings.contains(text, `"title":"old"`), text)
	testing.expect(t, read(path) == old, "a read must not rewrite the file")

	// The next write stamps the current version and keeps the data.
	text, bad = call(&s, "task_create", `{"title":"new"}`)
	testing.expect(t, !bad && strings.contains(text, `"id":3`), text)
	testing.expect(t, has_version(read(path)) && strings.contains(read(path), "old"), read(path))

	// A newer file is refused with both versions named.
	newer := `{"version":999,"next_id":2,"tasks":[]}`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)newer) == nil)
	text, bad = call(&s, "task_create", `{"title":"x"}`)
	testing.expect(t, bad && strings.contains(text, "version 999") && strings.contains(text, fmt.tprintf("up to %d", STORE_VERSION)), text)
	testing.expect(t, read(path) == newer, "a newer file is left alone")
}

@(test)
test_priority :: proc(t: ^testing.T) {
	s := temp_server("priority", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}

	text, bad := call(&s, "task_create", `{"title":"a"}`)
	testing.expect(t, !bad && strings.contains(text, `"priority":0`), text)
	call(&s, "task_create", `{"title":"b","priority":5}`)
	call(&s, "task_create", `{"title":"c","priority":5}`)
	call(&s, "task_create", `{"title":"d","priority":9,"blocked_by":[1]}`)
	_, bad = call(&s, "task_create", `{"title":"x","priority":"high"}`)
	testing.expect(t, bad, "priority is an integer")

	// Highest first, then lowest id; the list defaults to id order.
	text, _ = call(&s, "task_list", `{"sort":"priority"}`)
	ia, ib, ic, id := strings.index(text, `"title":"a"`), strings.index(text, `"title":"b"`), strings.index(text, `"title":"c"`), strings.index(text, `"title":"d"`)
	testing.expect(t, id < ib && ib < ic && ic < ia, text)
	text, _ = call(&s, "task_list", `{}`)
	ia, ib, ic, id = strings.index(text, `"title":"a"`), strings.index(text, `"title":"b"`), strings.index(text, `"title":"c"`), strings.index(text, `"title":"d"`)
	testing.expect(t, ia < ib && ib < ic && ic < id, text)
	_, bad = call(&s, "task_list", `{"sort":"name"}`)
	testing.expect(t, bad)

	// task_next skips d (blocked, though it has the top priority), takes b over a and c.
	text, _ = call(&s, "task_next", `{}`)
	testing.expect(t, strings.contains(text, `"title":"b"`), text)
	call(&s, "task_next", `{"claim":true}`)
	text, _ = call(&s, "task_next", `{}`)
	testing.expect(t, strings.contains(text, `"title":"c"`), text)

	text, bad = call(&s, "task_update", `{"id":1,"priority":7}`)
	testing.expect(t, !bad && strings.contains(text, `"priority":7`) && strings.contains(text, `"title":"a"`), text)
	text, _ = call(&s, "task_next", `{}`)
	testing.expect(t, strings.contains(text, `"title":"a"`), text)
	_, bad = call(&s, "task_update", `{"id":1,"priority":1.5}`)
	testing.expect(t, bad, "priority must be a whole number")
}

@(test)
test_history :: proc(t: ^testing.T) {
	s := temp_server("history", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}

	call(&s, "project_create", `{"name":"p"}`)
	call(&s, "task_create", `{"title":"a"}`)
	call(&s, "task_update", `{"id":1,"title":"a2","priority":3}`)
	call(&s, "task_move", `{"id":1,"project":"p"}`)
	call(&s, "task_claim", `{"id":1}`)
	call(&s, "task_note", `{"id":1,"text":"hi"}`)
	call(&s, "task_release", `{"id":1,"agent":"bob","force":true}`)
	call(&s, "task_next", `{"claim":true,"agent":"bob"}`)
	call(&s, "task_complete", `{"id":1,"agent":"bob"}`)

	text, bad := call(&s, "task_history", `{"id":1}`)
	testing.expect(t, !bad, text)
	// Oldest first, in the order things happened.
	last := -1
	for action in ([?]string{"created", "updated", "moved", "claimed", "noted", "released", "claimed", "completed"}) {
		at := strings.index(text[last + 1:], fmt.tprintf(`"action":"%s"`, action))
		testing.expectf(t, at >= 0, "%s missing or out of order in %s", action, text)
		last += at + 1
	}
	testing.expect(t, strings.contains(text, `"detail":"title, priority"`) && strings.contains(text, `"detail":"/ -> p/"`), text)
	testing.expect(t, strings.contains(text, "forced; was claimed by alice") && strings.contains(text, "via task_next"), text)
	testing.expect(t, strings.contains(text, `"who":"alice"`) && strings.contains(text, `"who":"bob"`), text)

	// A refused call leaves no trace; unknown ids are refused.
	call(&s, "task_claim", `{"id":1}`)
	text2, _ := call(&s, "task_history", `{"id":1}`)
	testing.expect(t, text2 == text, "a refused claim is not recorded")
	_, bad = call(&s, "task_history", `{"id":9}`)
	testing.expect(t, bad)

	// task_get stays free of the log.
	text, _ = call(&s, "task_get", `{"id":1}`)
	testing.expect(t, !strings.contains(text, "action"), text)
}

@(test)
test_release_stale_is_recorded :: proc(t: ^testing.T) {
	s := temp_server("stalehist", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}
	call(&s, "task_create", `{"title":"a"}`)
	call(&s, "agent_register", `{"agent":"bob"}`)
	call(&s, "task_claim", `{"id":1,"agent":"bob"}`)
	testing.expect(t, store_lock(&s))
	st, _ := store_load(&s)
	st.agents[0].last_seen -= 1000
	store_save(&s, st)
	store_unlock(&s)
	call(&s, "task_release_stale", `{"release":true}`)
	text, _ := call(&s, "task_history", `{"id":1}`)
	testing.expect(t, strings.contains(text, `"action":"released"`) && strings.contains(text, "stale: bob"), text)
}

@(test)
test_block_and_unblock :: proc(t: ^testing.T) {
	s := temp_server("block", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}
	for title in ([?]string{"a", "b", "c"}) {
		call(&s, "task_create", fmt.tprintf(`{{"title":"%s"}}`, title))
	}

	text, bad := call(&s, "task_block", `{"id":2,"blocked_by":[1,1]}`)
	testing.expect(t, !bad && strings.contains(text, `"blocked_by":[1]`) && strings.contains(text, `"blocked":true`), text)
	text, bad = call(&s, "task_block", `{"id":2,"blocked_by":[1]}`)
	testing.expect(t, !bad && strings.contains(text, `"blocked_by":[1]`), "repeats are kept once")
	call(&s, "task_block", `{"id":3,"blocked_by":[2]}`)

	text, bad = call(&s, "task_block", `{"id":1,"blocked_by":[1]}`)
	testing.expect(t, bad && strings.contains(text, "itself"), text)
	text, bad = call(&s, "task_block", `{"id":1,"blocked_by":[3]}`)
	testing.expect(t, bad && strings.contains(text, "cycle"), text)
	text, bad = call(&s, "task_block", `{"id":1,"blocked_by":[2]}`)
	testing.expect(t, bad && strings.contains(text, "cycle"), text)
	text, bad = call(&s, "task_block", `{"id":1,"blocked_by":[9]}`)
	testing.expect(t, bad && strings.contains(text, "no task 9"), text)
	_, bad = call(&s, "task_block", `{"id":1,"blocked_by":[]}`)
	testing.expect(t, bad)
	text, _ = call(&s, "task_get", `{"id":1}`)
	testing.expect(t, strings.contains(text, `"blocked_by":[]`), "refused calls change nothing")

	text, bad = call(&s, "task_claim", `{"id":3}`)
	testing.expect(t, bad && strings.contains(text, "blocked"), text)
	text, bad = call(&s, "task_unblock", `{"id":3,"blocked_by":[1]}`)
	testing.expect(t, bad && strings.contains(text, "not blocked by task 1"), text)
	text, bad = call(&s, "task_unblock", `{"id":3,"blocked_by":[2]}`)
	testing.expect(t, !bad && strings.contains(text, `"blocked_by":[]`) && strings.contains(text, `"blocked":false`), text)
	_, bad = call(&s, "task_claim", `{"id":3}`)
	testing.expect(t, !bad)
	// With the chain cut, the former cycle is fine.
	_, bad = call(&s, "task_block", `{"id":1,"blocked_by":[3]}`)
	testing.expect(t, !bad)

	text, _ = call(&s, "task_history", `{"id":2}`)
	testing.expect(t, strings.contains(text, `"action":"blocked"`) && strings.contains(text, `"detail":"by 1"`), text)

	call(&s, "task_complete", `{"id":3}`)
	text, bad = call(&s, "task_block", `{"id":3,"blocked_by":[2]}`)
	testing.expect(t, bad && strings.contains(text, "is done"), text)
}

@(test)
test_cancel_and_reopen :: proc(t: ^testing.T) {
	s := temp_server("cancel", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}
	call(&s, "task_create", `{"title":"a"}`)
	call(&s, "task_create", `{"title":"b","blocked_by":[1]}`)
	call(&s, "task_create", `{"title":"c"}`)

	text, bad := call(&s, "task_reopen", `{"id":1}`)
	testing.expect(t, bad && strings.contains(text, "not done or cancelled"), text)

	// Cancelling an open task frees what waited on it.
	text, bad = call(&s, "task_cancel", `{"id":1,"note":"not needed"}`)
	testing.expect(t, !bad && strings.contains(text, `"status":"cancelled"`) && strings.contains(text, "not needed"), text)
	text, _ = call(&s, "task_get", `{"id":2}`)
	testing.expect(t, strings.contains(text, `"blocked":false`), text)
	text, bad = call(&s, "task_claim", `{"id":1}`)
	testing.expect(t, bad && strings.contains(text, "cancelled"), text)
	text, bad = call(&s, "task_cancel", `{"id":1}`)
	testing.expect(t, bad && strings.contains(text, "already cancelled"), text)
	text, _ = call(&s, "task_list", `{"status":"cancelled"}`)
	testing.expect(t, strings.contains(text, `"title":"a"`) && !strings.contains(text, `"title":"b"`), text)
	text, _ = call(&s, "task_next", `{}`)
	testing.expect(t, strings.contains(text, `"title":"b"`), "next skips the cancelled task")

	// Reopening a cancelled task makes it claimable, and the dependent waits again.
	text, bad = call(&s, "task_reopen", `{"id":1,"note":"needed after all"}`)
	testing.expect(t, !bad && strings.contains(text, `"status":"open"`) && strings.contains(text, "needed after all"), text)
	text, _ = call(&s, "task_get", `{"id":2}`)
	testing.expect(t, strings.contains(text, `"blocked":true`), text)

	// A claimed task is cancelled by its assignee, or by force.
	call(&s, "task_claim", `{"id":3,"agent":"bob"}`)
	text, bad = call(&s, "task_cancel", `{"id":3}`)
	testing.expect(t, bad && strings.contains(text, "claimed by bob"), text)
	text, bad = call(&s, "task_cancel", `{"id":3,"force":true}`)
	testing.expect(t, !bad && strings.contains(text, `"assignee":""`), text)

	// A done task is not cancelled but can be reopened (unassigned).
	call(&s, "task_claim", `{"id":1}`)
	call(&s, "task_complete", `{"id":1}`)
	text, bad = call(&s, "task_cancel", `{"id":1}`)
	testing.expect(t, bad && strings.contains(text, "is done"), text)
	text, bad = call(&s, "task_reopen", `{"id":1}`)
	testing.expect(t, !bad && strings.contains(text, `"assignee":""`) && strings.contains(text, `"status":"open"`), text)

	text, _ = call(&s, "task_history", `{"id":1}`)
	testing.expect(t, strings.contains(text, `"action":"cancelled"`) && strings.contains(text, `"detail":"was cancelled"`) && strings.contains(text, `"detail":"was done"`), text)
	text, _ = call(&s, "project_create", `{"name":"p"}`)
	call(&s, "task_move", `{"id":3,"project":"p"}`)
	text, _ = call(&s, "project_list", `{}`)
	testing.expect(t, strings.contains(text, `"cancelled":1`), text)
}

@(test)
test_size_caps :: proc(t: ^testing.T) {
	s := temp_server("caps", "alice")
	defer server_destroy(&s)
	long :: proc(n: int) -> string {
		return strings.repeat("x", n, context.temp_allocator)
	}

	text, bad := call(&s, "task_create", fmt.tprintf(`{{"title":"%s"}}`, long(MAX_TITLE + 1)))
	testing.expect(t, bad && strings.contains(text, "title") && strings.contains(text, "limit"), text)
	text, bad = call(&s, "task_create", fmt.tprintf(`{{"title":"%s","description":"%s"}}`, long(MAX_TITLE), long(MAX_DESCRIPTION)))
	testing.expect(t, !bad, "exactly at the limits is fine")
	text, bad = call(&s, "task_create", fmt.tprintf(`{{"title":"a","description":"%s"}}`, long(MAX_DESCRIPTION + 1)))
	testing.expect(t, bad && strings.contains(text, "description"), text)
	text, bad = call(&s, "task_update", fmt.tprintf(`{{"id":1,"title":"%s"}}`, long(MAX_TITLE + 1)))
	testing.expect(t, bad && strings.contains(text, "title"), text)

	text, bad = call(&s, "task_note", fmt.tprintf(`{{"id":1,"text":"%s"}}`, long(MAX_NOTE + 1)))
	testing.expect(t, bad && strings.contains(text, "note"), text)
	for _ in 0 ..< MAX_NOTES_PER_TASK {
		call(&s, "task_note", `{"id":1,"text":"n"}`)
	}
	text, bad = call(&s, "task_note", `{"id":1,"text":"one too many"}`)
	testing.expect(t, bad && strings.contains(text, "notes"), text)
	call(&s, "task_claim", `{"id":1}`)
	text, bad = call(&s, "task_complete", `{"id":1,"note":"also too many"}`)
	testing.expect(t, bad, text)

	text, bad = call(&s, "project_create", fmt.tprintf(`{{"name":"p","description":"%s"}}`, long(MAX_DESCRIPTION + 1)))
	testing.expect(t, bad && strings.contains(text, "description"), text)
	text, bad = call(&s, "agent_register", fmt.tprintf(`{{"doing":"%s"}}`, long(MAX_DOING + 1)))
	testing.expect(t, bad && strings.contains(text, "doing"), text)
	text, bad = call(&s, "agent_register", fmt.tprintf(`{{"agent":"%s"}}`, long(MAX_AGENT_NAME + 1)))
	testing.expect(t, bad && strings.contains(text, "agent name"), text)
}

@(test)
test_rename_and_milestone_done :: proc(t: ^testing.T) {
	s := temp_server("rename", "alice")
	defer server_destroy(&s)
	call(&s, "project_create", `{"name":"p"}`)
	call(&s, "project_create", `{"name":"other"}`)
	call(&s, "milestone_create", `{"project":"p","name":"m"}`)
	call(&s, "milestone_create", `{"project":"p","name":"m2"}`)
	call(&s, "task_create", `{"title":"a","project":"p","milestone":"m"}`)
	call(&s, "task_create", `{"title":"b","project":"other"}`)

	text, bad := call(&s, "project_rename", `{"name":"p","new_name":"other"}`)
	testing.expect(t, bad && strings.contains(text, "already exists"), text)
	text, bad = call(&s, "project_rename", `{"name":"nope","new_name":"x"}`)
	testing.expect(t, bad && strings.contains(text, "no project"), text)
	text, bad = call(&s, "project_rename", `{"name":"p","new_name":" "}`)
	testing.expect(t, bad, text)
	text, bad = call(&s, "project_rename", `{"name":"p","new_name":"q"}`)
	testing.expect(t, !bad, text)
	text, _ = call(&s, "task_get", `{"id":1}`)
	testing.expect(t, strings.contains(text, `"project":"q"`) && strings.contains(text, `"milestone":"m"`), text)
	text, _ = call(&s, "task_get", `{"id":2}`)
	testing.expect(t, strings.contains(text, `"project":"other"`), "other projects' tasks are untouched")
	text, _ = call(&s, "task_list", `{"project":"q","milestone":"m"}`)
	testing.expect(t, strings.contains(text, `"title":"a"`), text)
	call(&s, "task_create", `{"title":"c","project":"q","milestone":"m2"}`)

	text, bad = call(&s, "milestone_rename", `{"project":"q","name":"m","new_name":"m2"}`)
	testing.expect(t, bad && strings.contains(text, "already has"), text)
	text, bad = call(&s, "milestone_rename", `{"project":"q","name":"m","new_name":"first"}`)
	testing.expect(t, !bad, text)
	text, _ = call(&s, "task_list", `{"project":"q","milestone":"first"}`)
	testing.expect(t, strings.contains(text, `"title":"a"`) && !strings.contains(text, `"title":"c"`), text)
	text, _ = call(&s, "task_history", `{"id":1}`)
	testing.expect(t, strings.contains(text, "project renamed p -> q") && strings.contains(text, "milestone renamed m -> first"), text)

	text, _ = call(&s, "project_list", `{}`)
	testing.expect(t, strings.contains(text, `"name":"first","description":"","done":false`), text)
	text, bad = call(&s, "milestone_set_done", `{"project":"q","name":"first","done":true}`)
	testing.expect(t, !bad && strings.contains(text, `"done":true`), text)
	text, _ = call(&s, "project_list", `{}`)
	testing.expect(t, strings.contains(text, `"name":"first","description":"","done":true`) && strings.contains(text, `"name":"m2","description":"","done":false`), text)
	text, bad = call(&s, "milestone_set_done", `{"project":"q","name":"first"}`)
	testing.expect(t, bad, text)
	text, bad = call(&s, "milestone_set_done", `{"project":"q","name":"zzz","done":true}`)
	testing.expect(t, bad && strings.contains(text, "no milestone"), text)
}

@(test)
test_task_search :: proc(t: ^testing.T) {
	s := temp_server("search", "alice")
	defer server_destroy(&s)
	call(&s, "project_create", `{"name":"p"}`)
	call(&s, "task_create", `{"title":"Fix the Widget","project":"p"}`)
	call(&s, "task_create", `{"title":"b","description":"about a widget too"}`)
	call(&s, "task_create", `{"title":"c"}`)
	call(&s, "task_note", `{"id":3,"text":"WIDGET note"}`)
	call(&s, "task_create", `{"title":"d"}`)

	text, bad := call(&s, "task_search", `{"text":"widget"}`)
	testing.expect(t, !bad && strings.contains(text, `"matched":["title"]`) && strings.contains(text, `"matched":["description"]`) && strings.contains(text, `"matched":["notes"]`) && !strings.contains(text, `"title":"d"`), text)
	text, _ = call(&s, "task_search", `{"text":"widget","project":"p"}`)
	testing.expect(t, strings.contains(text, `"title":"Fix the Widget"`) && !strings.contains(text, `"title":"b"`), text)
	call(&s, "task_claim", `{"id":2}`)
	text, _ = call(&s, "task_search", `{"text":"widget","status":"claimed"}`)
	testing.expect(t, strings.contains(text, `"title":"b"`) && !strings.contains(text, `"title":"c"`), text)
	text, _ = call(&s, "task_search", `{"text":"nothing here"}`)
	testing.expect(t, text == "[]", text)
	text, bad = call(&s, "task_search", `{"text":" "}`)
	testing.expect(t, bad, text)
	text, bad = call(&s, "task_search", `{"text":"x","milestone":"m"}`)
	testing.expect(t, bad && strings.contains(text, "needs project"), text)
}

@(test)
test_ship_one_per_day :: proc(t: ^testing.T) {
	s := temp_server("ship", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}
	s.today = "2026-10-27"

	text, bad := call(&s, "ship_schedule", `{"title":"Freedom Haters of Splorr","date":"2026-10-28"}`)
	testing.expect(t, !bad && strings.contains(text, `"date":"2026-10-28"`), text)
	text, bad = call(&s, "ship_schedule", `{"title":"Pyramid of Araxis","date":"2026-10-29"}`)
	testing.expect(t, !bad, text)
	text, bad = call(&s, "ship_schedule", `{"title":"Third","date":"2026-10-28"}`)
	testing.expect(t, bad && strings.contains(text, "taken") && strings.contains(text, "next free day is 2026-10-30"), text)
	text, bad = call(&s, "ship_schedule", `{"title":"Third"}`)
	testing.expect(t, !bad && strings.contains(text, `"date":"2026-10-27"`), text)
	text, bad = call(&s, "ship_schedule", `{"title":"Old","date":"2026-10-26"}`)
	testing.expect(t, bad && strings.contains(text, "past"), text)
	text, bad = call(&s, "ship_schedule", `{"title":"Bad","date":"2026-02-30"}`)
	testing.expect(t, bad && strings.contains(text, "not a date"), text)

	// Ship 3 (today). Shipping ship 1 early is refused, and forcing still hits the one-a-day rule.
	text, bad = call(&s, "ship_complete", `{"id":1}`)
	testing.expect(t, bad && strings.contains(text, "booked for 2026-10-28"), text)
	text, bad = call(&s, "ship_complete", `{"id":1,"force":true}`)
	testing.expect(t, bad && strings.contains(text, "taken"), text)
	text, bad = call(&s, "ship_complete", `{"id":3,"url":"https://x.itch.io/third"}`)
	testing.expect(t, !bad && strings.contains(text, `"status":"shipped"`), text)

	text, _ = call(&s, "ship_today", `{}`)
	testing.expect(t, strings.contains(text, `"may_ship_now":false`) && strings.contains(text, `"next_free_day":"2026-10-30"`), text)

	// Tomorrow.
	s.today = "2026-10-28"
	text, _ = call(&s, "ship_today", `{}`)
	testing.expect(t, strings.contains(text, `"may_ship_now":true`), text)
	text, bad = call(&s, "ship_complete", `{"id":1}`)
	testing.expect(t, !bad, text)
	text, bad = call(&s, "ship_cancel", `{"id":1}`)
	testing.expect(t, bad, "a shipped release cannot be cancelled")
	text, bad = call(&s, "ship_cancel", `{"id":2}`)
	testing.expect(t, !bad, text)
	text, bad = call(&s, "ship_reschedule", `{"id":2,"date":"2026-10-29"}`)
	testing.expect(t, bad, "a cancelled release cannot be rescheduled")
	text, bad = call(&s, "ship_schedule", `{"title":"Pyramid again","date":"2026-10-29"}`)
	testing.expect(t, !bad, text)
	text, _ = call(&s, "ship_list", `{"status":"shipped"}`)
	testing.expect(t, strings.contains(text, `"id":3`) && strings.contains(text, `"id":1`) && !strings.contains(text, `"id":2`), text)

	// Cancelled ships are hidden unless asked for.
	text, _ = call(&s, "ship_list", `{}`)
	testing.expect(t, !strings.contains(text, `"id":2`), text)
	text, _ = call(&s, "ship_list", `{"include_cancelled":true}`)
	testing.expect(t, strings.contains(text, `"id":2`), text)
	text, _ = call(&s, "ship_list", `{"status":"cancelled"}`)
	testing.expect(t, strings.contains(text, `"id":2`), text)
}

@(test)
test_ship_update :: proc(t: ^testing.T) {
	s := temp_server("shipupd", "alice")
	defer {os.remove_all(s.dir); server_destroy(&s)}
	s.today = "2026-10-27"

	call(&s, "ship_schedule", `{"title":"Pyramid of Araxis","date":"2026-10-29","note":"n"}`)
	call(&s, "ship_schedule", `{"title":"Other","date":"2026-10-30"}`)

	text, bad := call(&s, "ship_update", `{"id":1,"title":"Pyramid of Ahraxis","url":"https://x"}`)
	testing.expect(t, !bad && strings.contains(text, `"title":"Pyramid of Ahraxis"`) && strings.contains(text, `"date":"2026-10-29"`) && strings.contains(text, `"url":"https://x"`), text)
	text, bad = call(&s, "ship_update", `{"id":1,"note":""}`)
	testing.expect(t, !bad && strings.contains(text, `"note":""`), text)
	text, bad = call(&s, "ship_update", `{"id":1,"date":"2026-10-30"}`)
	testing.expect(t, bad && strings.contains(text, "taken"), text)
	text, bad = call(&s, "ship_update", `{"id":1,"date":"2026-10-26"}`)
	testing.expect(t, bad && strings.contains(text, "past"), text)
	text, bad = call(&s, "ship_update", `{"id":1,"date":"2026-11-01"}`)
	testing.expect(t, !bad && strings.contains(text, `"date":"2026-11-01"`), text)
	text, bad = call(&s, "ship_update", `{"id":1,"title":" "}`)
	testing.expect(t, bad, text)
	text, bad = call(&s, "ship_update", `{"id":1,"project":"nope"}`)
	testing.expect(t, bad, text)
	text, bad = call(&s, "ship_update", `{"id":1}`)
	testing.expect(t, bad && strings.contains(text, "nothing to change"), text)
	call(&s, "ship_cancel", `{"id":2}`)
	text, bad = call(&s, "ship_update", `{"id":2,"title":"x"}`)
	testing.expect(t, bad, "a cancelled release cannot be edited")
}
