package mcp_server

import "core:encoding/json"
import "core:fmt"
import "core:strings"

task_tools :: proc() -> []Tool {
	@(static) table := [?]Tool {
		{
			name = "task_create",
			description = "Create a task (status open), optionally in a project (which must exist) and a milestone of that project. blocked_by lists ids of tasks that must be done before it can be claimed. Returns the new task.",
			schema = `{"type":"object","properties":{"title":{"type":"string"},"description":{"type":"string"},"blocked_by":{"type":"array","items":{"type":"integer"}},"project":{"type":"string"},"milestone":{"type":"string"}},"required":["title"]}`,
			run = tool_task_create,
		},
		{
			name = "task_list",
			description = "List tasks, optionally only those with a status (open, claimed, done), an assignee, a project or a milestone (milestone needs project). Each task is shown in full; blocked is true while a task it waits on is not done.",
			schema = `{"type":"object","properties":{"status":{"type":"string","enum":["open","claimed","done"]},"assignee":{"type":"string"},"project":{"type":"string"},"milestone":{"type":"string"}}}`,
			run = tool_task_list,
		},
		{
			name = "task_move",
			description = "Put a task in a project and optionally one of its milestones, or take it out. Giving project replaces the placement (the milestone is cleared unless given too); giving only milestone keeps the task's project. An empty string clears: project \"\" removes it from its project and milestone, milestone \"\" removes it from its milestone.",
			schema = `{"type":"object","properties":{"id":{"type":"integer"},"project":{"type":"string"},"milestone":{"type":"string"}},"required":["id"]}`,
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
			t := Task {
				id          = st.next_id,
				title       = title,
				description = desc,
				blocked_by  = deps[:],
				project     = project,
				milestone   = milestone,
			}
			st.next_id += 1
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
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, "[")
			n := 0
			for t in st.tasks {
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
			t.status = .Open
			t.assignee = ""
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
			t.status = .Done
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
			t.project = project
			t.milestone = milestone
			return ok_result(task_json(st^, t^)), true
		}, args)
}
