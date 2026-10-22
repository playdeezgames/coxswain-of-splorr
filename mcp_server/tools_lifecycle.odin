package mcp_server

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// Tools that change a task's dependencies or end/restart its life.
lifecycle_tools :: proc() -> []Tool {
	@(static) table := [?]Tool {
		{
			name = "task_block",
			description = "Make a task wait for other tasks: adds the ids in blocked_by to its dependencies (ones it already has are kept once). Refuses unknown ids, the task itself, any dependency cycle, and a task that is done or cancelled. Cancelled tasks do not block.",
			schema = `{"type":"object","properties":{"id":{"type":"integer"},"blocked_by":{"type":"array","items":{"type":"integer"}},"agent":{"type":"string"}},"required":["id","blocked_by"]}`,
			run = tool_task_block,
		},
		{
			name = "task_unblock",
			description = "Stop a task waiting for other tasks: removes the ids in blocked_by from its dependencies. Refuses an id the task does not depend on.",
			schema = `{"type":"object","properties":{"id":{"type":"integer"},"blocked_by":{"type":"array","items":{"type":"integer"}},"agent":{"type":"string"}},"required":["id","blocked_by"]}`,
			run = tool_task_unblock,
		},
		{
			name = "task_cancel",
			description = "Drop a task that will not be done (status cancelled). Tasks are never deleted, so ids, history and notes stay. A cancelled task no longer blocks the tasks waiting on it. An open task may be cancelled by anyone; a claimed one only by its assignee unless force is true. An optional note says why.",
			schema = `{"type":"object","properties":{"id":{"type":"integer"},"agent":{"type":"string"},"note":{"type":"string"},"force":{"type":"boolean"}},"required":["id"]}`,
			run = tool_task_cancel,
		},
		{
			name = "task_reopen",
			description = "Put a done or cancelled task back to open, unassigned, so it can be claimed again. Tasks waiting on it are blocked again if it was done. An optional note says why.",
			schema = `{"type":"object","properties":{"id":{"type":"integer"},"agent":{"type":"string"},"note":{"type":"string"}},"required":["id"]}`,
			run = tool_task_reopen,
		},
	}
	return table[:]
}

// The ids in args.blocked_by, each an existing task, without repeats.
id_list :: proc(st: Store, args: json.Object) -> (ids: []int, res: Tool_Result, ok: bool) {
	raw, has := args["blocked_by"]
	arr, is_arr := raw.(json.Array)
	if !has || !is_arr || len(arr) == 0 {
		return nil, fail("blocked_by is a non-empty array of task ids"), false
	}
	out := make([dynamic]int, context.temp_allocator)
	for item in arr {
		id, is_int := json_int(item)
		if !is_int {
			return nil, fail("blocked_by is a non-empty array of task ids"), false
		}
		if task_index(st, id) < 0 {
			return nil, fail(fmt.tprintf("blocked_by: no task %d", id)), false
		}
		if !contains_id(out[:], id) {
			append(&out, id)
		}
	}
	return out[:], {}, true
}

contains_id :: proc(ids: []int, id: int) -> bool {
	for x in ids {
		if x == id {
			return true
		}
	}
	return false
}

// True if `target` can be reached from `from` by following blocked_by links (from == target counts).
depends_on :: proc(st: Store, from, target: int) -> bool {
	seen := make([dynamic]int, context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	append(&stack, from)
	for len(stack) > 0 {
		id := pop(&stack)
		if id == target {
			return true
		}
		if contains_id(seen[:], id) {
			continue
		}
		append(&seen, id)
		if i := task_index(st, id); i >= 0 {
			append(&stack, ..st.tasks[i].blocked_by)
		}
	}
	return false
}

ids_text :: proc(ids: []int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for id, i in ids {
		fmt.sbprintf(&b, "%s%d", i > 0 ? "," : "", id)
	}
	return strings.to_string(b)
}

tool_task_block :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			i, r, ok := find_task(st, args)
			if !ok {
				return r, false
			}
			ids, r2, ok2 := id_list(st^, args)
			if !ok2 {
				return r2, false
			}
			t := &st.tasks[i]
			if t.status == .Done || t.status == .Cancelled {
				return fail(fmt.tprintf("task %d is %s; reopen it before changing what it waits for", t.id, status_name(t.status))), false
			}
			added := make([dynamic]int, context.temp_allocator)
			for id in ids {
				if id == t.id {
					return fail(fmt.tprintf("task %d cannot be blocked by itself", id)), false
				}
				if contains_id(t.blocked_by, id) {
					continue
				}
				if depends_on(st^, id, t.id) {
					return fail(fmt.tprintf("task %d cannot be blocked by task %d: that would be a cycle (task %d already waits for task %d)", t.id, id, id, t.id)), false
				}
				append(&added, id)
			}
			if len(added) == 0 {
				return ok_result(task_json(st^, t^)), false
			}
			deps := make([dynamic]int, context.temp_allocator)
			append(&deps, ..t.blocked_by)
			append(&deps, ..added[:])
			t.blocked_by = deps[:]
			record(t, actor(s, args), "blocked", fmt.tprintf("by %s", ids_text(added[:])))
			return ok_result(task_json(st^, t^)), true
		}, args)
}

tool_task_unblock :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			i, r, ok := find_task(st, args)
			if !ok {
				return r, false
			}
			ids, r2, ok2 := id_list(st^, args)
			if !ok2 {
				return r2, false
			}
			t := &st.tasks[i]
			for id in ids {
				if !contains_id(t.blocked_by, id) {
					return fail(fmt.tprintf("task %d is not blocked by task %d", t.id, id)), false
				}
			}
			kept := make([dynamic]int, context.temp_allocator)
			for id in t.blocked_by {
				if !contains_id(ids, id) {
					append(&kept, id)
				}
			}
			t.blocked_by = kept[:]
			record(t, actor(s, args), "unblocked", fmt.tprintf("from %s", ids_text(ids)))
			return ok_result(task_json(st^, t^)), true
		}, args)
}

tool_task_cancel :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			i, r, ok := find_task(st, args)
			if !ok {
				return r, false
			}
			who := actor(s, args)
			t := &st.tasks[i]
			switch t.status {
			case .Done:
				return fail(fmt.tprintf("task %d is done (task_reopen it first)", t.id)), false
			case .Cancelled:
				return fail(fmt.tprintf("task %d is already cancelled", t.id)), false
			case .Claimed:
				if t.assignee != who && !arg_bool(args, "force") {
					return fail(fmt.tprintf("task %d is claimed by %s, not %s (force true overrides)", t.id, t.assignee, who)), false
				}
			case .Open:
			}
			detail := ""
			if t.status == .Claimed && t.assignee != who {
				detail = fmt.tprintf("forced; was claimed by %s", t.assignee)
			}
			if note, has := arg_string(args, "note"); has && note != "" {
				append_note(t, who, note)
			}
			t.status = .Cancelled
			t.assignee = ""
			record(t, who, "cancelled", detail)
			refresh_agent(s, st, args)
			return ok_result(task_json(st^, t^)), true
		}, args)
}

tool_task_reopen :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			i, r, ok := find_task(st, args)
			if !ok {
				return r, false
			}
			who := actor(s, args)
			t := &st.tasks[i]
			if t.status != .Done && t.status != .Cancelled {
				return fail(fmt.tprintf("task %d is %s, not done or cancelled", t.id, status_name(t.status))), false
			}
			if note, has := arg_string(args, "note"); has && note != "" {
				append_note(t, who, note)
			}
			record(t, who, "reopened", fmt.tprintf("was %s", status_name(t.status)))
			t.status = .Open
			t.assignee = ""
			refresh_agent(s, st, args)
			return ok_result(task_json(st^, t^)), true
		}, args)
}
