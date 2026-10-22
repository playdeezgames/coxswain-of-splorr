package mcp_server

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"

STORE_FILE :: "tasks.json"
// The on-disk format version. Bump it when the format changes in a way an older server would misread,
// and migrate older files in store_load. A file without "version" is version 0, the format before
// versions existed; it is read as it is and gets the current version on its next save.
STORE_VERSION :: 2 // 2: tasks have a priority (absent = 0, so version 0 and 1 files read as they are)
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
	priority:    int, // higher is more important; 0 unless set
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
	version: int,
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

// Reads the store; a missing file is an empty store. Otherwise problem says why the file could not be
// used ("" = fine). A bad file is never replaced: callers refuse and leave it for a person to look at.
store_load :: proc(s: ^Server) -> (st: Store, problem: string) {
	path := store_path(s, STORE_FILE)
	if !os.exists(path) {
		return Store{version = STORE_VERSION, next_id = 1}, ""
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}, fmt.tprintf("%s exists but could not be read (%v)", path, err)
	}
	if uerr := json.unmarshal(data, &st, .JSON, context.temp_allocator); uerr != nil {
		return {}, fmt.tprintf("%s is not a valid task store (%v); it was left untouched", path, uerr)
	}
	if st.version < 0 || st.version > STORE_VERSION {
		return {}, fmt.tprintf("%s has store version %d, but this server only understands up to %d; update the server (the file was left untouched)", path, st.version, STORE_VERSION)
	}
	st.version = STORE_VERSION
	if st.next_id < 1 {
		st.next_id = 1
	}
	return st, ""
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
