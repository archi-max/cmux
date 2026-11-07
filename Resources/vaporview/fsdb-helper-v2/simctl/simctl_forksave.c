/* SPDX-License-Identifier: MIT
 * simctl fork-save: a file save that does not pause the simulation. Included by simctl_vpi.c (one unit).
 *
 * `V id <file>` (served when idle and at a run's poll points): the library fork()s right there, at a
 * ReadOnlySynch. The parent answers {id, t, pid, forkMs, file} and goes on at once. The child:
 *   - stops serving at once: the serve loops return to the simulation right after the V (the lines behind it
 *     are the parent's), every library callback returns at once in it, it never reads or writes the channel
 *     (its copies are closed) and never ends the group (lost_controller is the parent's);
 *   - sends its output to <file>.log;
 *   - one time unit later (a writable region) sets simctl_saver.name and toggles simctl_saver.go, so the
 *     build's simctl_saver top runs the documented $save as the last event of that step;
 *   - at the next step's callback waits for its own children ($save's compressor), checks the image (there,
 *     not empty, and no [VCS_SAVE_RESTORE] error in its log) and _exit()s: 0 if good, 2 no image, 3 an
 *     error in the log. No end-of-simulation work, no licence check-in.
 * So the save holds the state at t+1. The build needs the simctl_saver top (vpi/simctl_saver.sv,
 * `-top simctl_saver`); without it V is refused. At most FS_MAX saves at once (more are refused, never
 * waited for, so the parent never blocks). When a child ends, the library sends {ev: saved, pid, file, t,
 * status} (status: the child's exit status, -1 if it could not be collected). A child still running after
 * SIMCTL_FORKSAVE_TIMEOUT_MS (default 120000) is killed with its descendants and reported with
 * "timeout":true; its slot is free again. The children are in the simulation's process group, so they go
 * with it.
 * A process restored from such a save (simv -r <file>) carries the child's state: its library stays inert. */
#include <sys/wait.h>
#include <sys/stat.h>

#define FS_MAX 2
static pid_t fs_child_pid;
static struct { pid_t pid; char *file; double t0; } fs_out[FS_MAX];
static double fs_timeout_ms = -1;

/* SIGKILL a process and all its descendants (collected first, so none is reparented away meanwhile). */
static void fs_kill_tree(pid_t root) {
  pid_t set[256]; int n = 0; set[n++] = root;
  for (int grew = 1; grew && n < 256;) {
    grew = 0;
    DIR *d = opendir("/proc"); struct dirent *e;
    while (d && (e = readdir(d)) && n < 256) {
      if (!isdigit((unsigned char)e->d_name[0])) continue;
      char path[300], st[512]; snprintf(path, sizeof path, "/proc/%s/stat", e->d_name);
      int fd = open(path, O_RDONLY); if (fd < 0) continue;
      ssize_t k = read(fd, st, sizeof st - 1); close(fd); if (k <= 0) continue; st[k] = 0;
      char *rp = strrchr(st, ')'); int ppid; char state; pid_t pid = (pid_t)atoi(e->d_name);
      if (!rp || sscanf(rp + 2, "%c %d", &state, &ppid) != 2) continue;
      int in = 0, parent = 0;
      for (int i = 0; i < n; i++) { if (set[i] == pid) in = 1; if (set[i] == ppid) parent = 1; }
      if (parent && !in) { set[n++] = pid; grew = 1; }
    }
    if (d) closedir(d);
  }
  for (int i = n - 1; i >= 0; i--) kill(set[i], SIGKILL);
}
static char fs_file[1100];
static vpiHandle fs_name_h, fs_go_h;

static void fs_reap(void) {
  if (fs_timeout_ms < 0) { const char *e = getenv("SIMCTL_FORKSAVE_TIMEOUT_MS"); fs_timeout_ms = e && *e ? atof(e) : 120000; }
  for (int i = 0; i < FS_MAX; i++) {
    if (!fs_out[i].pid) continue;
    int st = 0, late = 0; pid_t r = waitpid(fs_out[i].pid, &st, WNOHANG);
    if (r == 0) {
      if (wall_ms() - fs_out[i].t0 <= fs_timeout_ms) continue;
      fs_kill_tree(fs_out[i].pid); late = 1;           /* past its deadline: end it and its children */
      do r = waitpid(fs_out[i].pid, &st, 0); while (r < 0 && errno == EINTR);
    }
    int status = r < 0 ? -1 : WIFEXITED(st) ? WEXITSTATUS(st) : 128 + (WIFSIGNALED(st) ? WTERMSIG(st) : 0);
    bfmt(&ob, "{\"ev\":\"saved\",\"pid\":%d,\"t\":%llu,\"status\":%d,%s\"file\":", (int)fs_out[i].pid, (unsigned long long)now(), status, late ? "\"timeout\":true," : "");
    bjson(&ob, fs_out[i].file); bstr(&ob, "}"); send_ob();
    free(fs_out[i].file); fs_out[i].pid = 0; fs_out[i].file = NULL; fs_alive--;
  }
}
/* The child, one step after its $save: wait for its own children (the compressor $save starts), then check the
 * image and say in the exit status whether it is good. */
static PLI_INT32 fs_exit(p_cb_data d) {
  (void)d;
  if (getpid() != fs_child_pid) return 0;
  fflush(NULL);
  for (;;) { pid_t r = waitpid(-1, NULL, 0); if (r < 0 && errno == EINTR) continue; if (r < 0) break; }
  struct stat sb;
  if (stat(fs_file, &sb) != 0 || sb.st_size <= 0) _exit(2);
  char lf[1200]; snprintf(lf, sizeof lf, "%s.log", fs_file);
  FILE *f = fopen(lf, "r");
  if (f) { char line[1024]; while (fgets(line, sizeof line, f)) if (strstr(line, "[VCS_SAVE_RESTORE]") && strstr(line, "Error")) { fclose(f); _exit(3); } fclose(f); }
  _exit(0);
}
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
  for (int i = 0; i < FS_MAX; i++) if (!fs_out[i].pid) { fs_out[i].pid = p; fs_out[i].file = strdup(file); fs_out[i].t0 = t0; fs_alive++; break; }
  bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"pid\":%d,\"forkMs\":%.3f,\"file\":", id, (unsigned long long)t, (int)p, ms);
  bjson(&ob, file); bstr(&ob, "}"); send_ob();
}
