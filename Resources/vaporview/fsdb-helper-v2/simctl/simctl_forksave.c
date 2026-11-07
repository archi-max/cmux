/* SPDX-License-Identifier: MIT
 * simctl fork-save: a file save that does not pause the simulation. Included by simctl_vpi.c (one unit).
 *
 * `V id <file>` (served when idle and at a run's poll points): the library fork()s right there, at a
 * ReadOnlySynch. The parent answers {id, t, pid, forkMs, file} and goes on at once. The child:
 *   - stops serving (every library callback returns at once in it, and its copies of the channel are closed);
 *   - sends its output to <file>.log;
 *   - one time unit later (a writable region) sets simctl_saver.name and toggles simctl_saver.go, so the
 *     build's simctl_saver top runs the documented $save as the last event of that step;
 *   - at the next step's callback _exit()s: no end-of-simulation work, no licence check-in.
 * So the save holds the state at t+1. The build needs the simctl_saver top (vpi/simctl_saver.sv,
 * `-top simctl_saver`); without it V is refused. At most FS_MAX saves at once (more are refused, never
 * waited for, so the parent never blocks). When a child ends, the library sends {ev: saved, pid, file, t,
 * status} (status: the child's exit status, -1 if it could not be collected). The children are in the
 * simulation's process group, so they go with it.
 * A process restored from such a save (simv -r <file>) carries the child's state: its library stays inert. */
#include <sys/wait.h>

#define FS_MAX 2
static pid_t fs_child_pid;
static struct { pid_t pid; char *file; } fs_out[FS_MAX];
static char fs_file[1100];
static vpiHandle fs_name_h, fs_go_h;

static void fs_reap(void) {
  for (int i = 0; i < FS_MAX; i++) {
    if (!fs_out[i].pid) continue;
    int st = 0; pid_t r = waitpid(fs_out[i].pid, &st, WNOHANG);
    if (r == 0) continue;
    int status = r < 0 ? -1 : WIFEXITED(st) ? WEXITSTATUS(st) : 128 + (WIFSIGNALED(st) ? WTERMSIG(st) : 0);
    bfmt(&ob, "{\"ev\":\"saved\",\"pid\":%d,\"t\":%llu,\"status\":%d,\"file\":", (int)fs_out[i].pid, (unsigned long long)now(), status);
    bjson(&ob, fs_out[i].file); bstr(&ob, "}"); send_ob();
    free(fs_out[i].file); fs_out[i].pid = 0; fs_out[i].file = NULL; fs_alive--;
  }
}
static PLI_INT32 fs_exit(p_cb_data d) { (void)d; if (getpid() == fs_child_pid) _exit(0); return 0; }
static PLI_INT32 fs_trigger(p_cb_data d) {
  (void)d;
  if (getpid() != fs_child_pid) return 0;      /* restored from the save: not the child */
  s_vpi_value v; v.format = vpiStringVal; v.value.str = fs_file; vpi_put_value(fs_name_h, &v, NULL, vpiNoDelay);
  s_vpi_value g; g.format = vpiIntVal; vpi_get_value(fs_go_h, &g); g.value.integer = !g.value.integer; vpi_put_value(fs_go_h, &g, NULL, vpiNoDelay);
  vpiHandle h = after(1, fs_exit); if (h) vpi_release_handle(h);   /* $save runs as the last event of this step */
  return 0;
}
static void forksave(long id, const char *file, uint64_t t) {
  fs_reap();
  if (!file || !*file) { reply_err(id, "forksave: no file"); return; }
  if (strlen(file) >= sizeof fs_file || strlen(file) >= 1024) { reply_err(id, "forksave: file name too long (limit 1023)"); return; }
  if (!fs_name_h) { fs_name_h = vpi_handle_by_name("simctl_saver.name", NULL); fs_go_h = vpi_handle_by_name("simctl_saver.go", NULL); }
  if (!fs_name_h || !fs_go_h) { reply_err(id, "forksave: this build has no simctl_saver top (compile simctl_saver.sv with -top simctl_saver)"); return; }
  if (fs_alive >= FS_MAX) { reply_err(id, "forksave: two saves in progress; try again when one has ended"); return; }
  snprintf(fs_file, sizeof fs_file, "%s", file);
  fflush(NULL);
  double t0 = wall_ms();
  pid_t p = fork();
  if (p < 0) { reply_err(id, "forksave: fork failed"); return; }
  if (p == 0) {
    fs_child = 1; fs_child_pid = getpid();
    if (in_fd >= 0) close(in_fd);
    if (out_fd >= 0) close(out_fd);
    char lf[1200]; snprintf(lf, sizeof lf, "%s.log", fs_file);
    int o = open(lf, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (o >= 0) { dup2(o, 1); dup2(o, 2); close(o); }
    /* the simulator's command-line channel arrives on stdin: the child must not take the parent's input */
    int nul[2]; if (pipe(nul) == 0) { dup2(nul[0], 0); close(nul[0]); /* write end kept open: no EOF */ }
    vpiHandle h = after(1, fs_trigger); if (h) vpi_release_handle(h);
    return;
  }
  double ms = wall_ms() - t0;
  for (int i = 0; i < FS_MAX; i++) if (!fs_out[i].pid) { fs_out[i].pid = p; fs_out[i].file = strdup(file); fs_alive++; break; }
  bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"pid\":%d,\"forkMs\":%.3f,\"file\":", id, (unsigned long long)t, (int)p, ms);
  bjson(&ob, file); bstr(&ob, "}"); send_ob();
}
