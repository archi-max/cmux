// GENERATED from spike-webview/vaporview-instr src/webview/riscv_disasm.ts (instr-format b42ffa4, written for
// this project; see its header below) by esbuild --format=iife --global-name=cmuxRiscvDisasm. Do not edit;
// regenerate from the TypeScript. Used by the machine state (cmux-machine.js) for pc, x/i and History.
var cmuxRiscvDisasm = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __defNormalProp = (obj, key, value) => key in obj ? __defProp(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
  var __publicField = (obj, key, value) => __defNormalProp(obj, typeof key !== "symbol" ? key + "" : key, value);

  // riscv_disasm.ts
  var riscv_disasm_exports = {};
  __export(riscv_disasm_exports, {
    disassembleRiscv: () => disassembleRiscv,
    formatRiscvBinaryString: () => formatRiscvBinaryString,
    riscvCsrName: () => riscvCsrName
  });
  var ABI_NAMES = [
    "zero",
    "ra",
    "sp",
    "gp",
    "tp",
    "t0",
    "t1",
    "t2",
    "s0",
    "s1",
    "a0",
    "a1",
    "a2",
    "a3",
    "a4",
    "a5",
    "a6",
    "a7",
    "s2",
    "s3",
    "s4",
    "s5",
    "s6",
    "s7",
    "s8",
    "s9",
    "s10",
    "s11",
    "t3",
    "t4",
    "t5",
    "t6"
  ];
  var CSR_NAMES = {
    1: "fflags",
    2: "frm",
    3: "fcsr",
    8: "vstart",
    9: "vxsat",
    10: "vxrm",
    15: "vcsr",
    21: "seed",
    256: "sstatus",
    260: "sie",
    261: "stvec",
    262: "scounteren",
    266: "senvcfg",
    268: "sstateen0",
    269: "sstateen1",
    270: "sstateen2",
    271: "sstateen3",
    276: "sieh",
    320: "sscratch",
    321: "sepc",
    322: "scause",
    323: "stval",
    324: "sip",
    333: "stimecmp",
    336: "siselect",
    337: "sireg",
    338: "sireg2",
    339: "sireg3",
    340: "siph",
    341: "sireg4",
    342: "sireg5",
    343: "sireg6",
    348: "stopei",
    349: "stimecmph",
    384: "satp",
    512: "vsstatus",
    516: "vsie",
    517: "vstvec",
    532: "vsieh",
    576: "vsscratch",
    577: "vsepc",
    578: "vscause",
    579: "vstval",
    580: "vsip",
    589: "vstimecmp",
    592: "vsiselect",
    593: "vsireg",
    594: "vsireg2",
    595: "vsireg3",
    596: "vsiph",
    597: "vsireg4",
    598: "vsireg5",
    599: "vsireg6",
    604: "vstopei",
    605: "vstimecmph",
    640: "vsatp",
    768: "mstatus",
    769: "misa",
    770: "medeleg",
    771: "mideleg",
    772: "mie",
    773: "mtvec",
    774: "mcounteren",
    776: "mvien",
    777: "mvip",
    778: "menvcfg",
    780: "mstateen0",
    781: "mstateen1",
    782: "mstateen2",
    783: "mstateen3",
    784: "mstatush",
    787: "midelegh",
    788: "mieh",
    792: "mvienh",
    793: "mviph",
    794: "menvcfgh",
    796: "mstateen0h",
    797: "mstateen1h",
    798: "mstateen2h",
    799: "mstateen3h",
    800: "mcountinhibit",
    801: "mcyclecfg",
    802: "minstretcfg",
    832: "mscratch",
    833: "mepc",
    834: "mcause",
    835: "mtval",
    836: "mip",
    842: "mtinst",
    843: "mtval2",
    848: "miselect",
    849: "mireg",
    850: "mireg2",
    851: "mireg3",
    852: "miph",
    853: "mireg4",
    854: "mireg5",
    855: "mireg6",
    860: "mtopei",
    1448: "scontext",
    1536: "hstatus",
    1538: "hedeleg",
    1539: "hideleg",
    1540: "hie",
    1541: "htimedelta",
    1542: "hcounteren",
    1543: "hgeie",
    1544: "hvien",
    1545: "hvictl",
    1546: "henvcfg",
    1548: "hstateen0",
    1549: "hstateen1",
    1550: "hstateen2",
    1551: "hstateen3",
    1555: "hidelegh",
    1557: "htimedeltah",
    1560: "hvienh",
    1562: "henvcfgh",
    1564: "hstateen0h",
    1565: "hstateen1h",
    1566: "hstateen2h",
    1567: "hstateen3h",
    1603: "htval",
    1604: "hip",
    1605: "hvip",
    1606: "hviprio1",
    1607: "hviprio2",
    1610: "htinst",
    1621: "hviph",
    1622: "hviprio1h",
    1623: "hviprio2h",
    1664: "hgatp",
    1704: "hcontext",
    1825: "mcyclecfgh",
    1826: "minstretcfgh",
    1863: "mseccfg",
    1879: "mseccfgh",
    1952: "tselect",
    1953: "tdata1",
    1954: "tdata2",
    1955: "tdata3",
    1956: "tinfo",
    1957: "tcontrol",
    1960: "mcontext",
    1962: "mscontext",
    1968: "dcsr",
    1969: "dpc",
    1970: "dscratch0",
    1971: "dscratch1",
    2816: "mcycle",
    2818: "minstret",
    2944: "mcycleh",
    2946: "minstreth",
    3072: "cycle",
    3073: "time",
    3074: "instret",
    3104: "vl",
    3105: "vtype",
    3106: "vlenb",
    3200: "cycleh",
    3201: "timeh",
    3202: "instreth",
    3488: "scountovf",
    3504: "stopi",
    3602: "hgeip",
    3760: "vstopi",
    3857: "mvendorid",
    3858: "marchid",
    3859: "mimpid",
    3860: "mhartid",
    3861: "mconfigptr",
    4016: "mtopi"
  };
  for (let i = 3; i < 32; i++) {
    CSR_NAMES[3072 + i] = "hpmcounter" + i;
    CSR_NAMES[3200 + i] = "hpmcounter" + i + "h";
    CSR_NAMES[2816 + i] = "mhpmcounter" + i;
    CSR_NAMES[2944 + i] = "mhpmcounter" + i + "h";
    CSR_NAMES[800 + i] = "mhpmevent" + i;
    CSR_NAMES[1824 + i] = "mhpmevent" + i + "h";
  }
  for (let i = 0; i < 16; i++) {
    CSR_NAMES[928 + i] = "pmpcfg" + i;
  }
  for (let i = 0; i < 64; i++) {
    CSR_NAMES[944 + i] = "pmpaddr" + i;
  }
  function riscvCsrName(csr) {
    return CSR_NAMES[csr] ?? "0x" + csr.toString(16);
  }
  function signExtend(value, bits2) {
    const shift = 32 - bits2;
    return value << shift >> shift;
  }
  function bits(word, hi, lo) {
    return word >>> lo & (1 << hi - lo + 1) - 1;
  }
  function hex(n) {
    return "0x" + (n >>> 0).toString(16);
  }
  var BRANCH_NAMES = ["beq", "bne", null, null, "blt", "bge", "bltu", "bgeu"];
  var LOAD_NAMES = ["lb", "lh", "lw", null, "lbu", "lhu", null, null];
  var STORE_NAMES = ["sb", "sh", "sw", null, null, null, null, null];
  var OP_NAMES = ["add", "sll", "slt", "sltu", "xor", "srl", "or", "and"];
  var OP_ALT_NAMES = ["sub", null, null, null, null, "sra", null, null];
  var MULDIV_NAMES = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"];
  var CSR_OPS = ["", "csrrw", "csrrs", "csrrc", "", "csrrwi", "csrrsi", "csrrci"];
  var CSR_SHORT_OPS = ["", "csrw", "csrs", "csrc", "", "csrwi", "csrsi", "csrci"];
  var COUNTER_READS = {
    3072: "rdcycle",
    3073: "rdtime",
    3074: "rdinstret",
    3200: "rdcycleh",
    3201: "rdtimeh",
    3202: "rdinstreth"
  };
  var CA_NAMES = ["sub", "xor", "or", "and"];
  var FENCE_SET = ["unknown", "w", "r", "rw", "o", "ow", "or", "orw", "i", "iw", "ir", "irw", "io", "iow", "ior", "iorw"];
  var Disassembler = class {
    constructor(opts) {
      __publicField(this, "reg");
      __publicField(this, "aliases");
      __publicField(this, "pc");
      const abi = opts.abiNames !== false;
      this.reg = abi ? (n) => ABI_NAMES[n] : (n) => "x" + n;
      this.aliases = opts.aliases !== false;
      this.pc = opts.pc;
    }
    target(offset) {
      if (this.pc !== void 0) {
        return hex(this.pc + offset);
      }
      return offset < 0 ? "pc-" + -offset : "pc+" + offset;
    }
    op(mnemonic, ...operands) {
      return operands.length ? mnemonic + " " + operands.join(",") : mnemonic;
    }
    decode(word) {
      word = word >>> 0;
      if ((word & 3) !== 3) {
        return this.decodeCompressed(word & 65535);
      }
      if ((word & 28) === 28) {
        return null;
      }
      return this.decode32(word);
    }
    // #region 32-bit
    decode32(w) {
      const r = this.reg;
      const a = this.aliases;
      const opcode = bits(w, 6, 0);
      const rd = bits(w, 11, 7);
      const funct3 = bits(w, 14, 12);
      const rs1 = bits(w, 19, 15);
      const rs2 = bits(w, 24, 20);
      const funct7 = bits(w, 31, 25);
      const immI = signExtend(bits(w, 31, 20), 12);
      const immS = signExtend(bits(w, 31, 25) << 5 | bits(w, 11, 7), 12);
      const immB = signExtend(bits(w, 31, 31) << 12 | bits(w, 7, 7) << 11 | bits(w, 30, 25) << 5 | bits(w, 11, 8) << 1, 13);
      const immJ = signExtend(bits(w, 31, 31) << 20 | bits(w, 19, 12) << 12 | bits(w, 20, 20) << 11 | bits(w, 30, 21) << 1, 21);
      const immU = bits(w, 31, 12);
      switch (opcode) {
        case 55:
          return this.op("lui", r(rd), hex(immU));
        case 23:
          return this.op("auipc", r(rd), hex(immU));
        case 111: {
          if (a && rd === 0) {
            return this.op("j", this.target(immJ));
          }
          if (a && rd === 1) {
            return this.op("jal", this.target(immJ));
          }
          return this.op("jal", r(rd), this.target(immJ));
        }
        case 103: {
          if (funct3 !== 0) {
            return null;
          }
          if (a && rd === 0 && rs1 === 1 && immI === 0) {
            return "ret";
          }
          if (a && rd === 0) {
            return immI === 0 ? this.op("jr", r(rs1)) : this.op("jr", `${immI}(${r(rs1)})`);
          }
          if (a && rd === 1) {
            return immI === 0 ? this.op("jalr", r(rs1)) : this.op("jalr", `${immI}(${r(rs1)})`);
          }
          if (a && immI === 0) {
            return this.op("jalr", r(rd), r(rs1));
          }
          return this.op("jalr", r(rd), `${immI}(${r(rs1)})`);
        }
        case 99: {
          const name = BRANCH_NAMES[funct3];
          if (!name) {
            return null;
          }
          const t = this.target(immB);
          if (a) {
            if (rs2 === 0) {
              if (funct3 === 0) {
                return this.op("beqz", r(rs1), t);
              }
              if (funct3 === 1) {
                return this.op("bnez", r(rs1), t);
              }
              if (funct3 === 4) {
                return this.op("bltz", r(rs1), t);
              }
              if (funct3 === 5) {
                return this.op("bgez", r(rs1), t);
              }
            }
            if (rs1 === 0) {
              if (funct3 === 4) {
                return this.op("bgtz", r(rs2), t);
              }
              if (funct3 === 5) {
                return this.op("blez", r(rs2), t);
              }
            }
          }
          return this.op(name, r(rs1), r(rs2), t);
        }
        case 3: {
          const name = LOAD_NAMES[funct3];
          if (!name) {
            return null;
          }
          return this.op(name, r(rd), `${immI}(${r(rs1)})`);
        }
        case 35: {
          const name = STORE_NAMES[funct3];
          if (!name) {
            return null;
          }
          return this.op(name, r(rs2), `${immS}(${r(rs1)})`);
        }
        case 19: {
          switch (funct3) {
            case 0:
              if (a) {
                if (rd === 0 && rs1 === 0 && immI === 0) {
                  return "nop";
                }
                if (rs1 === 0) {
                  return this.op("li", r(rd), String(immI));
                }
                if (immI === 0) {
                  return this.op("mv", r(rd), r(rs1));
                }
              }
              return this.op("addi", r(rd), r(rs1), String(immI));
            case 2:
              return this.op("slti", r(rd), r(rs1), String(immI));
            case 3:
              if (a && immI === 1) {
                return this.op("seqz", r(rd), r(rs1));
              }
              return this.op("sltiu", r(rd), r(rs1), String(immI));
            case 4:
              if (a && immI === -1) {
                return this.op("not", r(rd), r(rs1));
              }
              return this.op("xori", r(rd), r(rs1), String(immI));
            case 6:
              return this.op("ori", r(rd), r(rs1), String(immI));
            case 7:
              if (a && immI === 255) {
                return this.op("zext.b", r(rd), r(rs1));
              }
              return this.op("andi", r(rd), r(rs1), String(immI));
            case 1:
              if (funct7 !== 0) {
                return null;
              }
              return this.op("slli", r(rd), r(rs1), hex(rs2));
            case 5:
              if (funct7 === 0) {
                return this.op("srli", r(rd), r(rs1), hex(rs2));
              }
              if (funct7 === 32) {
                return this.op("srai", r(rd), r(rs1), hex(rs2));
              }
              return null;
          }
          return null;
        }
        case 51: {
          let name = null;
          if (funct7 === 0) {
            name = OP_NAMES[funct3];
          } else if (funct7 === 32) {
            name = OP_ALT_NAMES[funct3];
          } else if (funct7 === 1) {
            name = MULDIV_NAMES[funct3];
          }
          if (!name) {
            return null;
          }
          if (a) {
            if (name === "sub" && rs1 === 0) {
              return this.op("neg", r(rd), r(rs2));
            }
            if (name === "sltu" && rs1 === 0) {
              return this.op("snez", r(rd), r(rs2));
            }
            if (name === "slt" && rs2 === 0) {
              return this.op("sltz", r(rd), r(rs1));
            }
            if (name === "slt" && rs1 === 0) {
              return this.op("sgtz", r(rd), r(rs2));
            }
          }
          return this.op(name, r(rd), r(rs1), r(rs2));
        }
        case 15: {
          if (funct3 === 1) {
            return w === 4111 ? "fence.i" : null;
          }
          if (funct3 !== 0 || rd !== 0 || rs1 !== 0) {
            return null;
          }
          const fm = bits(w, 31, 28);
          const pred = bits(w, 27, 24);
          const succ = bits(w, 23, 20);
          if (fm === 8 && pred === 3 && succ === 3) {
            return "fence.tso";
          }
          if (fm !== 0) {
            return null;
          }
          if (a && pred === 15 && succ === 15) {
            return "fence";
          }
          return this.op("fence", FENCE_SET[pred], FENCE_SET[succ]);
        }
        case 115:
          return this.decodeSystem(w, rd, funct3, rs1, rs2, funct7);
      }
      return null;
    }
    decodeSystem(w, rd, funct3, rs1, rs2, funct7) {
      const r = this.reg;
      const a = this.aliases;
      if (funct3 === 0) {
        switch (w) {
          case 115:
            return "ecall";
          case 1048691:
            return "ebreak";
          case 270532723:
            return "sret";
          case 807403635:
            return "mret";
          case 2065694835:
            return "dret";
          case 273678451:
            return "wfi";
        }
        if (funct7 === 9 && rd === 0) {
          if (rs2 !== 0 || !a) {
            return this.op("sfence.vma", r(rs1), r(rs2));
          }
          return rs1 !== 0 ? this.op("sfence.vma", r(rs1)) : "sfence.vma";
        }
        return null;
      }
      if (funct3 === 4) {
        return null;
      }
      const csrNum = bits(w, 31, 20);
      const csr = riscvCsrName(csrNum);
      const imm = funct3 >= 5;
      const src = imm ? String(rs1) : r(rs1);
      const base = CSR_OPS[funct3];
      if (w === 3221229683) {
        return "unimp";
      }
      if (a) {
        if (funct3 === 2 && rs1 === 0) {
          if (COUNTER_READS[csrNum]) {
            return this.op(COUNTER_READS[csrNum], r(rd));
          }
          return this.op("csrr", r(rd), csr);
        }
        if (rd === 0) {
          return this.op(CSR_SHORT_OPS[funct3], csr, src);
        }
      }
      return this.op(base, r(rd), csr, src);
    }
    // #region Compressed
    decodeCompressed(h) {
      const r = this.reg;
      const a = this.aliases;
      const quadrant = h & 3;
      const funct3 = bits(h, 15, 13);
      const rdP = bits(h, 4, 2) + 8;
      const rs1P = bits(h, 9, 7) + 8;
      const rd = bits(h, 11, 7);
      const rs2 = bits(h, 6, 2);
      const c = (name, ...ops) => this.op(name, ...ops);
      if (h === 0) {
        return a ? "unimp" : "c.unimp";
      }
      if (quadrant === 0) {
        switch (funct3) {
          case 0: {
            const nzuimm = bits(h, 10, 7) << 6 | bits(h, 12, 11) << 4 | bits(h, 5, 5) << 3 | bits(h, 6, 6) << 2;
            if (nzuimm === 0) {
              return null;
            }
            return c(a ? "addi" : "c.addi4spn", r(rdP), r(2), String(nzuimm));
          }
          case 2: {
            const off = bits(h, 5, 5) << 6 | bits(h, 12, 10) << 3 | bits(h, 6, 6) << 2;
            return c(a ? "lw" : "c.lw", r(rdP), `${off}(${r(rs1P)})`);
          }
          case 6: {
            const off = bits(h, 5, 5) << 6 | bits(h, 12, 10) << 3 | bits(h, 6, 6) << 2;
            return c(a ? "sw" : "c.sw", r(rdP), `${off}(${r(rs1P)})`);
          }
        }
        return null;
      }
      if (quadrant === 1) {
        const imm6 = signExtend(bits(h, 12, 12) << 5 | bits(h, 6, 2), 6);
        const jOff = signExtend(bits(h, 12, 12) << 11 | bits(h, 8, 8) << 10 | bits(h, 10, 9) << 8 | bits(h, 6, 6) << 7 | bits(h, 7, 7) << 6 | bits(h, 2, 2) << 5 | bits(h, 11, 11) << 4 | bits(h, 5, 3) << 1, 12);
        switch (funct3) {
          case 0:
            if (rd === 0) {
              if (imm6 === 0) {
                return a ? "nop" : c("c.addi", r(0), "0");
              }
              return a ? c("c.nop", String(imm6)) : c("c.addi", r(0), String(imm6));
            }
            return a ? c("addi", r(rd), r(rd), String(imm6)) : c("c.addi", r(rd), String(imm6));
          case 1:
            return a ? c("jal", this.target(jOff)) : c("c.jal", this.target(jOff));
          case 2:
            return c(a && rd !== 0 ? "li" : "c.li", r(rd), String(imm6));
          case 3: {
            if (rd === 2) {
              const imm = signExtend(bits(h, 12, 12) << 9 | bits(h, 4, 3) << 7 | bits(h, 5, 5) << 6 | bits(h, 2, 2) << 5 | bits(h, 6, 6) << 4, 10);
              return a ? c("addi", r(2), r(2), String(imm)) : c("c.addi16sp", r(2), String(imm));
            }
            if (imm6 === 0) {
              return null;
            }
            return c(a && rd !== 0 ? "lui" : "c.lui", r(rd), hex(imm6 & 1048575));
          }
          case 4: {
            const sub = bits(h, 11, 10);
            const shamt = bits(h, 12, 12) << 5 | bits(h, 6, 2);
            if (sub === 0 || sub === 1) {
              if (bits(h, 12, 12)) {
                return null;
              }
              const name2 = sub === 0 ? "srli" : "srai";
              if (shamt === 0) {
                return c("c." + name2 + "64", r(rs1P));
              }
              return a ? c(name2, r(rs1P), r(rs1P), hex(shamt)) : c("c." + name2, r(rs1P), hex(shamt));
            }
            if (sub === 2) {
              return a ? c("andi", r(rs1P), r(rs1P), String(imm6)) : c("c.andi", r(rs1P), String(imm6));
            }
            if (bits(h, 12, 12)) {
              return null;
            }
            const name = CA_NAMES[bits(h, 6, 5)];
            return a ? c(name, r(rs1P), r(rs1P), r(rdP)) : c("c." + name, r(rs1P), r(rdP));
          }
          case 5:
            return a ? c("j", this.target(jOff)) : c("c.j", this.target(jOff));
          case 6:
          case 7: {
            const bOff = signExtend(bits(h, 12, 12) << 8 | bits(h, 6, 5) << 6 | bits(h, 2, 2) << 5 | bits(h, 11, 10) << 3 | bits(h, 4, 3) << 1, 9);
            const name = funct3 === 6 ? "beqz" : "bnez";
            return c(a ? name : "c." + name, r(rs1P), this.target(bOff));
          }
        }
        return null;
      }
      switch (funct3) {
        case 0: {
          const shamt = bits(h, 12, 12) << 5 | bits(h, 6, 2);
          if (bits(h, 12, 12)) {
            return null;
          }
          if (shamt === 0) {
            return c("c.slli64", r(rd));
          }
          return a && rd !== 0 ? c("slli", r(rd), r(rd), hex(shamt)) : c("c.slli", r(rd), hex(shamt));
        }
        case 2: {
          if (rd === 0) {
            return null;
          }
          const off = bits(h, 3, 2) << 6 | bits(h, 12, 12) << 5 | bits(h, 6, 4) << 2;
          return c(a ? "lw" : "c.lwsp", r(rd), `${off}(${r(2)})`);
        }
        case 4: {
          const bit12 = bits(h, 12, 12);
          if (bit12 === 0) {
            if (rs2 === 0) {
              if (rd === 0) {
                return null;
              }
              if (!a) {
                return c("c.jr", r(rd));
              }
              return rd === 1 ? "ret" : c("jr", r(rd));
            }
            return a && rd !== 0 ? c("mv", r(rd), r(rs2)) : c("c.mv", r(rd), r(rs2));
          }
          if (rs2 === 0) {
            if (rd === 0) {
              return a ? "ebreak" : "c.ebreak";
            }
            return c(a ? "jalr" : "c.jalr", r(rd));
          }
          return a && rd !== 0 ? c("add", r(rd), r(rd), r(rs2)) : c("c.add", r(rd), r(rs2));
        }
        case 6: {
          const off = bits(h, 8, 7) << 6 | bits(h, 12, 9) << 2;
          return c(a ? "sw" : "c.swsp", r(rs2), `${off}(${r(2)})`);
        }
      }
      return null;
    }
  };
  var cachedDisassemblers = /* @__PURE__ */ new Map();
  function disassembleRiscv(word, opts = {}) {
    if (opts.pc !== void 0) {
      return new Disassembler(opts).decode(word);
    }
    const key = (opts.abiNames !== false ? "a" : "n") + (opts.aliases !== false ? "p" : "r");
    let d = cachedDisassemblers.get(key);
    if (d === void 0) {
      d = new Disassembler(opts);
      cachedDisassemblers.set(key, d);
    }
    return d.decode(word);
  }
  function formatRiscvBinaryString(binaryString, is2State, opts = {}) {
    if (!is2State) {
      return "x";
    }
    const low = binaryString.length > 32 ? binaryString.slice(-32) : binaryString;
    const word = parseInt(low, 2) >>> 0;
    if (low.length <= 16 && (word & 3) === 3) {
      return "0x" + word.toString(16).padStart(4, "0");
    }
    const text = disassembleRiscv(word, opts);
    if (text !== null) {
      return text;
    }
    const digits = (word & 3) !== 3 ? 4 : 8;
    return "0x" + ((word & 3) !== 3 ? word & 65535 : word).toString(16).padStart(digits, "0");
  }
  return __toCommonJS(riscv_disasm_exports);
})();
window.cmuxRiscvDisasm = cmuxRiscvDisasm;
