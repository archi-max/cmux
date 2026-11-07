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
 * A process restored from such a save (simv -r <file>) carries the child's state: its library stays inert.
 *
 * Hardening (review M-a, L-a..L-d, M5, M6):
 *   - the child saves to <file>.simctl-<pid>.tmp and, only once that image checks out, renames its .FILES and
 *     then the image to <file> (the rename is the commit point; a renamed image restores: measured). So a
 *     failed re-save never leaves or reads an old <file> as its result: its exit status 0 is this save's own
 *     completion record;
 *   - a failed or timed-out save's temporaries (<tmp>, <tmp>.FILES, <tmp>_tmp.save_in_progress) are removed;
 *   - at the deadline one outcome wins: timeout only if the kill is what ended the child;
 *   - after a kill the parent waits at most FS_KILL_WAIT_MS for the child (never blocks on a stuck one);
 *   - a simulation that ends with saves out (quit, $finish) ends them and reports each once, simExited;
 *   - refused when the simulator runs more than one thread (fork copies only the calling thread);
 *   - in the child every inherited descriptor >= 3 that is open for writing is pointed at /dev/null right after
 *     the fork, so nothing the child does can write into the parent's dumps, logs or sockets. Read-only ones are
 *     kept: $save reads the build's database through an inherited one (simv.daidir/dsa.sdb; with it replaced,
 *     $save fails with Error-[VFS_SDB_ERROR]: measured). */
#include <sys/wait.h>
#include <sys/stat.h>
#include <ftw.h>
#define FS_KILL_WAIT_MS 2000

#define FS_MAX 2
static pid_t fs_child_pid;
static struct { pid_t pid; char *file; double t0; } fs_out[FS_MAX];
static pid_t fs_zomb[16]; static int nzomb;   /* killed children not yet collected (L-d): reaped later */
static char fs_tmp[1200];                     /* the child's save name: <file>.simctl-<pid>.tmp */
static void fs_tmpname(char *out, size_t n, const char *file, pid_t pid) { snprintf(out, n, "%s.simctl-%d.tmp", file, (int)pid); }
static int rm_one(const char *p, const struct stat *sb, int fl, struct FTW *ftw) { (void)sb; (void)fl; (void)ftw; remove(p); return 0; }
static void rm_tree(const char *p) { struct stat sb; if (lstat(p, &sb) == 0) nftw(p, rm_one, 16, FTW_DEPTH | FTW_PHYS); }
/* a failed, killed or abandoned save leaves nothing behind */
static void fs_cleanup(const char *file, pid_t pid) {
  char t[1200], x[1300];
  fs_tmpname(t, sizeof t, file, pid);
  rm_tree(t);
  snprintf(x, sizeof x, "%s.FILES", t); rm_tree(x);
  snprintf(x, sizeof x, "%s_tmp.save_in_progress", t); rm_tree(x);
}
static int fs_threads(void) {
  FILE *f = fopen("/proc/self/status", "r"); char l[256]; int n = -1;
  while (f && fgets(l, sizeof l, f)) if (!strncmp(l, "Threads:", 8)) { n = atoi(l + 8); break; }
  if (f) fclose(f);
  return n;
}
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

/* kill a child's tree and collect it, waiting at most FS_KILL_WAIT_MS; r: waitpid's result (0: not collected) */
static pid_t fs_kill_collect(pid_t pid, int *st) {
  fs_kill_tree(pid);
  double end = wall_ms() + FS_KILL_WAIT_MS; pid_t r;
  for (;;) {
    r = waitpid(pid, st, WNOHANG);
    if (r != 0 || wall_ms() > end) break;
    struct timespec ts = { 0, 10 * 1000 * 1000 }; nanosleep(&ts, NULL);
  }
  if (r == 0 && nzomb < 16) fs_zomb[nzomb++] = pid;   /* stuck (e.g. in D state): collected later, never waited on */
  return r;
}
/* one event per save; why: 0 ended by itself, 1 deadline, 2 the simulation ended */
static void fs_report(int i, pid_t r, int st, int why) {
  int status = r <= 0 ? -1 : WIFEXITED(st) ? WEXITSTATUS(st) : 128 + (WIFSIGNALED(st) ? WTERMSIG(st) : 0);
  if (status != 0 || why) fs_cleanup(fs_out[i].file, fs_out[i].pid);
  bfmt(&ob, "{\"ev\":\"saved\",\"pid\":%d,\"t\":%llu,\"status\":%d,%s\"file\":", (int)fs_out[i].pid, (unsigned long long)now(), status,
       why == 1 ? "\"timeout\":true," : why == 2 ? "\"simExited\":true," : "");
  bjson(&ob, fs_out[i].file); bstr(&ob, "}"); send_ob();
  free(fs_out[i].file); fs_out[i].pid = 0; fs_out[i].file = NULL; fs_alive--;
}
static void fs_reap(void) {
  if (fs_timeout_ms < 0) { const char *e = getenv("SIMCTL_FORKSAVE_TIMEOUT_MS"); fs_timeout_ms = e && *e ? atof(e) : 120000; }
  for (int z = 0; z < nzomb;) { if (waitpid(fs_zomb[z], NULL, WNOHANG) != 0) fs_zomb[z] = fs_zomb[--nzomb]; else z++; }
  for (int i = 0; i < FS_MAX; i++) {
    if (!fs_out[i].pid) continue;
    int st = 0, why = 0; pid_t r = waitpid(fs_out[i].pid, &st, WNOHANG);
    if (r == 0) {
      if (wall_ms() - fs_out[i].t0 <= fs_timeout_ms) continue;
      r = fs_kill_collect(fs_out[i].pid, &st);          /* past its deadline: end it and its children */
      /* one winner (L-b): a timeout only if the kill ended it; a child that exited just before is its own result */
      why = r <= 0 || (WIFSIGNALED(st) && WTERMSIG(st) == SIGKILL) ? 1 : 0;
    }
    fs_report(i, r, st, why);
  }
}
/* the simulation ends (quit, $finish) with saves out: end them, report each once (M-a) */
static void fs_end_all(void) {
  for (int i = 0; i < FS_MAX; i++) {
    if (!fs_out[i].pid) continue;
    int st = 0; pid_t r = waitpid(fs_out[i].pid, &st, WNOHANG);
    if (r == 0) r = fs_kill_collect(fs_out[i].pid, &st);
    else if (r > 0 && WIFEXITED(st) && WEXITSTATUS(st) == 0) { fs_report(i, r, st, 0); continue; }   /* it finished first */
    fs_report(i, r, st, 2);
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
  if (stat(fs_tmp, &sb) != 0 || sb.st_size <= 0) _exit(2);
  char lf[1200]; snprintf(lf, sizeof lf, "%s.log", fs_file);
  FILE *f = fopen(lf, "r");
  if (f) { char line[1024]; while (fgets(line, sizeof line, f)) if (strstr(line, "[VCS_SAVE_RESTORE]") && strstr(line, "Error")) { fclose(f); _exit(3); } fclose(f); }
  /* commit: this save's .FILES, then the image itself (the image's rename is the commit point) */
  char tf[1300], ff[1300];
  snprintf(tf, sizeof tf, "%s.FILES", fs_tmp); snprintf(ff, sizeof ff, "%s.FILES", fs_file);
  if (stat(tf, &sb) == 0) { rm_tree(ff); if (rename(tf, ff) != 0) _exit(4); }
  if (rename(fs_tmp, fs_file) != 0) _exit(4);
  _exit(0);
}
static PLI_INT32 fs_trigger(p_cb_data d) {
  (void)d;
  if (getpid() != fs_child_pid) return 0;      /* restored from the save: not the child */
  s_vpi_value v; v.format = vpiStringVal; v.value.str = fs_tmp; vpi_put_value(fs_name_h, &v, NULL, vpiNoDelay);
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
  int nth = fs_threads();
  if (nth != 1) {   /* fork copies only this thread: a multi-threaded simulator (e.g. -fgp) can't be saved this way */
    char m[200]; snprintf(m, sizeof m, "forksave: the simulator runs %d threads (fork copies only one); use a single-threaded build", nth);
    reply_err(id, m); return;
  }
  snprintf(fs_file, sizeof fs_file, "%s", file);
  fflush(NULL);
  double t0 = wall_ms();
  pid_t p = fork();
  if (p < 0) { reply_err(id, "forksave: fork failed"); return; }
  if (p == 0) {
    fs_child = 1; fs_child_pid = getpid();
    if (in_fd >= 0) close(in_fd);
    if (out_fd >= 0) close(out_fd);
    fs_tmpname(fs_tmp, sizeof fs_tmp, fs_file, fs_child_pid);
    /* nothing inherited is written by the child: every writable descriptor >= 3 now refers to /dev/null (M6) */
    int dn = open("/dev/null", O_RDWR);
    if (dn >= 0) {
      DIR *fd_d = opendir("/proc/self/fd"); struct dirent *fe; int fds[1024], nfd = 0, dfd = fd_d ? dirfd(fd_d) : -1;
      while (fd_d && (fe = readdir(fd_d)) && nfd < 1024) {
        int k = atoi(fe->d_name);
        if (!isdigit((unsigned char)fe->d_name[0]) || k < 3 || k == dn || k == dfd) continue;
        int fl = fcntl(k, F_GETFL);
        if (fl != -1 && (fl & O_ACCMODE) == O_RDONLY) continue;   /* read-only: kept ($save reads the database) */
        fds[nfd++] = k;
      }
      if (fd_d) closedir(fd_d);
      for (int k = 0; k < nfd; k++) dup2(dn, fds[k]);
      close(dn);
    }
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
