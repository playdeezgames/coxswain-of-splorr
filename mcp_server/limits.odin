package mcp_server

import "core:fmt"

// Caps that keep the store file and every reply a sane size. Lengths are in bytes. A refusal names
// the limit; nothing is ever truncated silently.
MAX_TITLE :: 200
MAX_DESCRIPTION :: 10_000 // tasks, projects and milestones
MAX_NOTE :: 4_000
MAX_DOING :: 200
MAX_AGENT_NAME :: 64
MAX_TASKS :: 10_000
MAX_NOTES_PER_TASK :: 200
MAX_AGENTS :: 200

// The refusal when text is over max bytes; what names the field ("title", "note", ...).
too_long :: proc(what, text: string, max: int) -> (res: Tool_Result, ok: bool) {
	if len(text) > max {
		return fail(fmt.tprintf("%s is %d characters; the limit is %d", what, len(text), max)), false
	}
	return {}, true
}

// Why a note cannot be added to t, as a refusal.
check_note :: proc(t: Task, text: string) -> (res: Tool_Result, ok: bool) {
	if r, good := too_long("note", text, MAX_NOTE); !good {
		return r, false
	}
	if len(t.notes) >= MAX_NOTES_PER_TASK {
		return fail(fmt.tprintf("task %d already has %d notes, the limit", t.id, MAX_NOTES_PER_TASK)), false
	}
	return {}, true
}
