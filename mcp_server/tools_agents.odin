package mcp_server

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// An agent that has not been seen for this long is reported as not active (agent_list can override).
DEFAULT_STALE_SECONDS :: 300

agent_tools :: proc() -> []Tool {
	@(static) table := [?]Tool {
		{
			name = "agent_register",
			description = "Announce this session as an agent (name from agent, else the server's --agent) with an optional line about what it is doing. Registering again just refreshes it. Call agent_heartbeat now and then so others can tell you are alive.",
			schema = `{"type":"object","properties":{"agent":{"type":"string"},"doing":{"type":"string"}}}`,
			run = tool_agent_register,
		},
		{
			name = "agent_heartbeat",
			description = "Mark an agent as alive now, optionally updating its doing line. The agent must be registered.",
			schema = `{"type":"object","properties":{"agent":{"type":"string"},"doing":{"type":"string"}}}`,
			run = tool_agent_heartbeat,
		},
		{
			name = "agent_list",
			description = "List registered agents with seconds since each was last seen, whether it is active (seen within stale_after seconds, default 300), and the tasks it has claimed.",
			schema = `{"type":"object","properties":{"stale_after":{"type":"integer"}}}`,
			run = tool_agent_list,
		},
		{
			name = "task_release_stale",
			description = "Find claimed tasks whose assignee is registered but has not been seen for more than stale_after seconds (default 300), so a crashed session does not hold them forever. Without release it only lists them; with release true it gives each back (status open) and adds a note saying why. Claims by agents that are not registered are listed under unregistered and never released, since there is no last_seen to judge them by.",
			schema = `{"type":"object","properties":{"stale_after":{"type":"integer"},"release":{"type":"boolean"},"agent":{"type":"string"}}}`,
			run = tool_task_release_stale,
		},
		{
			name = "agent_unregister",
			description = "Remove an agent from the registry. Its claimed tasks stay claimed (release them first, or another agent can release with force).",
			schema = `{"type":"object","properties":{"agent":{"type":"string"}}}`,
			run = tool_agent_unregister,
		},
	}
	return table[:]
}

agent_json :: proc(st: Store, a: Agent, stale_after: int, now: i64) -> string {
	b := strings.builder_make(context.temp_allocator)
	age := max(now - a.last_seen, 0)
	fmt.sbprintf(&b, `{{"name":%s,"doing":%s,"last_seen":%d,"seconds_since_seen":%d,"active":%v,"claimed":[`, quote(a.name), quote(a.doing), a.last_seen, age, age <= i64(stale_after))
	n := 0
	for t in st.tasks {
		if t.status == .Claimed && t.assignee == a.name {
			fmt.sbprintf(&b, "%s%d", n > 0 ? "," : "", t.id)
			n += 1
		}
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// Adds or replaces the entry for name, leaving doing alone when the caller gave none.
touch_agent :: proc(st: ^Store, name: string, doing: string, has_doing: bool, create: bool) -> (idx: int, ok: bool) {
	i := agent_index(st^, name)
	if i < 0 {
		if !create {
			return -1, false
		}
		agents := make([dynamic]Agent, context.temp_allocator)
		append(&agents, ..st.agents)
		append(&agents, Agent{name = name})
		st.agents = agents[:]
		i = len(st.agents) - 1
	}
	st.agents[i].last_seen = now_unix()
	if has_doing {
		st.agents[i].doing = doing
	}
	return i, true
}

// Counts a tool call as a heartbeat for the agent it names (args.agent, else the server's --agent),
// if that agent is registered. Never registers anyone. Call it only on a path that saves.
refresh_agent :: proc(s: ^Server, st: ^Store, args: json.Object) {
	name, _ := arg_string(args, "agent")
	if name == "" {
		name = s.agent
	}
	if name != "" {
		touch_agent(st, name, "", false, false)
	}
}

with_agent :: proc(s: ^Server, args: json.Object, body: proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool)) -> Tool_Result {
	agent, r, ok := acting_agent(s, args)
	if !ok {
		return r
	}
	args := args
	args["agent"] = json.String(agent)
	return with_store(s, body, args)
}

tool_agent_register :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_agent(s, args, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			name, _ := arg_string(args, "agent")
			doing, has := arg_string(args, "doing")
			i, _ := touch_agent(st, name, doing, has, true)
			return ok_result(agent_json(st^, st.agents[i], DEFAULT_STALE_SECONDS, now_unix())), true
		})
}

tool_agent_heartbeat :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_agent(s, args, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			name, _ := arg_string(args, "agent")
			doing, has := arg_string(args, "doing")
			i, ok := touch_agent(st, name, doing, has, false)
			if !ok {
				return fail(fmt.tprintf("%s is not registered (call agent_register first)", name)), false
			}
			return ok_result(agent_json(st^, st.agents[i], DEFAULT_STALE_SECONDS, now_unix())), true
		})
}

tool_agent_list :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			stale := DEFAULT_STALE_SECONDS
			if _, has := args["stale_after"]; has {
				v, ok := arg_int(args, "stale_after")
				if !ok || v < 0 {
					return fail("stale_after is a number of seconds (0 or more)"), false
				}
				stale = v
			}
			now := now_unix()
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, "[")
			for a, i in st.agents {
				fmt.sbprintf(&b, "%s%s", i > 0 ? "," : "", agent_json(st^, a, stale, now))
			}
			strings.write_string(&b, "]")
			return ok_result(strings.to_string(b)), false
		}, args)
}

tool_agent_unregister :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_agent(s, args, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			name, _ := arg_string(args, "agent")
			i := agent_index(st^, name)
			if i < 0 {
				return fail(fmt.tprintf("%s is not registered", name)), false
			}
			kept := make([dynamic]Agent, context.temp_allocator)
			for a, j in st.agents {
				if j != i {
					append(&kept, a)
				}
			}
			st.agents = kept[:]
			return ok_result(fmt.tprintf("%s unregistered", name)), true
		})
}

tool_task_release_stale :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			stale := DEFAULT_STALE_SECONDS
			if _, has := args["stale_after"]; has {
				v, ok := arg_int(args, "stale_after")
				if !ok || v < 0 {
					return fail("stale_after is a number of seconds (0 or more)"), false
				}
				stale = v
			}
			release := arg_bool(args, "release")
			who, _ := arg_string(args, "agent")
			if who == "" {
				who = s.agent
			}
			author := who != "" ? who : "system"
			now := now_unix()
			stale_b := strings.builder_make(context.temp_allocator)
			unreg_b := strings.builder_make(context.temp_allocator)
			n_stale, n_unreg := 0, 0
			for &t in st.tasks {
				if t.status != .Claimed {
					continue
				}
				ai := agent_index(st^, t.assignee)
				if ai < 0 {
					fmt.sbprintf(&unreg_b, "%s%d", n_unreg > 0 ? "," : "", t.id)
					n_unreg += 1
					continue
				}
				age := max(now - st.agents[ai].last_seen, 0)
				if age <= i64(stale) {
					continue
				}
				fmt.sbprintf(&stale_b, `%s{{"id":%d,"title":%s,"assignee":%s,"seconds_since_seen":%d}}`, n_stale > 0 ? "," : "", t.id, quote(t.title), quote(t.assignee), age)
				n_stale += 1
				if release {
					append_note(&t, author, fmt.tprintf("released: %s was not seen for %d seconds (more than %d)", t.assignee, age, stale))
					record(&t, author, "released", fmt.tprintf("stale: %s not seen for %d seconds", t.assignee, age))
					t.status = .Open
					t.assignee = ""
}
			}
			if release {
				refresh_agent(s, st, args)
			}
			out := fmt.tprintf(`{{"released":%v,"stale":[%s],"unregistered":[%s]}}`, release, strings.to_string(stale_b), strings.to_string(unreg_b))
			return ok_result(out), release && n_stale > 0
		}, args)
}
