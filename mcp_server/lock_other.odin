#+build !linux
package mcp_server

import "core:os"
import "core:time"

LOCK_DIR :: "tasks.lock"
LOCK_STALE :: 30 * time.Second // a lock older than this is taken to belong to a dead process

// Takes the store's lock where flock is not wired up: a directory (creating one is atomic). A lock
// older than LOCK_STALE is removed and retaken, which is not itself race-free (two waiters can both
// remove it and one can delete the other's fresh lock); the Linux build uses flock instead.
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
		seed = seed * 1664525 + 1013904223
		time.sleep(time.Duration(2 + (seed >> 16) % 28) * time.Millisecond)
	}
	return false
}

store_unlock :: proc(s: ^Server) {
	os.remove(store_path(s, LOCK_DIR))
}
