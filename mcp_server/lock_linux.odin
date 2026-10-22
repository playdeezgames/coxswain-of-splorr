#+build linux
package mcp_server

import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

LOCK_FILE :: "tasks.flock"

// Takes the store's lock: an exclusive flock on a lock file. The kernel drops the lock when its
// holder dies, so there is never a stale lock to clean up (and no stealing, which cannot be done
// race-free). Waits up to LOCK_WAIT, retrying with jitter. Callers `defer store_unlock(s)` after a
// successful lock.
store_lock :: proc(s: ^Server) -> bool {
	if s.dir != "" {
		os.make_directory_all(s.dir)
	}
	path := store_path(s, LOCK_FILE)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	start := time.now()
	seed := u32(os.get_pid()) * 2654435761
	for {
		// A fresh open each attempt is harmless, and keeps the fd from lingering if we give up.
		fd, oerr := linux.open(cpath, {.CREAT, .RDWR, .CLOEXEC}, {.IRUSR, .IWUSR})
		if oerr != .NONE {
			return false
		}
		if linux.flock(fd, {.EX, .NB}) == .NONE {
			s.lock = int(fd)
			return true
		}
		linux.close(fd)
		if time.since(start) >= LOCK_WAIT {
			return false
		}
		// Jittered backoff, so waiters do not retry in step and starve one another.
		seed = seed * 1664525 + 1013904223
		time.sleep(time.Duration(2 + (seed >> 16) % 28) * time.Millisecond)
	}
}

// Releases the lock (closing the file drops it).
store_unlock :: proc(s: ^Server) {
	linux.close(linux.Fd(s.lock))
	s.lock = 0
}
