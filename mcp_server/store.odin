package mcp_server

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"

STORE_FILE :: "tasks.json"
LOCK_DIR :: "tasks.lock"
LOCK_STALE :: 30 * time.Second // a lock older than this belongs to a dead process
LOCK_WAIT :: 15 * time.Second // how long a tool waits for the lock before refusing

Status :: enum {
	Open,
	Claimed,
	Done,
}

Note :: struct {
	author: string,
	text:   string,
}

Task :: struct {
	id:          int,
	title:       string,
	description: string,
	status:      Status,
	assignee:    string,
	blocked_by:  []int,
	notes:       []Note,
	project:     string, // "" = in no project
	milestone:   string, // "" = in no milestone; only meaningful (and only allowed) with a project
}

// A project groups tasks. Projects are named, never numbered.
Project :: struct {
	name:        string,
	description: string,
}

// A milestone belongs to one project; its name is unique within that project.
Milestone :: struct {
	project:     string,
	name:        string,
	description: string,
}

// A registered session or agent. last_seen is seconds since 1970, set by registering or a heartbeat.
Agent :: struct {
	name:      string,
	doing:     string, // a free-text line about what it is working on
	last_seen: i64,
}

// The whole store as it is on disk. Everything loaded is on the temp allocator.
Store :: struct {
	next_id: int,
	tasks:   []Task,
	agents:  []Agent,
	projects:   []Project,
	milestones: []Milestone,
}

store_path :: proc(s: ^Server, name: string) -> string {
	dir := s.dir == "" ? "." : s.dir
	return filepath.join({dir, name}, context.temp_allocator) or_else name
}

// Takes the store's lock (a directory: creating one is atomic) and returns the unlock proc's work as
// ok. Callers `defer store_unlock(s)` after a successful lock.
store_lock :: proc(s: ^Server) -> bool {
	if s.dir != "" {
		os.make_directory_all(s.dir)
	}
	lock := store_path(s, LOCK_DIR)
	start := time.now()
	seed := u32(os.get_pid()) * 2654435761
	for time.since(start) < LOCK_WAIT {
		if err := os.make_directory(lock); err == nil {
			return true
		}
		if info, err := os.stat(lock, context.temp_allocator); err == nil && time.since(info.modification_time) > LOCK_STALE {
			os.remove(lock)
			continue
		}
		// Jittered backoff, so waiters do not retry in step and starve one another.
		seed = seed * 1664525 + 1013904223
		time.sleep(time.Duration(2 + (seed >> 16) % 28) * time.Millisecond)
	}
	return false
}

store_unlock :: proc(s: ^Server) {
	os.remove(store_path(s, LOCK_DIR))
}

// Reads the store; a missing file is an empty store.
store_load :: proc(s: ^Server) -> (st: Store, ok: bool) {
	path := store_path(s, STORE_FILE)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return Store{next_id = 1}, !os.exists(path)
	}
	if uerr := json.unmarshal(data, &st, .JSON, context.temp_allocator); uerr != nil {
		return {}, false
	}
	if st.next_id < 1 {
		st.next_id = 1
	}
	return st, true
}

// Writes the store through a temp file and a rename, so a reader never sees half of it.
store_save :: proc(s: ^Server, st: Store) -> bool {
	st := st
	text, merr := json.marshal(st, {pretty = true, use_enum_names = true}, context.temp_allocator)
	if merr != nil {
		return false
	}
	path := store_path(s, STORE_FILE)
	tmp := fmt.tprintf("%s.%d.tmp", path, os.get_pid())
	if err := os.write_entire_file(tmp, text); err != nil {
		return false
	}
	return os.rename(tmp, path) == nil
}

task_index :: proc(st: Store, id: int) -> int {
	for t, i in st.tasks {
		if t.id == id {
			return i
		}
	}
	return -1
}

// A task is blocked while any task it names is not Done.
task_blocked_by_open :: proc(st: Store, t: Task) -> (id: int, blocked: bool) {
	for b in t.blocked_by {
		if i := task_index(st, b); i >= 0 && st.tasks[i].status != .Done {
			return b, true
		}
	}
	return 0, false
}

agent_index :: proc(st: Store, name: string) -> int {
	for a, i in st.agents {
		if a.name == name {
			return i
		}
	}
	return -1
}

now_unix :: proc() -> i64 {
	return i64(time.to_unix_seconds(time.now()))
}

project_index :: proc(st: Store, name: string) -> int {
	for p, i in st.projects {
		if p.name == name {
			return i
		}
	}
	return -1
}

milestone_index :: proc(st: Store, project, name: string) -> int {
	for m, i in st.milestones {
		if m.project == project && m.name == name {
			return i
		}
	}
	return -1
}
