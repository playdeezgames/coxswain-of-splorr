package mcp_server

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

// The release schedule. The rule it enforces: at most one release a day. Every ship that is not
// cancelled holds its calendar day (the day it is scheduled for, or the day it really shipped), and no
// two hold the same one. Days are the server's local days.

ship_tools :: proc() -> []Tool {
	@(static) table := [?]Tool {
		{
			name = "ship_today",
			description = "Ask this before releasing anything: today's date, whether today's one release slot is free (may_ship_now), what holds it if not, the next free day, and the coming schedule. Only one release may go out per day.",
			schema = `{"type":"object","properties":{}}`,
			run = tool_ship_today,
		},
		{
			name = "ship_schedule",
			description = "Book a release on a day. The day must be today or later and not held by another release; a refusal names the holder and the next free day. Without date it takes the next free day. Dates are YYYY-MM-DD.",
			schema = `{"type":"object","properties":{"title":{"type":"string"},"date":{"type":"string"},"project":{"type":"string"},"url":{"type":"string"},"note":{"type":"string"},"agent":{"type":"string"}},"required":["title"]}`,
			run = tool_ship_schedule,
		},
		{
			name = "ship_list",
			description = "List releases in date order. Cancelled releases are hidden unless status is cancelled or include_cancelled is true. Optional filters: status (scheduled, shipped, cancelled), project, from and to (inclusive dates).",
			schema = `{"type":"object","properties":{"status":{"type":"string"},"project":{"type":"string"},"from":{"type":"string"},"to":{"type":"string"},"include_cancelled":{"type":"boolean"}}}`,
			run = tool_ship_list,
		},
		{
			name = "ship_reschedule",
			description = "Move a scheduled release to another day (today or later, and free).",
			schema = `{"type":"object","properties":{"id":{"type":"integer"},"date":{"type":"string"},"agent":{"type":"string"}},"required":["id","date"]}`,
			run = tool_ship_reschedule,
		},
		{
			name = "ship_update",
			description = "Correct a scheduled release: any of title, project, url, note and date (an empty string clears project, url or note). The date follows the same rules as ship_reschedule, and changing only the text never touches the release's day.",
			schema = `{"type":"object","properties":{"id":{"type":"integer"},"title":{"type":"string"},"project":{"type":"string"},"url":{"type":"string"},"note":{"type":"string"},"date":{"type":"string"},"agent":{"type":"string"}},"required":["id"]}`,
			run = tool_ship_update,
		},
		{
			name = "ship_complete",
			description = "Record that a scheduled release is now live (call it when you publish, not before). Refused if another release already holds or used today; refused before the release's own day unless force is true (force never gets round the one-a-day rule). The release's date becomes today. url says where it went live.",
			schema = `{"type":"object","properties":{"id":{"type":"integer"},"url":{"type":"string"},"note":{"type":"string"},"force":{"type":"boolean"},"agent":{"type":"string"}},"required":["id"]}`,
			run = tool_ship_complete,
		},
		{
			name = "ship_cancel",
			description = "Drop a scheduled release; its day becomes free. A release that has shipped cannot be cancelled.",
			schema = `{"type":"object","properties":{"id":{"type":"integer"},"note":{"type":"string"},"agent":{"type":"string"}},"required":["id"]}`,
			run = tool_ship_cancel,
		},
	}
	return table[:]
}

// "YYYY-MM-DD" as a day number, or false if it is not a real date in exactly that form.
date_ordinal :: proc(text: string) -> (datetime.Ordinal, bool) {
	if len(text) != 10 || text[4] != '-' || text[7] != '-' {
		return 0, false
	}
	for c, i in transmute([]u8)text {
		if i != 4 && i != 7 && (c < '0' || c > '9') {
			return 0, false
		}
	}
	n :: proc(t: string) -> i64 {
		v: i64
		for c in transmute([]u8)t {
			v = v * 10 + i64(c - '0')
		}
		return v
	}
	date, err := datetime.components_to_date(n(text[0:4]), n(text[5:7]), n(text[8:10]))
	if err != nil {
		return 0, false
	}
	o, err2 := datetime.date_to_ordinal(date)
	return o, err2 == nil
}

date_text :: proc(o: datetime.Ordinal) -> string {
	d, _ := datetime.ordinal_to_date(o)
	return fmt.tprintf("%04d-%02d-%02d", d.year, d.month, d.day)
}

// Today's day number: the test override if set, else the local calendar day.
today_ordinal :: proc(s: ^Server) -> datetime.Ordinal {
	if s.today != "" {
		if o, ok := date_ordinal(s.today); ok {
			return o
		}
	}
	dt, _ := time.time_to_datetime(time.now())
	if reg, ok := timezone.region_load("local", context.temp_allocator); ok && reg != nil {
		if local, ok2 := timezone.datetime_to_tz(dt, reg); ok2 {
			dt = local
		}
	}
	o, _ := datetime.date_to_ordinal(dt.date)
	return o
}

ship_index :: proc(st: Store, id: int) -> int {
	for sh, i in st.ships {
		if sh.id == id {
			return i
		}
	}
	return -1
}

// The ship (other than except) holding day o, or -1.
day_holder :: proc(st: Store, o: datetime.Ordinal, except: int) -> int {
	for sh, i in st.ships {
		if sh.id != except && sh.status != .Cancelled {
			if so, ok := date_ordinal(sh.date); ok && so == o {
				return i
			}
		}
	}
	return -1
}

// The first free day on or after from.
next_free_day :: proc(st: Store, from: datetime.Ordinal) -> datetime.Ordinal {
	o := from
	for day_holder(st, o, 0) >= 0 {
		o += 1
	}
	return o
}

ship_status_name :: proc(s: Ship_Status) -> string {
	switch s {
	case .Scheduled:
		return "scheduled"
	case .Shipped:
		return "shipped"
	case .Cancelled:
		return "cancelled"
	}
	return "?"
}

ship_json :: proc(sh: Ship) -> string {
	return fmt.tprintf(`{{"id":%d,"title":%s,"project":%s,"date":%s,"status":%s,"url":%s,"note":%s,"created_by":%s,"shipped_by":%s}}`, sh.id, quote(sh.title), quote(sh.project), quote(sh.date), quote(ship_status_name(sh.status)), quote(sh.url), quote(sh.note), quote(sh.created_by), quote(sh.shipped_by))
}

// Ships that are not cancelled, in date order.
live_ships :: proc(st: Store) -> []Ship {
	list := make([dynamic]Ship, context.temp_allocator)
	for sh in st.ships {
		if sh.status != .Cancelled {
			append(&list, sh)
		}
	}
	slice.sort_by(list[:], proc(a, b: Ship) -> bool {return a.date < b.date})
	return list[:]
}

// The refusal for a day someone else holds.
day_taken :: proc(st: Store, o: datetime.Ordinal, h: int) -> Tool_Result {
	sh := st.ships[h]
	verb := sh.status == .Shipped ? "already shipped" : "is booked for"
	return fail(fmt.tprintf("%s is taken: ship %d (%s) %s that day; only one release a day. The next free day is %s", date_text(o), sh.id, sh.title, verb, date_text(next_free_day(st, o))))
}

arg_date :: proc(args: json.Object, key: string) -> (o: datetime.Ordinal, res: Tool_Result, ok: bool) {
	text, has := arg_string(args, key)
	if !has {
		return 0, fail(fmt.tprintf("%s is required (YYYY-MM-DD)", key)), false
	}
	o, ok = date_ordinal(text)
	if !ok {
		return 0, fail(fmt.tprintf("%s %q is not a date; use YYYY-MM-DD", key, text)), false
	}
	return o, {}, true
}

tool_ship_today :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			today := today_ordinal(s)
			holder := day_holder(st^, today, 0)
			b := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&b, `{{"today":%s,"may_ship_now":%v,"today_holder":`, quote(date_text(today)), holder < 0 || st.ships[holder].status == .Scheduled)
			if holder >= 0 {
				strings.write_string(&b, ship_json(st.ships[holder]))
			} else {
				strings.write_string(&b, "null")
			}
			fmt.sbprintf(&b, `,"next_free_day":%s,"upcoming":[`, quote(date_text(next_free_day(st^, today))))
			n := 0
			for sh in live_ships(st^) {
				if o, ok := date_ordinal(sh.date); ok && o >= today && sh.status == .Scheduled {
					fmt.sbprintf(&b, "%s%s", n > 0 ? "," : "", ship_json(sh))
					n += 1
				}
			}
			strings.write_string(&b, "]}")
			return ok_result(strings.to_string(b)), false
		}, args)
}

tool_ship_schedule :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			title, r, ok := need_string(args, "title")
			if !ok {
				return r, false
			}
			if strings.trim_space(title) == "" {
				return fail("title is empty"), false
			}
			if r, ok := too_long("title", title, MAX_TITLE); !ok {
				return r, false
			}
			project, _ := arg_string(args, "project")
			if project != "" && project_index(st^, project) < 0 {
				return fail(fmt.tprintf("no project %s", project)), false
			}
			url, _ := arg_string(args, "url")
			note, _ := arg_string(args, "note")
			if r, ok := too_long("url", url, MAX_URL); !ok {
				return r, false
			}
			if r, ok := too_long("note", note, MAX_NOTE); !ok {
				return r, false
			}
			if len(st.ships) >= MAX_SHIPS {
				return fail(fmt.tprintf("the store already has %d ships, the limit", MAX_SHIPS)), false
			}
			today := today_ordinal(s)
			day := today
			if _, has := args["date"]; has {
				d, r, ok := arg_date(args, "date")
				if !ok {
					return r, false
				}
				if d < today {
					return fail(fmt.tprintf("%s is in the past; today is %s", date_text(d), date_text(today))), false
				}
				if h := day_holder(st^, d, 0); h >= 0 {
					return day_taken(st^, d, h), false
				}
				day = d
			} else {
				day = next_free_day(st^, today)
			}
			sh := Ship{id = st.next_ship_id, title = title, project = project, date = date_text(day), status = .Scheduled, url = url, note = note, created_by = actor(s, args)}
			st.next_ship_id += 1
			list := make([dynamic]Ship, context.temp_allocator)
			append(&list, ..st.ships)
			append(&list, sh)
			st.ships = list[:]
			refresh_agent(s, st, args)
			return ok_result(ship_json(sh)), true
		}, args)
}

tool_ship_list :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			status, _ := arg_string(args, "status")
			project, _ := arg_string(args, "project")
			include_cancelled := arg_bool(args, "include_cancelled")
			if status != "" && status != "scheduled" && status != "shipped" && status != "cancelled" {
				return fail("status is scheduled, shipped or cancelled"), false
			}
			from, to: datetime.Ordinal
			has_from, has_to: bool
			if _, has := args["from"]; has {
				r: Tool_Result
				from, r, has_from = arg_date(args, "from")
				if !has_from {
					return r, false
				}
			}
			if _, has := args["to"]; has {
				r: Tool_Result
				to, r, has_to = arg_date(args, "to")
				if !has_to {
					return r, false
				}
			}
			all := make([dynamic]Ship, context.temp_allocator)
			append(&all, ..st.ships)
			slice.stable_sort_by(all[:], proc(a, b: Ship) -> bool {return a.date < b.date})
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, "[")
			n := 0
			for sh in all {
				o, _ := date_ordinal(sh.date)
				if (status == "" && !include_cancelled && sh.status == .Cancelled) || (status != "" && ship_status_name(sh.status) != status) || (project != "" && sh.project != project) || (has_from && o < from) || (has_to && o > to) {
					continue
				}
				fmt.sbprintf(&b, "%s%s", n > 0 ? "," : "", ship_json(sh))
				n += 1
			}
			strings.write_string(&b, "]")
			return ok_result(strings.to_string(b)), false
		}, args)
}

// The scheduled ship named by args["id"].
find_scheduled_ship :: proc(st: ^Store, args: json.Object) -> (idx: int, res: Tool_Result, ok: bool) {
	id, r, good := need_int(args, "id")
	if !good {
		return 0, r, false
	}
	idx = ship_index(st^, id)
	if idx < 0 {
		return 0, fail(fmt.tprintf("no ship %d", id)), false
	}
	if st.ships[idx].status != .Scheduled {
		return 0, fail(fmt.tprintf("ship %d is %s, not scheduled", id, ship_status_name(st.ships[idx].status))), false
	}
	return idx, {}, true
}

tool_ship_reschedule :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			i, r, ok := find_scheduled_ship(st, args)
			if !ok {
				return r, false
			}
			d, r2, ok2 := arg_date(args, "date")
			if !ok2 {
				return r2, false
			}
			today := today_ordinal(s)
			if d < today {
				return fail(fmt.tprintf("%s is in the past; today is %s", date_text(d), date_text(today))), false
			}
			if h := day_holder(st^, d, st.ships[i].id); h >= 0 {
				return day_taken(st^, d, h), false
			}
			st.ships[i].date = date_text(d)
			refresh_agent(s, st, args)
			return ok_result(ship_json(st.ships[i])), true
		}, args)
}

tool_ship_update :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			i, r, ok := find_scheduled_ship(st, args)
			if !ok {
				return r, false
			}
			sh := st.ships[i]
			changed := false
			if _, has := args["title"]; has {
				title, _ := arg_string(args, "title")
				if strings.trim_space(title) == "" {
					return fail("title is empty"), false
				}
				if r, ok := too_long("title", title, MAX_TITLE); !ok {
					return r, false
				}
				sh.title = title
				changed = true
			}
			if _, has := args["project"]; has {
				project, _ := arg_string(args, "project")
				if project != "" && project_index(st^, project) < 0 {
					return fail(fmt.tprintf("no project %s", project)), false
				}
				sh.project = project
				changed = true
			}
			if _, has := args["url"]; has {
				url, _ := arg_string(args, "url")
				if r, ok := too_long("url", url, MAX_URL); !ok {
					return r, false
				}
				sh.url = url
				changed = true
			}
			if _, has := args["note"]; has {
				note, _ := arg_string(args, "note")
				if r, ok := too_long("note", note, MAX_NOTE); !ok {
					return r, false
				}
				sh.note = note
				changed = true
			}
			if _, has := args["date"]; has {
				d, r2, ok2 := arg_date(args, "date")
				if !ok2 {
					return r2, false
				}
				if date_text(d) != sh.date {
					today := today_ordinal(s)
					if d < today {
						return fail(fmt.tprintf("%s is in the past; today is %s", date_text(d), date_text(today))), false
					}
					if h := day_holder(st^, d, sh.id); h >= 0 {
						return day_taken(st^, d, h), false
					}
					sh.date = date_text(d)
					changed = true
				}
			}
			if !changed {
				return fail("nothing to change: give title, project, url, note or date"), false
			}
			st.ships[i] = sh
			refresh_agent(s, st, args)
			return ok_result(ship_json(sh)), true
		}, args)
}

tool_ship_complete :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			i, r, ok := find_scheduled_ship(st, args)
			if !ok {
				return r, false
			}
			url, _ := arg_string(args, "url")
			note, _ := arg_string(args, "note")
			if r, ok := too_long("url", url, MAX_URL); !ok {
				return r, false
			}
			if r, ok := too_long("note", note, MAX_NOTE); !ok {
				return r, false
			}
			today := today_ordinal(s)
			planned, _ := date_ordinal(st.ships[i].date)
			if planned > today && !arg_bool(args, "force") {
				return fail(fmt.tprintf("ship %d is booked for %s and today is %s; ship it on its day (force true overrides this, not the one-a-day rule)", st.ships[i].id, st.ships[i].date, date_text(today))), false
			}
			if h := day_holder(st^, today, st.ships[i].id); h >= 0 {
				return day_taken(st^, today, h), false
			}
			sh := &st.ships[i]
			sh.date = date_text(today)
			sh.status = .Shipped
			sh.shipped_by = actor(s, args)
			if url != "" {
				sh.url = url
			}
			if note != "" {
				sh.note = note
			}
			refresh_agent(s, st, args)
			return ok_result(ship_json(sh^)), true
		}, args)
}

tool_ship_cancel :: proc(s: ^Server, args: json.Object) -> Tool_Result {
	return with_store(s, proc(s: ^Server, st: ^Store, args: json.Object) -> (Tool_Result, bool) {
			i, r, ok := find_scheduled_ship(st, args)
			if !ok {
				return r, false
			}
			note, _ := arg_string(args, "note")
			if r, ok := too_long("note", note, MAX_NOTE); !ok {
				return r, false
			}
			st.ships[i].status = .Cancelled
			if note != "" {
				st.ships[i].note = note
			}
			refresh_agent(s, st, args)
			return ok_result(ship_json(st.ships[i])), true
		}, args)
}
