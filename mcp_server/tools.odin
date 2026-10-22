package mcp_server

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"

// The whole tool table, in the order tools/list shows it.
tools :: proc() -> []Tool {
	@(static) all: [dynamic]Tool
	@(static) once: sync.Once // (tests run servers on several threads)
	sync.once_do(&once, proc() {
		all.allocator = runtime.default_allocator() // (not a test's tracking allocator: this outlives the test)
		append(&all, ..task_tools())
		append(&all, ..agent_tools())
		append(&all, ..project_tools())
	})
	return all[:]
}

// Runs `body` on the locked, freshly loaded store. If body returns save = true the store is written
// back. Lock and I/O failures become refusals.
with_store :: proc(s: ^Server, body: proc(s: ^Server, st: ^Store, args: json.Object) -> (res: Tool_Result, save: bool), args: json.Object) -> Tool_Result {
	if !store_lock(s) {
		return fail("could not lock the task store (another session holds it); try again")
	}
	defer store_unlock(s)
	st, problem := store_load(s)
	if problem != "" {
		return fail(problem)
	}
	res, save := body(s, &st, args)
	if save && !res.is_error && !store_save(s, st) {
		return fail("could not write the task store")
	}
	return res
}

task_json :: proc(st: Store, t: Task) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"id":%d,"title":%s,"description":%s,"status":%s,"priority":%d,"assignee":%s,"project":%s,"milestone":%s,"blocked_by":[`, t.id, quote(t.title), quote(t.description), quote(status_name(t.status)), t.priority, quote(t.assignee), quote(t.project), quote(t.milestone))
	for id, i in t.blocked_by {
		fmt.sbprintf(&b, "%s%d", i > 0 ? "," : "", id)
	}
	strings.write_string(&b, `],"notes":[`)
	for n, i in t.notes {
		fmt.sbprintf(&b, `%s{{"author":%s,"text":%s}}`, i > 0 ? "," : "", quote(n.author), quote(n.text))
	}
	_, blocked := task_blocked_by_open(st, t)
	fmt.sbprintf(&b, `],"blocked":%v}}`, blocked)
	return strings.to_string(b)
}

status_name :: proc(s: Status) -> string {
	switch s {
	case .Open:
		return "open"
	case .Claimed:
		return "claimed"
	case .Done:
		return "done"
	}
	return "?"
}
