package mcp_server

import "core:encoding/json"
import "core:fmt"
import "core:strings"

MAX_NAME :: 64

project_tools :: proc() -> []Tool {
	@(static) table := [?]Tool {
		{
			name = "project_create",
			description = "Create a project (a named group of tasks; names are unique, at most 64 characters). Tasks join it with task_create or task_move.",
			schema = `{"type":"object","properties":{"name":{"type":"string"},"description":{"type":"string"}},"required":["name"]}`,
			run = tool_project_create,
		},
		{
			name = "project_list",
			description = "List projects, each with its milestones and counts of its tasks by status (milestone counts too).",
			schema = `{"type":"object","properties":{}}`,
			run = tool_project_list,
		},
		{
			name = "project_delete",
			description = "Delete a project and its milestones. Refused while any task is still in the project: move or finish those first.",
			schema = `{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}`,
			run = tool_project_delete,
		},
		{
			name = "milestone_create",
			description = "Add a milestone to a project (names are unique within the project, at most 64 characters). Tasks join it with task_create or task_move.",
			schema = `{"type":"object","properties":{"project":{"type":"string"},"name":{"type":"string"},"description":{"type":"string"}},"required":["project","name"]}`,
			run = tool_milestone_create,
		},
		{
			name = "milestone_delete",
			description = "Delete a milestone. Refused while any task is still in it: move those first.",
			schema = `{"type":"object","properties":{"project":{"type":"string"},"name":{"type":"string"}},"required":["project","name"]}`,
			run = tool_milestone_delete,
		},
	}
	return table[:]
}

// Why a project or milestone name is unusable, or "".
name_problem :: proc(name: string) -> string {
	if strings.trim_space(name) == "" {
		return "the name is empty"
	}
	if len(name) > MAX_NAME {
		return fmt.tprintf("the name is longer than %d characters", MAX_NAME)
	}
	return ""
}

// Task counts by status for the tasks matching a project (and a milestone when given).
counts_json :: proc(st: Store, project: string, milestone: string, by_milestone: bool) -> string {
	n: [Status]int
	for t in st.tasks {
		if t.project == project && (!by_milestone || t.milestone == milestone) {
			n[t.status] += 1
		}
	}
	return fmt.tprintf(`{{"open":%d,"claimed":%d,"done":%d,"cancelled":%d}}`, n[.Open], n[.Claimed], n[.Done], n[.Cancelled])
}

tool_project_create :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			name, r, ok := need_string(args, "name")
			if !ok {
				return r, false
			}
			if p := name_problem(name); p != "" {
				return fail(p), false
			}
			if project_index(st^, name) >= 0 {
				return fail(fmt.tprintf("project %s already exists", name)), false
			}
			desc, _ := arg_string(args, "description")
			list := make([dynamic]Project, context.temp_allocator)
			append(&list, ..st.projects)
			append(&list, Project{name, desc})
			st.projects = list[:]
			return ok_result(fmt.tprintf(`{{"name":%s,"description":%s}}`, quote(name), quote(desc))), true
		}, args)
}

tool_project_list :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, "[")
			for p, i in st.projects {
				fmt.sbprintf(&b, `%s{{"name":%s,"description":%s,"tasks":%s,"milestones":[`, i > 0 ? "," : "", quote(p.name), quote(p.description), counts_json(st^, p.name, "", false))
				n := 0
				for m in st.milestones {
					if m.project == p.name {
						fmt.sbprintf(&b, `%s{{"name":%s,"description":%s,"tasks":%s}}`, n > 0 ? "," : "", quote(m.name), quote(m.description), counts_json(st^, p.name, m.name, true))
						n += 1
					}
				}
				strings.write_string(&b, "]}")
			}
			strings.write_string(&b, "]")
			return ok_result(strings.to_string(b)), false
		}, args)
}

tool_project_delete :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			name, r, ok := need_string(args, "name")
			if !ok {
				return r, false
			}
			if project_index(st^, name) < 0 {
				return fail(fmt.tprintf("no project %s", name)), false
			}
			count := 0
			for t in st.tasks {
				if t.project == name {
					count += 1
				}
			}
			if count > 0 {
				return fail(fmt.tprintf("project %s still has %d task(s); move them first", name, count)), false
			}
			projects := make([dynamic]Project, context.temp_allocator)
			for p in st.projects {
				if p.name != name {
					append(&projects, p)
				}
			}
			milestones := make([dynamic]Milestone, context.temp_allocator)
			for m in st.milestones {
				if m.project != name {
					append(&milestones, m)
				}
			}
			st.projects = projects[:]
			st.milestones = milestones[:]
			return ok_result(fmt.tprintf("project %s deleted", name)), true
		}, args)
}

tool_milestone_create :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			project, r, ok := need_string(args, "project")
			if !ok {
				return r, false
			}
			name, r2, ok2 := need_string(args, "name")
			if !ok2 {
				return r2, false
			}
			if project_index(st^, project) < 0 {
				return fail(fmt.tprintf("no project %s", project)), false
			}
			if p := name_problem(name); p != "" {
				return fail(p), false
			}
			if milestone_index(st^, project, name) >= 0 {
				return fail(fmt.tprintf("project %s already has a milestone %s", project, name)), false
			}
			desc, _ := arg_string(args, "description")
			list := make([dynamic]Milestone, context.temp_allocator)
			append(&list, ..st.milestones)
			append(&list, Milestone{project, name, desc})
			st.milestones = list[:]
			return ok_result(fmt.tprintf(`{{"project":%s,"name":%s,"description":%s}}`, quote(project), quote(name), quote(desc))), true
		}, args)
}

tool_milestone_delete :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			project, r, ok := need_string(args, "project")
			if !ok {
				return r, false
			}
			name, r2, ok2 := need_string(args, "name")
			if !ok2 {
				return r2, false
			}
			if milestone_index(st^, project, name) < 0 {
				return fail(fmt.tprintf("project %s has no milestone %s", project, name)), false
			}
			count := 0
			for t in st.tasks {
				if t.project == project && t.milestone == name {
					count += 1
				}
			}
			if count > 0 {
				return fail(fmt.tprintf("milestone %s still has %d task(s); move them first", name, count)), false
			}
			kept := make([dynamic]Milestone, context.temp_allocator)
			for m in st.milestones {
				if !(m.project == project && m.name == name) {
					append(&kept, m)
				}
			}
			st.milestones = kept[:]
			return ok_result(fmt.tprintf("milestone %s deleted from %s", name, project)), true
		}, args)
}
