// The page's text-breakpoint formatters (Resources/vaporview/cmux-formats.js): the viewer's own
// code from the VaporView webview sources in the cmux fork, bundled by build-formats.mjs. Nothing
// here is rewritten.
import { formatRiscvBinaryString } from "./riscv_disasm";
import { parseAliasFile, formatWithTable } from "./value_alias";
import { valueFormatList, formatAscii, valueIs9State } from "./value_format";

const byId = (id: string) => {
  const f = valueFormatList.find((x) => x.id === id);
  if (!f) {throw new Error("no format " + id);}
  return f;
};
export const riscvOptions = {
  riscv: { abiNames: true, aliases: true },
  riscv_numeric: { abiNames: false, aliases: true },
  riscv_noalias: { abiNames: true, aliases: false },
  riscv_numeric_noalias: { abiNames: false, aliases: false },
};
export { formatRiscvBinaryString, parseAliasFile, formatWithTable, formatAscii, valueIs9State };
export const formatHexString = byId("hexadecimal").formatString;
export const formatOctString = byId("octal").formatString;
export const formatBinString = byId("binary").formatString;
export const formatDecString = byId("decimal").formatString;
export const formatSdecString = byId("signed").formatString;
