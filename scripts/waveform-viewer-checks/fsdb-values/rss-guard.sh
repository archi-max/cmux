#!/bin/bash
# run.sh fsdb-values, on the host: runs a command in its own session and stops that session
# (only it) if one of its processes passes <per-process MB> of RSS or all of them together
# pass <total MB>, so a check can't crowd out other work on a shared host.
# Usage: rss-guard.sh <per-process MB> <total MB> <command...>
per=$(( $1 * 1024 )) total=$(( $2 * 1024 )); shift 2
setsid "$@" &
pid=$!
while kill -0 "$pid" 2>/dev/null; do
  rss=$(ps -o rss= -s "$pid" 2>/dev/null)
  max=0 sum=0
  for r in $rss; do sum=$((sum + r)); [ "$r" -gt "$max" ] && max=$r; done
  if [ "$max" -gt "$per" ] || [ "$sum" -gt "$total" ]; then
    echo "FAIL rss-guard: stopped the check (largest ${max} KB, total ${sum} KB)"
    kill -TERM -- "-$pid" 2>/dev/null; sleep 2; kill -KILL -- "-$pid" 2>/dev/null
    wait "$pid"; exit 99
  fi
  sleep 0.5
done
wait "$pid"
