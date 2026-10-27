// A read-only web view of the shared task store: projects, milestones, tasks and agents. Usage:
//
//     coxswain_web [--dir <folder>] [--port <n>]
//
// --dir is the folder holding tasks.json (default: the working directory); --port defaults to 8787.
// It listens on 127.0.0.1 only and never writes. The store is replaced by rename on every save, so
// reading the file without the lock always sees a whole version.
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

PAGE := #load("index.html", string)

MAX_REQUEST :: 8192

main :: proc() {
	dir, port := ".", 8787
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "--dir" && i + 1 < len(args):
			dir = args[i + 1]
			i += 1
		case args[i] == "--port" && i + 1 < len(args):
			n, ok := strconv.parse_int(args[i + 1])
			if !ok || n < 1 || n > 65535 {
				fmt.eprintfln("bad port %s", args[i + 1])
				os.exit(2)
			}
			port = n
			i += 1
		case:
			fmt.eprintfln("usage: coxswain_web [--dir <folder>] [--port <n>]")
			os.exit(2)
		}
	}
	store := filepath.join({dir, "tasks.json"}) or_else "tasks.json"

	listener, err := net.listen_tcp({address = net.IP4_Loopback, port = port})
	if err != nil {
		fmt.eprintfln("cannot listen on 127.0.0.1:%d (%v)", port, err)
		os.exit(1)
	}
	fmt.eprintfln("coxswain_web: http://127.0.0.1:%d/  (store %s)", port, store)
	for {
		client, _, aerr := net.accept_tcp(listener)
		if aerr != nil {
			continue
		}
		serve(client, store)
		net.close(client)
		free_all(context.temp_allocator)
	}
}

serve :: proc(client: net.TCP_Socket, store: string) {
	net.set_option(client, .Receive_Timeout, 3 * time.Second)
	buf: [MAX_REQUEST]u8
	got := 0
	for got < len(buf) {
		n, err := net.recv_tcp(client, buf[got:])
		if err != nil || n == 0 {
			break
		}
		got += n
		if strings.contains(string(buf[:got]), "\r\n\r\n") {
			break
		}
	}
	line, _, _ := strings.partition(string(buf[:got]), "\r\n")
	parts := strings.split(line, " ", context.temp_allocator)
	if len(parts) < 2 || parts[0] != "GET" {
		respond(client, "405 Method Not Allowed", "text/plain", "read-only")
		return
	}
	path, _, _ := strings.partition(parts[1], "?")
	switch path {
	case "/", "/index.html":
		respond(client, "200 OK", "text/html; charset=utf-8", PAGE)
	case "/api/state":
		data, rerr := os.read_entire_file(store, context.temp_allocator)
		body := rerr == nil ? string(data) : "{}"
		respond(client, "200 OK", "application/json", fmt.tprintf(`{{"now":%d,"store":%s}}`, time.to_unix_seconds(time.now()), body))
	case:
		respond(client, "404 Not Found", "text/plain", "not found")
	}
}

respond :: proc(client: net.TCP_Socket, status, kind, body: string) {
	head := fmt.tprintf("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", status, kind, len(body))
	net.send_tcp(client, transmute([]u8)head)
	rest := transmute([]u8)body
	for len(rest) > 0 {
		n, err := net.send_tcp(client, rest)
		if err != nil {
			return
		}
		rest = rest[n:]
	}
}
