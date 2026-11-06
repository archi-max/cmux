// run.sh fsdb-values: writes a small FSDB with non-bit variables using the host's FSDB
// writer library (built on the host; nothing of the library is copied or shipped):
//   top.clk  (1-bit wire)      0/1 every 5 units, 0..200
//   top.msg  (string)          idle@0  load,store@10 (same time: store wins)  store@20 (repeat)
//                              ""@30  300 x 'a..z'@40  "na\xc3\xafve \xc3\xbc"@50  idle@60
//   top.r    (real, 8 bytes)   1.5@0 -2.25@10 -2.25@20 0.1@30 1e300@40 1e-7@50 -0.0@60 3@70 123456.789@80
//   top.f    (real, 4 bytes)   0.5@0 0.1f@10 -3.25@20 (written only if the writer takes a 4-byte real)
//   top.ev   (event, 1 bit)    1@15 1@35 (events: each is a change)
//   top.n    (integer, 32 bits) 7@0 9@10
//   top.odd  (reg, 2 bytes per bit): a value encoding the helper doesn't read
// Usage: mkvalues out.fsdb
#undef NOVAS_FSDB
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ffwAPI.h"

static byte_T clk = FSDB_BT_VCD_0, ev = FSDB_BT_VCD_0, n[32];
static double r;
static float f;
static int strHdl, oddHdl[8];
static void setn(unsigned v) { for (int i = 0; i < 32; i++) n[i] = ((v >> (31 - i)) & 1) ? FSDB_BT_VCD_1 : FSDB_BT_VCD_0; }

int main(int argc, char **argv) {
  ffwObject *o = ffw_Open(argc > 1 ? argv[1] : (char *)"values.fsdb", FSDB_FT_VERILOG);
  if (!o) { fprintf(stderr, "open failed\n"); return 1; }
  ffw_CreateTreeByHandleScheme(o);
  ffw_SetScaleUnit(o, (char *)"1n");
  ffw_SetGlitchNum(o, 50);
  ffw_BeginTree(o);
  ffw_CreateScope(o, FSDB_ST_VCD_MODULE, (char *)"top");
  ffw_CreateVarByHandle(o, FSDB_VT_VCD_WIRE, FSDB_VD_INPUT, FSDB_DT_HANDLE_VERILOG_STANDARD, 0, 0, &clk, (char *)"clk", FSDB_BYTES_PER_BIT_1B);
  if (!ffwCreateStrVarByVarHdl(o, (char *)"msg", &strHdl)) { fprintf(stderr, "no string var\n"); return 1; }
  ffw_CreateVarByHandle(o, FSDB_VT_VCD_REAL, FSDB_VD_IMPLICIT, FSDB_DT_HDL_DOUBLE, 0, 0, &r, (char *)"r", FSDB_BYTES_PER_BIT_8B);
  const bool haveF = ffw_CreateVarByHandle(o, FSDB_VT_VCD_REAL, FSDB_VD_IMPLICIT, FSDB_DT_HDL_FLOAT, 0, 0, &f, (char *)"f", FSDB_BYTES_PER_BIT_4B) != NULL;
  ffw_CreateVarByHandle(o, FSDB_VT_VCD_EVENT, FSDB_VD_IMPLICIT, FSDB_DT_HANDLE_VERILOG_STANDARD, 0, 0, &ev, (char *)"ev", FSDB_BYTES_PER_BIT_1B);
  ffw_CreateVarByHandle(o, FSDB_VT_VCD_INTEGER, FSDB_VD_IMPLICIT, FSDB_DT_HANDLE_VERILOG_STANDARD, 31, 0, n, (char *)"n", FSDB_BYTES_PER_BIT_1B);
  ffw_CreateVarByHandle(o, FSDB_VT_VCD_REG, FSDB_VD_IMPLICIT, FSDB_DT_HANDLE_VERILOG_STANDARD, 3, 0, oddHdl, (char *)"odd", FSDB_BYTES_PER_BIT_2B);
  ffw_EndTree(o);

  char longStr[301];
  for (int i = 0; i < 300; i++) longStr[i] = (char)('a' + i % 26);
  longStr[300] = 0;
  const char *msgs[][2] = {{"0", "idle"}, {"10", "load"}, {"10", "store"}, {"20", "store"}, {"30", ""},
                           {"40", longStr}, {"50", "na\xc3\xafve \xc3\xbc"}, {"60", "idle"}};
  const double reals[] = {1.5, -2.25, -2.25, 0.1, 1e300, 1e-7, -0.0, 3.0, 123456.789};
  const float floats[] = {0.5f, 0.1f, -3.25f};
  unsigned short odd[4] = {1, 2, 3, 0};
  str_T ret;
  for (int t = 0; t <= 200; t += 5) {
    ffw_CreateXCoorByHnL(o, 0, t);
    clk = (t / 5) & 1 ? FSDB_BT_VCD_1 : FSDB_BT_VCD_0;
    ffw_CreateVarValueByHandle(o, (fsdbVarHandle)&clk, &clk);
    for (auto &m : msgs) if (atoi(m[0]) == t) ffwCreateStrValByVarHdl(o, &strHdl, (str_T)m[1], &ret);
    if (t % 10 == 0 && t / 10 < (int)(sizeof reals / sizeof reals[0])) { r = reals[t / 10]; ffw_CreateVarValueByHandle(o, (fsdbVarHandle)&r, (byte_T *)&r); }
    if (haveF && t % 10 == 0 && t / 10 < 3) { f = floats[t / 10]; ffw_CreateVarValueByHandle(o, (fsdbVarHandle)&f, (byte_T *)&f); }
    if (t == 15 || t == 35) { ev = FSDB_BT_VCD_1; ffw_CreateVarValueByHandle(o, (fsdbVarHandle)&ev, &ev); }
    if (t == 0 || t == 10) { setn(t ? 9 : 7); ffw_CreateVarValueByHandle(o, (fsdbVarHandle)n, n); }
    if (t == 0) ffw_CreateVarValueByHandle(o, (fsdbVarHandle)oddHdl, (byte_T *)odd);
  }
  ffw_Close(o);
  printf("float var: %s\n", haveF ? "yes" : "no");
  return 0;
}
