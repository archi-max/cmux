/* SPDX-License-Identifier: GPL-3.0-or-later
 * simctl stub: the one routine a build names with the compile-time `-load <this>.so:simctl_register`.
 * With SIMCTL_LIB unset it does nothing, so the simulation behaves exactly as without it. With SIMCTL_LIB set
 * it loads that library and calls its simctl_entry(), so the real library can change without relinking.
 * Uses no simulator headers. */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

void simctl_register(void) {
  const char *lib = getenv("SIMCTL_LIB");
  if (!lib || !*lib) return;
  void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
  if (!h) { fprintf(stderr, "simctl stub: %s\n", dlerror()); return; }
  void (*entry)(void) = (void (*)(void))dlsym(h, "simctl_entry");
  if (!entry) { fprintf(stderr, "simctl stub: no simctl_entry in %s\n", lib); return; }
  entry();
}
