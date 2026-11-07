#!/bin/bash
# verdi-trace.sh's session lifetime, with a stand-in `verdi` (no Verdi, licence or host needed):
# it answers one request, and it ends when nothing has asked for CMUX_VERDI_IDLE_SECONDS (a
# connection whose other end slept or vanished without closing never sends EOF), not before; and
# a Verdi that ends by itself (no licence seat) is reported at once, with its message. Without
# Verdi the error names the variables to set, and a CMUX_VERDI_SETUP that hangs is ended at its cap.
# Usage: check.sh <verdi-trace.sh>
LAUNCHER=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/verdi-launch.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/run/simv.daidir/kdb.elab++" "$T/w1" "$T/w2" "$T/w3"
: > "$T/run/d.fsdb"
cat > "$T/bin/verdi" <<'FAKE'
#!/bin/bash
if [ "${FAKE_MODE:-}" = licence ]; then echo "Error: could not checkout license for Verdi"; exit 1; fi
printf '\n{"id":0,"ready":true,"engine":"verdi"}\n'
while IFS= read -r line; do printf '\n{"id":1,"ok":true,"echo":"%s"}\n' "${#line}"; done
echo ended > "$FAKE_MARK"
FAKE
chmod +x "$T/bin/verdi"
failures=0
expect() { if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; failures=$((failures + 1)); fi; }

# 1. A request is answered; the session ends at stdin's end.
mkfifo "$T/in1"
( sleep 1; printf '{"id":1,"cmd":"info"}\n'; sleep 1 ) > "$T/in1" &
PATH="$T/bin:$PATH" FAKE_MARK="$T/mark1" CMUX_VERDI_IDLE_SECONDS=30 bash "$LAUNCHER" "$T/w1" "$T/run/d.fsdb" < "$T/in1" > "$T/out1" 2>/dev/null &
L1=$!
for _ in $(seq 1 20); do kill -0 $L1 2>/dev/null || break; sleep 0.5; done
grep -q '"id":1,"ok":true' "$T/out1"; expect $? "a request is answered"
[ -f "$T/mark1" ]; expect $? "Verdi ends at stdin's end"

# 2. stdin stays open but nothing comes (the client slept): Verdi ends after the idle limit.
mkfifo "$T/in2"
sleep 60 > "$T/in2" &
PATH="$T/bin:$PATH" FAKE_MARK="$T/mark2" CMUX_VERDI_IDLE_SECONDS=3 bash "$LAUNCHER" "$T/w2" "$T/run/d.fsdb" < "$T/in2" > "$T/out2" 2>/dev/null &
L2=$!
S2=$(date +%s)
for _ in $(seq 1 30); do [ -f "$T/mark2" ] && break; sleep 0.5; done
E2=$(( $(date +%s) - S2 ))
[ -f "$T/mark2" ]; expect $? "Verdi ends when nothing asks for CMUX_VERDI_IDLE_SECONDS (3 s)"
# Not before: a read timeout is not stdin's end (bash 3.2's read -t says 1 for both).
[ "$E2" -ge 2 ]; expect $? "and not before it (ended after $E2 s)"
kill $L2 2>/dev/null

# 3. Verdi ends by itself (no licence seat) while stdin stays open: reported at once, as "licence".
mkfifo "$T/in3"
sleep 60 > "$T/in3" &
S3=$(date +%s)
PATH="$T/bin:$PATH" FAKE_MODE=licence CMUX_VERDI_IDLE_SECONDS=30 bash "$LAUNCHER" "$T/w3" "$T/run/d.fsdb" < "$T/in3" > "$T/out3" 2>/dev/null &
L3=$!
for _ in $(seq 1 20); do grep -q '"ready":false' "$T/out3" 2>/dev/null && break; sleep 0.25; done
E3=$(( $(date +%s) - S3 ))
grep -q '"error":"licence","message":"Error: could not checkout license' "$T/out3" && [ "$E3" -le 3 ]
expect $? "a Verdi without a licence seat is reported at once as licence (after $E3 s: $(tr -d '\n' < "$T/out3" | cut -c1-120))"
kill $L3 2>/dev/null
# 4. No verdi on PATH and nothing set: noVerdi, with the hint that names the variables to set.
mkdir -p "$T/w4" "$T/w5"
NOPATH=/usr/bin:/bin
env -u VERDI_HOME -u CMUX_VERDI_SETUP -u BASH_ENV PATH=$NOPATH bash "$LAUNCHER" "$T/w4" "$T/run/d.fsdb" < /dev/null > "$T/out4" 2>/dev/null
grep -q '"ready":false,"error":"noVerdi","message":".*VERDI_HOME.*CMUX_VERDI_SETUP' "$T/out4"
expect $? "no verdi and nothing set: noVerdi names VERDI_HOME and CMUX_VERDI_SETUP ($(tr -d '\n' < "$T/out4" | cut -c1-160))"

# 5. A CMUX_VERDI_SETUP that hangs is ended at its time cap (CMUX_VERDI_SETUP_SECONDS), with an
# error that says so.
S5=$(date +%s)
env -u VERDI_HOME -u BASH_ENV PATH=$NOPATH CMUX_VERDI_SETUP='sleep 27' CMUX_VERDI_SETUP_SECONDS=2 \
  bash "$LAUNCHER" "$T/w5" "$T/run/d.fsdb" < /dev/null > "$T/out5" 2>/dev/null
E5=$(( $(date +%s) - S5 ))
grep -q '"error":"noVerdi","message":"CMUX_VERDI_SETUP .*2 s.*CMUX_VERDI_SETUP_SECONDS' "$T/out5" && [ "$E5" -le 5 ] \
  && ! pgrep -u "$(id -u)" -f '^sleep 27$' >/dev/null
expect $? "a hung CMUX_VERDI_SETUP ends at its cap (after $E5 s: $(tr -d '\n' < "$T/out5" | cut -c1-160))"
pkill -u "$(id -u)" -f '^sleep 27$' 2>/dev/null
[ $failures = 0 ] && echo "VERDI LAUNCH CHECKS PASSED" || { echo "VERDI LAUNCH CHECKS FAILED: $failures"; exit 1; }
