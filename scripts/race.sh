#!/usr/bin/env bash
# Multi-process claim test: N separate coxswain_mcp processes (as N sessions would be) all try to
# claim the same tasks at once. Each task must be won by exactly one of them, and every process must
# see a consistent store. Usage: scripts/race.sh [processes] [tasks]   (needs build/coxswain_mcp)
set -euo pipefail
cd "$(dirname "$0")/.."

procs="${1:-8}"
tasks="${2:-20}"
bin=build/coxswain_mcp
[ -x "$bin" ] || { echo "build it first: ./build.sh mcp" >&2; exit 2; }

dir="$(mktemp -d /tmp/coxswain_race.XXXXXX)"
trap 'rm -rf "$dir"' EXIT

# Seed the tasks.
{
	for i in $(seq 1 "$tasks"); do
		echo "{\"jsonrpc\":\"2.0\",\"id\":$i,\"method\":\"tools/call\",\"params\":{\"name\":\"task_create\",\"arguments\":{\"title\":\"t$i\"}}}"
	done
} | "$bin" --dir "$dir" --agent seed >/dev/null

# Each process claims every task, in the same order, and logs the replies.
for p in $(seq 1 "$procs"); do
	(
		for i in $(seq 1 "$tasks"); do
			echo "{\"jsonrpc\":\"2.0\",\"id\":$i,\"method\":\"tools/call\",\"params\":{\"name\":\"task_claim\",\"arguments\":{\"id\":$i}}}"
		done | "$bin" --dir "$dir" --agent "agent$p" >"$dir/out.$p"
	) &
done
wait

fail=0
total_wins=0
for p in $(seq 1 "$procs"); do
	wins=$(grep -c '"isError":false' "$dir/out.$p" || true)
	total_wins=$((total_wins + wins))
	if grep -q 'could not lock' "$dir/out.$p"; then
		echo "FAIL: agent$p timed out waiting for the lock"; fail=1
	fi
done
if [ "$total_wins" -ne "$tasks" ]; then
	echo "FAIL: $total_wins successful claims for $tasks tasks (each should be won exactly once)"; fail=1
fi

# Every task is claimed, and by someone who reported winning it.
list=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"task_list","arguments":{"status":"claimed"}}}' | "$bin" --dir "$dir" --agent check)
claimed=$(grep -o '\\"status\\":\\"claimed\\"' <<<"$list" | wc -l)
if [ "$claimed" -ne "$tasks" ]; then
	echo "FAIL: $claimed tasks are claimed in the store, expected $tasks"; fail=1
fi

[ "$fail" -eq 0 ] && echo "ok: $procs processes, $tasks tasks, each claimed exactly once"
exit "$fail"
