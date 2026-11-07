/* SPDX-License-Identifier: MIT
 * simctl stub: the one routine a build names with the compile-time `-load <this>.so:simctl_register`.
 * It always registers the $simctl_serve and $simctl_next system tasks (so a testbench that calls them, e.g.
 * simctl_hold.sv and simctl_tb.sv, elaborates). With SIMCTL_LIB unset they do nothing and the simulation
 * behaves exactly as without the stub. With SIMCTL_LIB set it loads that library, calls its simctl_entry2(1) and
 * forwards both tasks to it,
 * so the real library can change without relinking. Public IEEE VPI only (built against the host's vpi_user.h). */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "vpi_user.h"

static PLI_INT32 (*serve_fwd)(PLI_BYTE8 *), (*next_fwd)(PLI_BYTE8 *);
static PLI_INT32 serve_calltf(PLI_BYTE8 *ud) { return serve_fwd ? serve_fwd(ud) : 0; }
static PLI_INT32 next_calltf(PLI_BYTE8 *ud) { return next_fwd ? next_fwd(ud) : 0; }

void simctl_register(void) {
  s_vpi_systf_data tf; memset(&tf, 0, sizeof tf);
  tf.type = vpiSysTask; tf.tfname = "$simctl_serve"; tf.calltf = serve_calltf;
  vpi_register_systf(&tf);
  tf.tfname = "$simctl_next"; tf.calltf = next_calltf;
  vpi_register_systf(&tf);
  const char *lib = getenv("SIMCTL_LIB");
  if (!lib || !*lib) return;
  void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
  if (!h) { fprintf(stderr, "simctl stub: %s\n", dlerror()); return; }
  void (*entry2)(int) = (void (*)(int))dlsym(h, "simctl_entry2");
  serve_fwd = (PLI_INT32 (*)(PLI_BYTE8 *))dlsym(h, "simctl_serve_calltf");
  next_fwd = (PLI_INT32 (*)(PLI_BYTE8 *))dlsym(h, "simctl_next_calltf");
  if (!entry2 || !serve_fwd || !next_fwd) { serve_fwd = next_fwd = NULL; fprintf(stderr, "simctl stub: %s is not a simctl library of this version (no simctl_entry2)\n", lib); return; }
  entry2(1);
}
