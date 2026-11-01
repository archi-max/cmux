# cmux driver tracing, the Verdi engine's session script (ours, GPL-3.0 like the rest of cmux's
# viewer resources; it only calls the host's installed Verdi, nothing of Verdi is copied here).
# Run by verdi-trace.sh as `verdi -nogui -dbdir <simv>.daidir -ssf <dump.fsdb> -play serve.tcl`:
# one warm session per waveform, so the KDB and the FSDB load once (about 16 s on a course CPU).
#
# Protocol: one JSON object per line on stdin, one per line on stdout (each after a newline, so a
# warning Verdi prints without one never shares its line), matched by id.
#   ready:   {"id":0,"ready":true,"engine":"verdi","fileUnit":"1ps","windowUnit":"1ps"}
#   {"id":1,"cmd":"active","signal":"tb.dut.q","time":60}
#       -> {"id":1,"ok":true,"scope":"tb.dut","file":"/abs/q.sv","line":34}   (srcActiveTrace at t:
#          the statement of the value's last transition, through port connections)
#   {"id":2,"cmd":"driver","signal":"tb.dut.q"} -> the same shape (srcTraceDriver: a static driver)
#   {"id":3,"cmd":"info"} -> {"id":3,"ok":true,"fileUnit":...,"windowUnit":...}
# Errors: {"id":n,"ok":false,"error":"notFound"|"badRequest"|"failed","message":"..."}.
fconfigure stdout -buffering line
fconfigure stdin -buffering line

proc jstr {s} {
  set out ""
  foreach ch [split $s ""] {
    scan $ch %c code
    if {$ch eq "\""} { append out "\\\"" } elseif {$ch eq "\\"} { append out "\\\\" } elseif {$code < 32} { append out [format "\\u%04x" $code] } else { append out $ch }
  }
  return "\"$out\""
}
proc say {text} { puts "\n$text" }
proc fail {id code message} { say "{\"id\":$id,\"ok\":false,\"error\":\"$code\",\"message\":[jstr $message]}" }
# A file Verdi names relative to the compile directory, made absolute.
proc absFile {f} {
  if {[file pathtype $f] eq "absolute"} { return [file normalize $f] }
  return [file normalize [file join $::env(CMUX_VERDI_COMPILE_DIR) $f]]
}
proc located {id r} {
  # A traced result is a list: scope, file, line.
  if {[llength $r] >= 3 && [string is integer -strict [lindex $r 2]]} {
    say "{\"id\":$id,\"ok\":true,\"scope\":[jstr [lindex $r 0]],\"file\":[jstr [absFile [lindex $r 1]]],\"line\":[lindex $r 2]}"
  } else {
    fail $id notFound $r
  }
}
proc units {} {
  set f ""; set w ""
  catch {set f [wvGetFileTimeUnit]}
  catch {set w [wvGetWindowTimeUnit]}
  return "\"fileUnit\":[jstr $f],\"windowUnit\":[jstr $w]"
}

say "{\"id\":0,\"ready\":true,\"engine\":\"verdi\",[units]}"
while {[gets stdin line] >= 0} {
  if {[string trim $line] eq ""} { continue }
  set id -1
  regexp {"id"\s*:\s*(-?[0-9]+)} $line -> id
  set cmd ""
  regexp {"cmd"\s*:\s*"([a-z]+)"} $line -> cmd
  set signal ""
  if {[regexp {"signal"\s*:\s*"((?:[^"\\]|\\.)*)"} $line -> raw]} {
    set signal [string map {\\\" \" \\\\ \\} $raw]
  }
  set time ""
  regexp {"time"\s*:\s*([0-9]+)} $line -> time
  if {$cmd eq "quit"} { break }
  if {$cmd eq "info"} { say "{\"id\":$id,\"ok\":true,[units]}"; continue }
  if {$cmd ne "active" && $cmd ne "driver"} { fail $id badRequest "unknown command $cmd"; continue }
  if {$signal eq "" || [string length $signal] > 4096} { fail $id badRequest "no signal"; continue }
  if {$cmd eq "active"} {
    if {$time eq ""} { fail $id badRequest "no time"; continue }
    if {[catch {srcSetCursorTime $time} r]} { fail $id failed $r; continue }
    if {[catch {srcActiveTrace $signal} r]} { fail $id failed $r; continue }
  } else {
    if {[catch {srcTraceDriver $signal} r]} { fail $id failed $r; continue }
  }
  located $id $r
}
debExit
