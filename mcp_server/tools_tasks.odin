package mcp_server

import "core:encoding/json"
import "core:fmt"
import "core:strings"

task_tools :: proc() -> []Tool {
	@(static) table := [?]Tool {
		{
			name = "task_create",
			description = "Create a task (status open) with an optional integer priority (default 0; higher is more important), optionally in a project (which must exist) and a milestone of that project. blocked_by lists ids of tasks that must be done before it can be claimed. Returns the new task.",
			schema = `{"type":"object","properties":{"title":{"type":"string"},"description":{"type":"string"},"blocked_by":{"type":"array","items":{"type":"integer"}},"priority":{"type":"integer"},"project":{"type":"string"},"milestone":{"type":"string"},"agent":{"type":"string"}},"required":["title"]}`,
			run = tool_task_create,
		},
		{
			name = "task_list",
			description = "List tasks, optionally only those with a status (open, claimed, done), an assignee, a project or a milestone (milestone needs project). Each task is shown in full; blocked is true while a task it waits on is not done. Ordered by id, or with sort \"priority\" by priority (highest first, then id).",
			schema = `{"type":"object","properties":{"status":{"type":"string","enum":["open","claimed","done"]},"assignee":{"type":"string"},"project":{"type":"string"},"milestone":{"type":"string"},"sort":{"type":"string","enum":["id","priority"]}}}`,
			run = tool_task_list,
		},
		{
			name = "task_next",
			description = "Show the next claimable task: the open task that no unfinished task blocks with the highest priority (lowest id among equals), optionally within a project or milestone (milestone needs project). With claim true it is also claimed for the agent (defaults to the server's --agent name), atomically. Says so, without failing, when nothing is claimable.",
			schema = `{"type":"object","properties":{"project":{"type":"string"},"milestone":{"type":"string"},"claim":{"type":"boolean"},"agent":{"type":"string"}}}`,
			run = tool_task_next,
		},
		{
			name = "task_history",
			description = "Show a task's history, oldest first: when (unix seconds), who, what happened (created, claimed, released, completed, noted, updated, moved) and a detail. Tasks from before the log existed start with whatever happened after.",
			schema = `{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]}`,
			run = tool_task_history,
		},
		{
			name = "task_update",
			description = "Change a task's title, description and/or priority (give at least one; the title cannot be empty, the description can; higher priority is more important). Anyone may edit any task, in any status. Status, assignee, project and milestone have their own tools. agent (else the server's --agent) is refreshed as a heartbeat if registered. agent (else the server's --agent) is refreshed as a heartbeat if registered.",
			schema = `{"type":"object","properties":{"id":{"type":"integer"},"title":{"type":"string"},"description":{"type":"string"},"priority":{"type":"integer"},"agent":{"type":"string"}},"required":["id"]}`,
			run = tool_task_update,
		},
		{
			name = "task_move",
			description = "Put a task in a project and optionally one of its milestones, or take it out. Giving project replaces the placement (the milestone is cleared unless given too); giving only milestone keeps the task's project. An empty string clears: project \"\" removes it from its project and milestone, milestone \"\" removes it from its milestone.",
			schema = `{"type":"object","properties":{"id":{"type":"integer"},"project":{"type":"string"},"milestone":{"type":"string"},"agent":{"type":"string"}},"required":["id"]}`,
			run = tool_task_move,
		},
		{
			name = "task_get",
			description = "Show one task by id, with its notes.",
			schema = `{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]}`,
			run = tool_task_get,
		},
		{
			name = "task_claim",
			description = "Claim an open task for an agent, atomically: if another agent got there first, or the task is blocked by unfinished tasks, it is refused. agent defaults to the server's --agent name.",
			schema = `{"type":"object","properties":{"id":{"type":"integer"},"agent":{"type":"string"}},"required":["id"]}`,
			run = tool_task_claim,
		},
		{
			name = "task_release",
			description = "Give a claimed task back (status open). Only its assignee may release it unless force is true.",
			schema = `{"type":"object","properties":{"id":{"type":"integer"},"agent":{"type":"string"},"force":{"type":"boolean"}},"required":["id"]}`,
			run = tool_task_release,
		},
		{
			name = "task_complete",
			description = "Mark a claimed task done. Only its assignee may complete it unless force is true. An optional note is added.",
			schema = `{"type":"object","properties":{"id":{"type":"integer"},"agent":{"type":"string"},"note":{"type":"string"},"force":{"type":"boolean"}},"required":["id"]}`,
			run = tool_task_complete,
		},
		{
			name = "task_note",
			description = "Append a note to a task (a handoff, a finding, a question). Anyone may add one.",
			schema = `{"type":"object","properties":{"id":{"type":"integer"},"text":{"type":"string"},"agent":{"type":"string"}},"required":["id","text"]}`,
			run = tool_task_note,
		},
	}
	return table[:]
}

// The priority argument if given (any integer; higher is more important), else 0.
optional_priority :: proc(args: json.Object) -> (p: int, res: Tool_Result, ok: bool) {
	if _, has := args["priority"]; !has {
		return 0, {}, true
	}
	v, got := arg_int(args, "priority")
	if !got {
		return 0, fail("priority is an integer (higher is more important)"), false
	}
	return v, {}, true
}

// Finds the task named by args.id, or the refusal.
find_task :: proc(st: ^Store, args: json.Object) -> (idx: int, res: Tool_Result, ok: bool) {
	id, r, got := need_int(args, "id")
	if !got {
		return -1, r, false
	}
	i := task_index(st^, id)
	if i < 0 {
		return -1, fail(fmt.tprintf("no task %d", id)), false
	}
	return i, {}, true
}

// Who is acting: the agent argument, else the server's --agent, else "" (create, move and update
// do not insist on a name).
actor :: proc(s: ^Server, args: json.Object) -> string {
	if a, has := arg_string(args, "agent"); has && a != "" {
		return a
	}
	return s.agent
}

// Appends an event to the task's history.
record :: proc(t: ^Task, who, action, detail: string) {
	events := make([dynamic]Event, context.temp_allocator)
	append(&events, ..t.history)
	append(&events, Event{now_unix(), who, action, detail})
	t.history = events[:]
}

append_note :: proc(t: ^Task, author, text: string) {
	notes := make([dynamic]Note, context.temp_allocator)
	append(&notes, ..t.notes)
	append(&notes, Note{author, text})
	t.notes = notes[:]
}

tool_task_create :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			title, r, ok := need_string(args, "title")
			if !ok {
				return r, false
			}
			if strings.trim_space(title) == "" {
				return fail("title is empty"), false
			}
			desc, _ := arg_string(args, "description")
			deps := make([dynamic]int, context.temp_allocator)
			if raw, has := args["blocked_by"]; has {
				arr, is_arr := raw.(json.Array)
				if !is_arr {
					return fail("blocked_by is an array of task ids"), false
				}
				for item in arr {
					id, is_int := json_int(item)
					if !is_int {
						return fail("blocked_by is an array of task ids"), false
					}
					if task_index(st^, id) < 0 {
						return fail(fmt.tprintf("blocked_by: no task %d", id)), false
					}
					append(&deps, id)
				}
			}
			project, _ := arg_string(args, "project")
			milestone, _ := arg_string(args, "milestone")
			if r, ok := check_placement(st^, project, milestone); !ok {
				return r, false
			}
			priority, r2, ok2 := optional_priority(args)
			if !ok2 {
				return r2, false
			}
			t := Task {
				id          = st.next_id,
				priority    = priority,
				title       = title,
				description = desc,
				blocked_by  = deps[:],
				project     = project,
				milestone   = milestone,
			}
			st.next_id += 1
			record(&t, actor(s, args), "created", t.title)
tasks := make([dynamic]Task, context.temp_allocator)
			append(&tasks, ..st.tasks)
			append(&tasks, t)
			st.tasks = tasks[:]
			return ok_result(task_json(st^, t)), true
		}, args)
}

tool_task_list :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			want_status, has_status := arg_string(args, "status")
			if has_status && want_status != "open" && want_status != "claimed" && want_status != "done" {
				return fail("status is open, claimed or done"), false
			}
			want_who, has_who := arg_string(args, "assignee")
			want_project, has_project := arg_string(args, "project")
			want_ms, has_ms := arg_string(args, "milestone")
			if has_ms && !has_project {
				return fail("milestone needs project (milestone names are per project)"), false
			}
			sort, has_sort := arg_string(args, "sort")
			if has_sort && sort != "id" && sort != "priority" {
				return fail("sort is id or priority"), false
			}
			ordered := make([dynamic]Task, context.temp_allocator)
			append(&ordered, ..st.tasks)
			if sort == "priority" {
				for i in 1 ..< len(ordered) { // insertion sort: stable, so ties stay in id order
					for j := i; j > 0 && ordered[j].priority > ordered[j - 1].priority; j -= 1 {
						ordered[j], ordered[j - 1] = ordered[j - 1], ordered[j]
					}
				}
			}
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, "[")
			n := 0
			for t in ordered {
				if has_status && status_name(t.status) != want_status {
					continue
				}
				if has_who && t.assignee != want_who {
					continue
				}
				if has_project && t.project != want_project {
					continue
				}
				if has_ms && t.milestone != want_ms {
					continue
				}
				fmt.sbprintf(&b, "%s%s", n > 0 ? "," : "", task_json(st^, t))
				n += 1
			}
			strings.write_string(&b, "]")
			return ok_result(strings.to_string(b)), false
		}, args)
}

tool_task_next :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	args := args
	if arg_bool(args, "claim") {
		agent, r, ok := acting_agent(s, args)
		if !ok {
			return r
		}
		args["agent"] = json.String(agent)
	}
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			want_project, has_project := arg_string(args, "project")
			want_ms, has_ms := arg_string(args, "milestone")
			if has_ms && !has_project {
				return fail("milestone needs project (milestone names are per project)"), false
			}
			best := -1
			for t, i in st.tasks {
				if t.status != .Open {
					continue
				}
				if has_project && t.project != want_project {
					continue
				}
				if has_ms && t.milestone != want_ms {
					continue
				}
				if _, blocked := task_blocked_by_open(st^, t); blocked {
					continue
				}
				if best < 0 || t.priority > st.tasks[best].priority {
					best = i
				}
			}
			if best >= 0 {
				t := &st.tasks[best]
				if arg_bool(args, "claim") {
					agent, _ := arg_string(args, "agent")
					t.status = .Claimed
					t.assignee = agent
					record(t, agent, "claimed", "via task_next")
					refresh_agent(s, st, args)
					return ok_result(task_json(st^, t^)), true
				}
				return ok_result(task_json(st^, t^)), false
			}
			return ok_result("no claimable task"), false
		}, args)
}

tool_task_history :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			i, r, ok := find_task(st, args)
			if !ok {
				return r, false
			}
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, "[")
			for e, j in st.tasks[i].history {
				fmt.sbprintf(&b, `%s{{"at":%d,"who":%s,"action":%s,"detail":%s}}`, j > 0 ? "," : "", e.at, quote(e.who), quote(e.action), quote(e.detail))
			}
			strings.write_string(&b, "]")
			return ok_result(strings.to_string(b)), false
		}, args)
}

tool_task_get :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			i, r, ok := find_task(st, args)
			if !ok {
				return r, false
			}
			return ok_result(task_json(st^, st.tasks[i])), false
		}, args)
}

tool_task_claim :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	agent, r, ok := acting_agent(s, args)
	if !ok {
		return r
	}
	args := args
	args["agent"] = json.String(agent)
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			i, r, ok := find_task(st, args)
			if !ok {
				return r, false
			}
			agent, _ := arg_string(args, "agent")
			t := &st.tasks[i]
			switch t.status {
			case .Claimed:
				return fail(fmt.tprintf("task %d is already claimed by %s", t.id, t.assignee)), false
			case .Done:
				return fail(fmt.tprintf("task %d is already done", t.id)), false
			case .Open:
			}
			if b, blocked := task_blocked_by_open(st^, t^); blocked {
				return fail(fmt.tprintf("task %d is blocked by unfinished task %d", t.id, b)), false
			}
			t.status = .Claimed
			t.assignee = agent
			record(t, agent, "claimed", "")
			refresh_agent(s, st, args)
			return ok_result(task_json(st^, t^)), true
		}, args)
}

tool_task_release :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	agent, r, ok := acting_agent(s, args)
	if !ok {
		return r
	}
	args := args
	args["agent"] = json.String(agent)
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			i, r, ok := find_task(st, args)
			if !ok {
				return r, false
			}
			agent, _ := arg_string(args, "agent")
			t := &st.tasks[i]
			if t.status != .Claimed {
				return fail(fmt.tprintf("task %d is not claimed", t.id)), false
			}
			if t.assignee != agent && !arg_bool(args, "force") {
				return fail(fmt.tprintf("task %d is claimed by %s, not %s (force true overrides)", t.id, t.assignee, agent)), false
			}
			detail := ""
			if t.assignee != agent {
				detail = fmt.tprintf("forced; was claimed by %s", t.assignee)
			}
			t.status = .Open
			t.assignee = ""
			record(t, agent, "released", detail)
			refresh_agent(s, st, args)
			return ok_result(task_json(st^, t^)), true
		}, args)
}

tool_task_complete :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	agent, r, ok := acting_agent(s, args)
	if !ok {
		return r
	}
	args := args
	args["agent"] = json.String(agent)
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			i, r, ok := find_task(st, args)
			if !ok {
				return r, false
			}
			agent, _ := arg_string(args, "agent")
			t := &st.tasks[i]
			if t.status != .Claimed {
				return fail(fmt.tprintf("task %d is not claimed (claim it first)", t.id)), false
			}
			if t.assignee != agent && !arg_bool(args, "force") {
				return fail(fmt.tprintf("task %d is claimed by %s, not %s (force true overrides)", t.id, t.assignee, agent)), false
			}
			if note, has := arg_string(args, "note"); has && note != "" {
				append_note(t, agent, note)
			}
			detail := ""
			if t.assignee != agent {
				detail = fmt.tprintf("forced; was claimed by %s", t.assignee)
			}
			t.status = .Done
			record(t, agent, "completed", detail)
			refresh_agent(s, st, args)
			return ok_result(task_json(st^, t^)), true
		}, args)
}

tool_task_note :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	agent, r, ok := acting_agent(s, args)
	if !ok {
		return r
	}
	args := args
	args["agent"] = json.String(agent)
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			i, r, ok := find_task(st, args)
			if !ok {
				return r, false
			}
			text, r2, ok2 := need_string(args, "text")
			if !ok2 {
				return r2, false
			}
			agent, _ := arg_string(args, "agent")
			append_note(&st.tasks[i], agent, text)
			record(&st.tasks[i], agent, "noted", "")
refresh_agent(s, st, args)
			return ok_result(task_json(st^, st.tasks[i])), true
		}, args)
}

// A project and milestone a task may be placed in: both empty, or an existing project with the
// milestone empty or one of its milestones.
check_placement :: proc(st: Store, project, milestone: string) -> (res: Tool_Result, ok: bool) {
	if project == "" {
		if milestone != "" {
			return fail("a milestone needs a project"), false
		}
		return {}, true
	}
	if project_index(st, project) < 0 {
		return fail(fmt.tprintf("no project %s", project)), false
	}
	if milestone != "" && milestone_index(st, project, milestone) < 0 {
		return fail(fmt.tprintf("project %s has no milestone %s", project, milestone)), false
	}
	return {}, true
}

tool_task_move :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			i, r, ok := find_task(st, args)
			if !ok {
				return r, false
			}
			project, has_project := arg_string(args, "project")
			milestone, has_ms := arg_string(args, "milestone")
			if !has_project && !has_ms {
				return fail("give project and/or milestone (an empty string clears)"), false
			}
			t := &st.tasks[i]
			if !has_project {
				project = t.project
			} else if project != t.project && !has_ms {
				milestone = "" // a new project: the old milestone no longer applies
			}
			if has_project && project == "" {
				milestone = ""
			}
			if r, ok := check_placement(st^, project, milestone); !ok {
				return r, false
			}
			record(t, actor(s, args), "moved", fmt.tprintf("%s/%s -> %s/%s", t.project, t.milestone, project, milestone))
			t.project = project
			t.milestone = milestone
return ok_result(task_json(st^, t^)), true
		}, args)
}

tool_task_update :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			i, r, ok := find_task(st, args)
			if !ok {
				return r, false
			}
			title, has_title := arg_string(args, "title")
			desc, has_desc := arg_string(args, "description")
			priority, r2, ok2 := optional_priority(args)
			if !ok2 {
				return r2, false
			}
			_, has_priority := args["priority"]
			if !has_title && !has_desc && !has_priority {
				return fail("give title, description and/or priority"), false
			}
			if has_title && strings.trim_space(title) == "" {
				return fail("title is empty"), false
			}
			t := &st.tasks[i]
			changed := make([dynamic]string, context.temp_allocator)
			if has_title {
				append(&changed, "title")
			}
			if has_desc {
				append(&changed, "description")
			}
			if has_priority {
				append(&changed, "priority")
			}
			record(t, actor(s, args), "updated", strings.join(changed[:], ", ", context.temp_allocator))
			if has_title {
				t.title = title
			}
			if has_desc {
				t.description = desc
			}
			if has_priority {
				t.priority = priority
			}
			refresh_agent(s, st, args)
			return ok_result(task_json(st^, t^)), true
		}, args)
}
