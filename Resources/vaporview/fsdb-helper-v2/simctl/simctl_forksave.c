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
 *   - one commit (re-review 2, M-new): each save is written into its own folder, <file>.simctl.d/<pid>/ (img,
 *     img.FILES), and <file> / <file>.FILES are fixed symlinks to <file>.simctl.d/cur/img and cur/img.FILES.
 *     Once the image checks out, the child points cur at its folder with one rename of a fresh symlink over cur
 *     (atomic), then removes the folder cur pointed at before. So whatever ends a save, at any step, <file> and
 *     <file>.FILES are always the image and file list of one and the same save (the old one or the new one), and
 *     the exit status 0 is this save's own completion record. A name that is not such a symlink yet (a first
 *     save, or a file from elsewhere) is turned into one before the commit;
 *   - a second save to a name with a save of this process still in flight is refused;
 *   - to move or copy a save, take all three: <file>, <file>.FILES and <file>.simctl.d (the links are relative;
 *     copy with the links as links, e.g. cp -a). <file> and <file>.FILES alone are just links (re-review 3, L1);
 *   - a failed or timed-out save's folder is removed;
 *   - at the deadline one outcome wins: timeout only if the kill is what ended the child;
 *   - after a kill the parent waits at most FS_KILL_WAIT_MS for the child (never blocks on a stuck one);
 *   - a simulation that ends with saves out (quit, $finish) ends them and reports each once, simExited;
 *   - refused when the simulator runs more than one thread (fork copies only the calling thread);
 *   - in the child every inherited descriptor >= 3 that is open for writing gets its own open file description
 *     right after the fork (re-review 2, H-new): a regular file is opened again by its path, same access mode,
 *     no O_TRUNC/O_APPEND, at the same offset; anything else (pipe, socket, device) is pointed at /dev/null. So
 *     the child never moves the parent's file offsets, the child's own stdio buffers are never flushed into the
 *     parent's files (no fflush(NULL) in the child), and $save records each $fopen file by its real path and
 *     offset, so a restored run goes on writing it (with /dev/null there, the restored run wrote nothing:
 *     measured). Read-only ones are kept: $save reads the build's database through an inherited one
 *     (simv.daidir/dsa.sdb; with it replaced, $save fails with Error-[VFS_SDB_ERROR]: measured). */
#include <sys/wait.h>
#include <sys/stat.h>
#include <ftw.h>
#define FS_KILL_WAIT_MS 2000

#define FS_MAX 2
static pid_t fs_child_pid;
static int fs_nsave;   /* forksaves accepted by this process (the test hook below counts them) */
/* test hook, inert unless SIMCTL_FORKSAVE_TEST_DIE=commit:<n>: the n-th save of the process _exit(9)s in the middle
 * of its commit, as a crash there would (review.js forkfopen) */
static int fs_test_die(void) { const char *e = getenv("SIMCTL_FORKSAVE_TEST_DIE"); return e && !strncmp(e, "commit:", 7) && atoi(e + 7) == fs_nsave; }
static struct { pid_t pid; char *file; double t0; } fs_out[FS_MAX];
static pid_t fs_zomb[16]; static int nzomb;   /* killed children not yet collected (L-d): reaped later */
static char fs_tmp[1200];                     /* the child's save name: <file>.simctl.d/<pid>/img */
static void fs_gendir(char *out, size_t n, const char *file, pid_t pid) { snprintf(out, n, "%s.simctl.d/%d", file, (int)pid); }
static void fs_tmpname(char *out, size_t n, const char *file, pid_t pid) { snprintf(out, n, "%s.simctl.d/%d/img", file, (int)pid); }
static int rm_one(const char *p, const struct stat *sb, int fl, struct FTW *ftw) { (void)sb; (void)fl; (void)ftw; remove(p); return 0; }
static void rm_tree(const char *p) { struct stat sb; if (lstat(p, &sb) == 0) nftw(p, rm_one, 16, FTW_DEPTH | FTW_PHYS); }
/* a failed, killed or abandoned save leaves nothing behind */
static void fs_cleanup(const char *file, pid_t pid) {
  char g[1200], x[1300];
  fs_gendir(g, sizeof g, file, pid);
  char cur[1300]; snprintf(x, sizeof x, "%s.simctl.d/cur", file);
  ssize_t k = readlink(x, cur, sizeof cur - 1);
  if (k > 0) { cur[k] = 0; if (atoi(cur) == (int)pid) return; }   /* it got as far as its commit: it is <file> now */
  rm_tree(g);
  snprintf(x, sizeof x, "%s.simctl.d/cur.%d", file, (int)pid); unlink(x);
}
/* <link> is a symlink to <to>, or made one (a fresh symlink renamed over whatever is there) */
static int fs_link(const char *link, const char *to) {
  char got[1300]; ssize_t k = readlink(link, got, sizeof got - 1);
  if (k > 0) { got[k] = 0; if (!strcmp(got, to)) return 0; }
  char t[1300]; snprintf(t, sizeof t, "%s.simctl-%d.ln", link, (int)getpid());
  unlink(t);
  if (symlink(to, t) != 0) return -1;
  struct stat sb;
  if (lstat(link, &sb) == 0 && S_ISDIR(sb.st_mode)) rm_tree(link);   /* rename can't replace a folder */
  if (rename(t, link) != 0) { unlink(t); return -1; }
  return 0;
}
/* the child: its own open file description for each inherited writable descriptor >= 3 (H-new, M6) */
static char fs_warn[2048]; static size_t fs_nwarn;   /* the child: files it could not reopen (L3), for its log */
static void fs_private_fds(void) {
  int dn = open("/dev/null", O_RDWR);
  DIR *fd_d = opendir("/proc/self/fd"); struct dirent *fe; int fds[1024], nfd = 0, dfd = fd_d ? dirfd(fd_d) : -1;
  while (fd_d && (fe = readdir(fd_d)) && nfd < 1024) {
    int k = atoi(fe->d_name);
    if (!isdigit((unsigned char)fe->d_name[0]) || k < 3 || k == dn || k == dfd) continue;
    int fl = fcntl(k, F_GETFL);
    if (fl == -1 || (fl & O_ACCMODE) == O_RDONLY) continue;   /* read-only: kept ($save reads the database) */
    fds[nfd++] = k;
  }
  if (fd_d) closedir(fd_d);
  for (int i = 0; i < nfd; i++) {
    int k = fds[i], fl = fcntl(k, F_GETFL), n = -1;
    struct stat sb; char lp[64], tp[4096];
    snprintf(lp, sizeof lp, "/proc/self/fd/%d", k);
    ssize_t m = readlink(lp, tp, sizeof tp - 1);
    if (m > 0 && tp[0] == '/' && fstat(k, &sb) == 0 && S_ISREG(sb.st_mode)) {
      tp[m] = 0;
      off_t at = lseek(k, 0, SEEK_CUR);   /* the shared offset, read before anything moves it */
      n = open(tp, (fl & O_ACCMODE));
      struct stat nb;
      if (n >= 0 && (fstat(n, &nb) != 0 || nb.st_ino != sb.st_ino || nb.st_dev != sb.st_dev || at < 0 || lseek(n, at, SEEK_SET) != at)) { close(n); n = -1; }
    }
    if (n >= 0) { dup2(n, k); close(n); }
    else {
      if (m > 0 && tp[0] == '/' && S_ISREG(sb.st_mode) && fs_nwarn < sizeof fs_warn - 1)   /* a file it could not reopen */
        fs_nwarn += snprintf(fs_warn + fs_nwarn, sizeof fs_warn - fs_nwarn, "simctl-forksave: warning: %s (fd %d) could not be reopened: a run restored from this save writes nothing to it\n", tp, k);
      if (dn >= 0) dup2(dn, k);
    }
  }
  if (dn >= 0) close(dn);
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
  fflush(stdout); fflush(stderr);   /* the child's own log only: never its copies of the parent's file buffers */
  for (;;) { pid_t r = waitpid(-1, NULL, 0); if (r < 0 && errno == EINTR) continue; if (r < 0) break; }
  struct stat sb;
  if (stat(fs_tmp, &sb) != 0 || sb.st_size <= 0) _exit(2);
  char lf[1200]; snprintf(lf, sizeof lf, "%s.log", fs_file);
  FILE *f = fopen(lf, "r");
  if (f) { char line[1024]; while (fgets(line, sizeof line, f)) if (strstr(line, "[VCS_SAVE_RESTORE]") && strstr(line, "Error")) { fclose(f); _exit(3); } fclose(f); }
  /* commit (M-new): <file> and <file>.FILES are (made) the fixed links through cur; then cur is pointed at this
   * save's folder in one rename; then the folder it pointed at before goes */
  char dd[1200], x[1500], to[1300], old[1300] = "", base[1100];
  const char *sl = strrchr(fs_file, '/'); snprintf(base, sizeof base, "%s", sl ? sl + 1 : fs_file);
  snprintf(dd, sizeof dd, "%s.simctl.d", fs_file);
  snprintf(x, sizeof x, "%s.FILES", fs_tmp);
  if (stat(x, &sb) != 0 && mkdir(x, 0755) != 0) _exit(4);   /* no .FILES from $save: an empty one keeps the pair whole */
  snprintf(to, sizeof to, "%s.simctl.d/cur/img", base); if (fs_link(fs_file, to) != 0) _exit(4);
  if (fs_test_die()) _exit(9);
  snprintf(x, sizeof x, "%s.FILES", fs_file); snprintf(to, sizeof to, "%s.simctl.d/cur/img.FILES", base); if (fs_link(x, to) != 0) _exit(4);
  snprintf(x, sizeof x, "%s/cur", dd);
  ssize_t k = readlink(x, old, sizeof old - 1); old[k > 0 ? k : 0] = 0;
  char me[32], tl[1500]; snprintf(me, sizeof me, "%d", (int)getpid()); snprintf(tl, sizeof tl, "%s/cur.%d", dd, (int)getpid());
  unlink(tl);
  if (symlink(me, tl) != 0 || rename(tl, x) != 0) { unlink(tl); _exit(4); }   /* the commit point */
  /* the old folder, and any a crashed save left after its own commit (L2): every <pid> folder but this one whose
   * process is gone (a live one may be another simulation's save in flight) */
  if (*old && strcmp(old, me) && !strchr(old, '/')) { snprintf(x, sizeof x, "%s/%s", dd, old); rm_tree(x); }   /* committed before: done */
  DIR *gd = opendir(dd); struct dirent *ge;
  while (gd && (ge = readdir(gd))) {
    const char *nm = ge->d_name; int digits = *nm != 0;
    for (const char *c = nm; *c; c++) if (!isdigit((unsigned char)*c)) digits = 0;
    if (!digits || !strcmp(nm, me)) continue;
    pid_t gp = (pid_t)atoi(nm);
    if (gp > 0 && (kill(gp, 0) == 0 || errno == EPERM)) continue;   /* alive */
    snprintf(x, sizeof x, "%s/%s", dd, nm); rm_tree(x);
  }
  if (gd) closedir(gd);
  _exit(0);
}
static PLI_INT32 fs_trigger(p_cb_data d) {
  (void)d;
  if (getpid() != fs_child_pid) return 0;      /* restored from the save: not the child */
  char gd[1200], sd[1300]; fs_gendir(gd, sizeof gd, fs_file, fs_child_pid); snprintf(sd, sizeof sd, "%s.simctl.d", fs_file);
  if ((mkdir(sd, 0755) != 0 && errno != EEXIST) || mkdir(gd, 0755) != 0) _exit(4);
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
  for (int i = 0; i < FS_MAX; i++)
    if (fs_out[i].pid && !strcmp(fs_out[i].file, file)) { reply_err(id, "forksave: a save to this file is in progress; try again when it has ended"); return; }
  if (fs_alive >= FS_MAX) { reply_err(id, "forksave: two saves in progress; try again when one has ended"); return; }
  int nth = fs_threads();
  if (nth != 1) {   /* fork copies only this thread: a multi-threaded simulator (e.g. -fgp) can't be saved this way */
    char m[200]; snprintf(m, sizeof m, "forksave: the simulator runs %d threads (fork copies only one); use a single-threaded build", nth);
    reply_err(id, m); return;
  }
  snprintf(fs_file, sizeof fs_file, "%s", file);
  fs_nsave++;
  fflush(NULL);
  double t0 = wall_ms();
  pid_t p = fork();
  if (p < 0) { reply_err(id, "forksave: fork failed"); return; }
  if (p == 0) {
    fs_child = 1; fs_child_pid = getpid();
    if (in_fd >= 0) close(in_fd);
    if (out_fd >= 0) close(out_fd);
    fs_tmpname(fs_tmp, sizeof fs_tmp, fs_file, fs_child_pid);
    fs_private_fds();   /* nothing the child does moves or writes through the parent's open files (H-new, M6) */
    char lf[1200]; snprintf(lf, sizeof lf, "%s.log", fs_file);
    int o = open(lf, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (o >= 0) { dup2(o, 1); dup2(o, 2); close(o); }
    if (fs_nwarn) { ssize_t w = write(2, fs_warn, fs_nwarn > sizeof fs_warn - 1 ? sizeof fs_warn - 1 : fs_nwarn); (void)w; }
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
