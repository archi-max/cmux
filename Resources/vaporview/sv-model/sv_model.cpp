// cmux-sv-model: the trace model sidecar for cmux's driver tracing (cmux-trace.js).
//
// It elaborates a SystemVerilog design with slang (https://github.com/MikePopoloski/slang, MIT,
// pinned in build.sh) from the same command line as the editor's slang profile (build file, top,
// defines), and answers per-instance questions about it: each signal's width and kind, each
// continuous assignment, each procedure with its clocking and its statement tree, and each port
// connection, with expressions lowered to cmux-expr text (Resources/vaporview/cmux-expr.js) whose
// operands are leaf tokens (_L<n>_ signals, _E<n>_ unpacked-array elements, _O<n>_ parts the
// evaluator does not model). Every leaf is read as a [w-1:0] vector: selects, struct members and
// packed-array elements are lowered here to 0-based bit windows.
//
// Protocol: one JSON object per line on stdin, one JSON reply per line on stdout, matched by id.
// The first line out is {"id":0,"ready":true,...}.
//   {"id":1,"cmd":"load","args":["-f","files.f","--top","tb"],"cwd":"/dir"}
//       -> {"id":1,"ok":true,"tops":["tb"],"errors":n,"messages":[...],"fingerprint":"<16 hex>","files":n,"ms":n}
//   {"id":2,"cmd":"instance","path":"tb.dut"}   -> {"id":2,"ok":true,"model":{...}}
//   {"id":3,"cmd":"lookup","path":"tb.dut.g[0].x"} -> {"id":3,"ok":true,"instance":"tb.dut","name":"g[0].x"}
//   {"id":4,"cmd":"instances"} -> {"id":4,"ok":true,"tops":["tb"],"instances":["tb","tb.dut",...]} (sorted)
//   {"id":5,"cmd":"writers","path":"tb.bus"} -> {"id":5,"ok":true,"writers":["tb.dut","tb.mem"]} (sorted):
//       the other instances whose statements write into it ($abs: lvalues; an interface instance
//       written through modport ports), from an index built over every instance on first use
//   {"id":6,"cmd":"stale"} -> {"id":6,"ok":true,"changed":false,"fingerprint":"..."}: whether a file the
//       load read (sources, includes, library and command files) has another size or time now,
//       or was written while the load read it; cmux then loads the design again
//   {"id":7,"cmd":"sources"} -> {"id":7,"ok":true,"sources":[{"path":"/abs/a.sv","mtime":<ms since 1970>},...]}
//   {"id":4,"cmd":"version"}
// A load's reply also has "fingerprint": a hash of its command line, folder and the text of every
// file it read, so a load of unchanged text is known to be the same design.
// Errors: {"id":n,"ok":false,"error":"<code>","message":"..."}.
//
// slang's license:
//
//   Copyright (c) 2015-2026 Michael Popoloski
//
//   Permission is hereby granted, free of charge, to any person obtaining a copy
//   of this software and associated documentation files (the "Software"), to deal
//   in the Software without restriction, including without limitation the rights
//   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//   copies of the Software, and to permit persons to whom the Software is
//   furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in
//   all copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//   THE SOFTWARE.

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <sys/stat.h>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <iostream>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <tuple>
#include <unordered_map>
#include <vector>

#include "slang/ast/ASTVisitor.h"
#include "slang/ast/Compilation.h"
#include "slang/ast/EvalContext.h"
#include "slang/ast/Expression.h"
#include "slang/ast/Statement.h"
#include "slang/ast/SystemSubroutine.h"
#include "slang/ast/TimingControl.h"
#include "slang/ast/expressions/AssignmentExpressions.h"
#include "slang/ast/expressions/CallExpression.h"
#include "slang/ast/expressions/ConversionExpression.h"
#include "slang/ast/expressions/LiteralExpressions.h"
#include "slang/ast/expressions/MiscExpressions.h"
#include "slang/ast/expressions/OperatorExpressions.h"
#include "slang/ast/expressions/SelectExpressions.h"
#include "slang/ast/statements/ConditionalStatements.h"
#include "slang/ast/statements/LoopStatements.h"
#include "slang/ast/statements/MiscStatements.h"
#include "slang/ast/symbols/BlockSymbols.h"
#include "slang/ast/symbols/CompilationUnitSymbols.h"
#include "slang/ast/symbols/InstanceSymbols.h"
#include "slang/ast/symbols/MemberSymbols.h"
#include "slang/ast/symbols/PortSymbols.h"
#include "slang/ast/symbols/SubroutineSymbols.h"
#include "slang/ast/symbols/VariableSymbols.h"
#include "slang/ast/types/AllTypes.h"
#include "slang/diagnostics/DiagnosticEngine.h"
#include "slang/driver/Driver.h"
#include "slang/syntax/AllSyntax.h"
#include "slang/syntax/SyntaxTree.h"
#include "slang/text/Json.h"
#include "slang/text/SourceManager.h"
#include "slang/util/VersionInfo.h"

using namespace slang;
using namespace slang::ast;

namespace {

// The protocol version: bump when the model's shape changes (cmux-trace.js checks it).
constexpr int kModelVersion = 1;

// ---------------------------------------------------------------------------------------------
// A small JSON reader for requests (objects of strings, numbers, booleans and string arrays).
struct JValue {
    enum Kind { Null, Bool, Number, String, Array, Object } kind = Null;
    bool b = false;
    double n = 0;
    std::string s;
    std::vector<JValue> a;
    std::vector<std::pair<std::string, JValue>> o;
    const JValue* get(std::string_view key) const {
        for (auto& [k, v] : o) {
            if (k == key)
                return &v;
        }
        return nullptr;
    }
    std::string str(std::string_view key) const {
        auto v = get(key);
        return v && v->kind == String ? v->s : std::string();
    }
};

class JParser {
public:
    explicit JParser(std::string_view text) : t(text) {}
    std::optional<JValue> parse() {
        JValue v;
        if (!value(v))
            return std::nullopt;
        ws();
        if (i != t.size())
            return std::nullopt;
        return v;
    }

private:
    std::string_view t;
    size_t i = 0;
    void ws() {
        while (i < t.size() && (t[i] == ' ' || t[i] == '\t' || t[i] == '\r' || t[i] == '\n'))
            i++;
    }
    bool lit(std::string_view w) {
        if (t.substr(i, w.size()) != w)
            return false;
        i += w.size();
        return true;
    }
    bool string(std::string& out) {
        if (i >= t.size() || t[i] != '"')
            return false;
        i++;
        while (i < t.size() && t[i] != '"') {
            char c = t[i++];
            if (c != '\\') {
                out += c;
                continue;
            }
            if (i >= t.size())
                return false;
            char e = t[i++];
            switch (e) {
                case 'n': out += '\n'; break;
                case 't': out += '\t'; break;
                case 'r': out += '\r'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'u': {
                    if (i + 4 > t.size())
                        return false;
                    unsigned cp = std::stoul(std::string(t.substr(i, 4)), nullptr, 16);
                    i += 4;
                    if (cp >= 0xD800 && cp < 0xDC00 && t.substr(i, 2) == "\\u" && i + 6 <= t.size()) {
                        unsigned lo = std::stoul(std::string(t.substr(i + 2, 4)), nullptr, 16);
                        i += 6;
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    }
                    if (cp < 0x80) {
                        out += char(cp);
                    }
                    else if (cp < 0x800) {
                        out += char(0xC0 | (cp >> 6));
                        out += char(0x80 | (cp & 0x3F));
                    }
                    else if (cp < 0x10000) {
                        out += char(0xE0 | (cp >> 12));
                        out += char(0x80 | ((cp >> 6) & 0x3F));
                        out += char(0x80 | (cp & 0x3F));
                    }
                    else {
                        out += char(0xF0 | (cp >> 18));
                        out += char(0x80 | ((cp >> 12) & 0x3F));
                        out += char(0x80 | ((cp >> 6) & 0x3F));
                        out += char(0x80 | (cp & 0x3F));
                    }
                    break;
                }
                default: out += e;
            }
        }
        if (i >= t.size())
            return false;
        i++;
        return true;
    }
    bool value(JValue& v) {
        ws();
        if (i >= t.size())
            return false;
        char c = t[i];
        if (c == '{') {
            v.kind = JValue::Object;
            i++;
            ws();
            if (i < t.size() && t[i] == '}') {
                i++;
                return true;
            }
            while (true) {
                ws();
                std::string k;
                if (!string(k))
                    return false;
                ws();
                if (i >= t.size() || t[i] != ':')
                    return false;
                i++;
                JValue x;
                if (!value(x))
                    return false;
                v.o.emplace_back(std::move(k), std::move(x));
                ws();
                if (i < t.size() && t[i] == ',') {
                    i++;
                    continue;
                }
                if (i < t.size() && t[i] == '}') {
                    i++;
                    return true;
                }
                return false;
            }
        }
        if (c == '[') {
            v.kind = JValue::Array;
            i++;
            ws();
            if (i < t.size() && t[i] == ']') {
                i++;
                return true;
            }
            while (true) {
                JValue x;
                if (!value(x))
                    return false;
                v.a.push_back(std::move(x));
                ws();
                if (i < t.size() && t[i] == ',') {
                    i++;
                    continue;
                }
                if (i < t.size() && t[i] == ']') {
                    i++;
                    return true;
                }
                return false;
            }
        }
        if (c == '"') {
            v.kind = JValue::String;
            return string(v.s);
        }
        if (lit("true")) {
            v.kind = JValue::Bool;
            v.b = true;
            return true;
        }
        if (lit("false")) {
            v.kind = JValue::Bool;
            return true;
        }
        if (lit("null"))
            return true;
        size_t start = i;
        while (i < t.size() && (isdigit((unsigned char)t[i]) || t[i] == '-' || t[i] == '+' ||
                                t[i] == '.' || t[i] == 'e' || t[i] == 'E'))
            i++;
        if (start == i)
            return false;
        v.kind = JValue::Number;
        v.n = std::strtod(std::string(t.substr(start, i - start)).c_str(), nullptr);
        return true;
    }
};

// ---------------------------------------------------------------------------------------------
// Lowered expressions.
struct Loc {
    std::string file;
    size_t line = 0, col = 0, endLine = 0, endCol = 0;
    bool valid = false;
};

struct Expr;
struct Elem {
    std::string array;            // relative name of the unpacked array
    std::unique_ptr<Expr> index;  // its index expression
    int64_t width = 0, lo = 0, hi = 0;
};
struct Opaque {
    std::string src, kind, why;
    Loc loc;
};
struct Expr {
    std::string text;
    std::vector<std::string> leaves;
    std::vector<std::vector<Loc>> leafLocs;
    std::vector<Elem> elems;
    std::vector<Opaque> opaque;
    int64_t width = 0;
    bool isSigned = false;
    std::string src;
    Loc loc;
};

// A 0-based bit window of a leaf: tok[off +: width], off constant or an expression's text.
struct Window {
    std::string tok;
    int64_t tokWidth = 0;
    std::optional<int64_t> constOff;
    std::string offText;
    int64_t width = 0;
    bool ok = false;
};

std::string sizedBits(const SVInt& v) {
    std::string bits;
    auto w = v.getBitWidth();
    bits.reserve(w);
    for (int32_t k = int32_t(w) - 1; k >= 0; k--) {
        logic_t b = v[k];
        bits += b.isUnknown() ? (b.value == logic_t::Z_VALUE ? 'z' : 'x') : (b.value ? '1' : '0');
    }
    return std::to_string(w) + (v.isSigned() ? "'sb" : "'b") + bits;
}

// A system task or function slang doesn't know (a simulator's own, such as $fsdbDumpvars): taken as
// a function of any arguments returning int, so the procedure that calls it is still modelled
// rather than dropped as an invalid statement.
class UnknownSystemCall : public SystemSubroutine {
public:
    explicit UnknownSystemCall(std::string name) : SystemSubroutine(std::move(name), SubroutineKind::Function) {}
    bool allowEmptyArgument(size_t) const final { return true; }
    const Expression& bindArgument(size_t index, const ASTContext& context, const syntax::ExpressionSyntax& syntax,
                                   const Args& previous) const final {
        // A scope or variable name (a dump task's "what to dump"): any symbol, not a value.
        if (syntax::NameSyntax::isKind(syntax.kind))
            return ArbitrarySymbolExpression::fromSyntax(context.getCompilation(), syntax.as<syntax::NameSyntax>(), context);
        return SystemSubroutine::bindArgument(index, context, syntax, previous);
    }
    const Type& checkArguments(const ASTContext& context, const Args&, SourceRange, const Expression*) const final {
        return context.getCompilation().getIntType();
    }
    ConstantValue eval(EvalContext& context, const Args&, SourceRange range,
                       const CallExpression::SystemCallInfo&) const final {
        notConst(context, range);
        return nullptr;
    }
};

// The system names ($...) a syntax tree calls.
void systemNames(const syntax::SyntaxNode& n, std::set<std::string>& out) {
    for (size_t i = 0, count = n.getChildCount(); i < count; i++) {
        if (auto child = n.childNode(i))
            systemNames(*child, out);
        else if (auto t = n.childToken(i); t && t.kind == parsing::TokenKind::SystemIdentifier)
            out.emplace(t.valueText());
    }
}

// A simulator's own task that only reads what it is given by name (a dump task's "what to dump").
bool readsOnlyByName(std::string_view n) {
    for (std::string_view p : {"$fsdb", "$vcdplus", "$vcd", "$dump", "$shm_", "$record", "$sdf", "$vpd", "$wlf", "$assert"})
        if (n.substr(0, p.size()) == p)
            return true;
    return false;
}

// The variables an expression or statement writes: assignment targets (output arguments of calls
// are assignments too), x++ / x-- operands; the symbol under selects and member accesses. Also what
// it may write that isn't re-executed: a variable given by name to a simulator's own task (one
// slang doesn't know, such as a vendor $deposit-style task), and the module variables a called
// task's or function's body writes (followed a few calls deep, without recursion). Into what slang
// could not bind too (a block with a call to a task it wasn't given is Invalid as a whole; its
// child still holds the statements). `sites`: for each of `out`, where it is written (the
// assignment, the ++/--, or the call), at most 8.
struct WriteFinder : public ASTVisitor<WriteFinder, VisitFlags::Statements | VisitFlags::Expressions | VisitFlags::Bad> {
    std::vector<const Symbol*> out;
    std::vector<std::vector<const Expression*>> sites;
    std::vector<const SubroutineSymbol*> calling;
    const Expression* site = nullptr;
    static bool within(const Symbol& s, const Symbol& outer) {
        for (auto scope = s.getParentScope(); scope; scope = scope->asSymbol().getParentScope())
            if (&scope->asSymbol() == &outer)
                return true;
        return false;
    }
    // An input port's variable: a task given it by name reads it (writing an input is illegal).
    static bool inputPort(const Symbol& sym) {
        auto scope = sym.getParentScope();
        if (!scope || scope->asSymbol().kind != SymbolKind::InstanceBody)
            return false;
        for (auto p : scope->asSymbol().as<InstanceBodySymbol>().getPortList())
            if (p->kind == SymbolKind::Port && p->as<PortSymbol>().internalSymbol == &sym)
                return p->as<PortSymbol>().direction == ArgumentDirection::In;
        return false;
    }
    void addSymbol(const Symbol* sym, const Expression* at) {
        if (!sym)
            return;
        auto it = std::find(out.begin(), out.end(), sym);
        if (it == out.end()) {
            out.push_back(sym);
            sites.emplace_back();
            it = out.end() - 1;
        }
        auto& here = sites[size_t(it - out.begin())];
        if (at && here.size() < 8 && std::find(here.begin(), here.end(), at) == here.end())
            here.push_back(at);
    }
    void handle(const InvalidStatement& s) {
        if (s.child)
            s.child->visit(*this);
    }
    void handle(const InvalidExpression& e) {
        if (e.child)
            e.child->visit(*this);
    }
    void handle(const CallExpression& c) {
        if (c.isSystemCall()) {
            auto& info = std::get<CallExpression::SystemCallInfo>(c.subroutine);
            if (dynamic_cast<const UnknownSystemCall*>(info.subroutine.get()) && !readsOnlyByName(c.getSubroutineName())) {
                for (auto arg : c.arguments()) {
                    if (arg->kind != ExpressionKind::ArbitrarySymbol)
                        continue;
                    auto sym = arg->as<ArbitrarySymbolExpression>().symbol;
                    if (sym && (sym->kind == SymbolKind::Variable || sym->kind == SymbolKind::Net) && !inputPort(*sym))
                        addSymbol(sym, &c);
                }
            }
        }
        else if (auto sub = std::get<const SubroutineSymbol*>(c.subroutine);
                 sub && calling.size() < 4 && std::find(calling.begin(), calling.end(), sub) == calling.end()) {
            WriteFinder inner;
            inner.calling = calling;
            inner.calling.push_back(sub);
            sub->getBody().visit(inner);
            // Its own locals and arguments aren't the caller's variables.
            for (auto sym : inner.out)
                if (!within(*sym, *sub))
                    addSymbol(sym, &c);
        }
        visitDefault(c);
    }
    static const Symbol* base(const Expression* e) {
        while (e) {
            switch (e->kind) {
                case ExpressionKind::NamedValue:
                case ExpressionKind::HierarchicalValue: return &e->as<ValueExpressionBase>().symbol;
                case ExpressionKind::ElementSelect: e = &e->as<ElementSelectExpression>().value(); break;
                case ExpressionKind::RangeSelect: e = &e->as<RangeSelectExpression>().value(); break;
                case ExpressionKind::MemberAccess: e = &e->as<MemberAccessExpression>().value(); break;
                case ExpressionKind::Conversion: e = &e->as<ConversionExpression>().operand(); break;
                default: return nullptr;
            }
        }
        return nullptr;
    }
    void add(const Expression& lv) {
        if (lv.kind == ExpressionKind::Concatenation) {
            for (auto op : lv.as<ConcatenationExpression>().operands())
                add(*op);
            return;
        }
        addSymbol(base(&lv), site);
    }
    void handle(const AssignmentExpression& a) {
        auto outer = site;
        site = &a;
        add(a.left());
        site = outer;
        visitDefault(a);
    }
    void handle(const UnaryExpression& u) {
        if (u.op == UnaryOperator::Preincrement || u.op == UnaryOperator::Predecrement ||
            u.op == UnaryOperator::Postincrement || u.op == UnaryOperator::Postdecrement) {
            auto outer = site;
            site = &u;
            add(u.operand());
            site = outer;
        }
        visitDefault(u);
    }
};

class Model {
public:
    Model(Compilation& comp, SourceManager& sm) : comp(comp), sm(sm) { index(); }

    std::vector<std::string> tops() const {
        std::vector<std::string> out;
        for (auto inst : comp.getRoot().topInstances)
            out.push_back(inst->getHierarchicalPath());
        return out;
    }

    std::vector<std::string> instancePaths() const {
        std::vector<std::string> out;
        for (auto& [k, v] : instances)
            out.push_back(k);
        std::sort(out.begin(), out.end());
        return out;
    }

    const InstanceSymbol* instance(const std::string& path) const {
        auto it = instances.find(path);
        return it == instances.end() ? nullptr : it->second;
    }

    // The deepest instance a dotted path is under, and the rest of the path.
    std::optional<std::pair<std::string, std::string>> lookup(const std::string& path) const {
        std::string best;
        for (size_t k = 0; k <= path.size(); k++) {
            if (k == path.size() || path[k] == '.') {
                auto prefix = path.substr(0, k);
                if (instances.count(prefix))
                    best = prefix;
            }
        }
        if (best.empty())
            return std::nullopt;
        return std::make_pair(best, best.size() < path.size() ? path.substr(best.size() + 1) : "");
    }

    void writeInstance(JsonWriter& w, const InstanceSymbol& inst) {
        cur = &inst;
        curPath = inst.getHierarchicalPath();
        files.clear();
        fileIndex.clear();
        auto parent = parentOf(inst);
        w.startObject();
        w.writeProperty("version");
        w.writeValue(int64_t(kModelVersion));
        w.writeProperty("path");
        w.writeValue(curPath);
        w.writeProperty("module");
        w.writeValue(inst.getDefinition().name);
        if (parent) {
            w.writeProperty("parent");
            w.writeValue(parent->getHierarchicalPath());
        }
        writeLocProp(w, "loc", inst.location, inst.name.size());
        w.writeProperty("ports");
        writePorts(w, inst, parent);
        // An interface: its modports and each one's ports (direction, the interface signal it
        // names), for load trace (a modport taking a signal as an input is a load of it).
        if (inst.getDefinition().definitionKind == DefinitionKind::Interface) {
            w.writeProperty("interface");
            w.writeValue(true);
            w.writeProperty("modports");
            w.startArray();
            for (auto& member : inst.body.members()) {
                if (member.kind != SymbolKind::Modport)
                    continue;
                auto& modport = member.as<ModportSymbol>();
                w.startObject();
                w.writeProperty("name");
                w.writeValue(modport.name);
                writeLocProp(w, "loc", modport.location, modport.name.size());
                w.writeProperty("ports");
                w.startArray();
                for (auto& pm : modport.members()) {
                    if (pm.kind != SymbolKind::ModportPort)
                        continue;
                    auto& port = pm.as<ModportPortSymbol>();
                    w.startObject();
                    w.writeProperty("name");
                    w.writeValue(port.name);
                    w.writeProperty("dir");
                    w.writeValue(toString(port.direction));
                    if (port.internalSymbol) {
                        w.writeProperty("internal");
                        w.writeValue(port.internalSymbol->name);
                    }
                    writeLocProp(w, "loc", port.location, port.name.size());
                    w.endObject();
                }
                w.endArray();
                w.endObject();
            }
            w.endArray();
            // The instances whose interface ports this interface is bound to, at any depth (through
            // the interface ports passing it down): where its signals can be read through a port.
            w.writeProperty("connections");
            w.startArray();
            for (auto& c : interfaceUsers(inst)) {
                w.startObject();
                w.writeProperty("instance");
                w.writeValue(c.instance);
                w.writeProperty("port");
                w.writeValue(c.port);
                if (!c.modport.empty()) {
                    w.writeProperty("modport");
                    w.writeValue(c.modport);
                }
                w.endObject();
            }
            w.endArray();
        }
        // Value parameters and localparams of the body (not its generate blocks'): integers without
        // x/z as numbers, others as slang prints them; cmux compares them with the KDB's.
        w.writeProperty("params");
        w.startObject();
        for (auto& member : inst.body.members()) {
            if (member.kind != SymbolKind::Parameter)
                continue;
            auto& param = member.as<ParameterSymbol>();
            auto& value = param.getValue();
            w.writeProperty(param.name);
            std::optional<int64_t> number;
            if (value.isInteger() && !value.integer().hasUnknown())
                number = value.integer().as<int64_t>();
            if (number)
                w.writeValue(*number);
            else
                w.writeValue(value.toString());
        }
        w.endObject();
        // Members (signals, assigns, procedures, children) in this body, with generate blocks.
        std::vector<const Symbol*> signals, assigns, procs, children;
        collect(inst.body, signals, assigns, procs, children);
        w.writeProperty("signals");
        w.startObject();
        for (auto s : signals)
            writeSignal(w, s->as<ValueSymbol>());
        w.endObject();
        w.writeProperty("assigns");
        w.startArray();
        for (auto a : assigns)
            writeAssign(w, a->as<ContinuousAssignSymbol>());
        w.endArray();
        w.writeProperty("procs");
        w.startArray();
        int id = 0;
        for (auto p : procs)
            writeProc(w, p->as<ProceduralBlockSymbol>(), id++);
        w.endArray();
        w.writeProperty("children");
        w.startArray();
        for (auto c : children) {
            auto& child = c->as<InstanceSymbol>();
            w.startObject();
            auto childPath = child.getHierarchicalPath();
            w.writeProperty("path");
            w.writeValue(childPath);
            w.writeProperty("name");
            w.writeValue(rel(childPath));
            w.writeProperty("module");
            w.writeValue(child.getDefinition().name);
            writeLocProp(w, "loc", child.location, child.name.size());
            w.writeProperty("ports");
            writePorts(w, child, &inst);
            w.endObject();
        }
        w.endArray();
        w.writeProperty("files");
        w.startArray();
        for (auto& f : files)
            w.writeValue(f);
        w.endArray();
        w.endObject();
    }

private:
    Compilation& comp;
    SourceManager& sm;
    std::unordered_map<std::string, const InstanceSymbol*> instances;
    std::unordered_map<const InstanceSymbol*, const InstanceSymbol*> parents;
    const InstanceSymbol* cur = nullptr;  // the instance names are relative to
    std::string curPath;
    mutable std::vector<std::string> files;
    mutable std::unordered_map<std::string, size_t> fileIndex;

    // ---- the instance index ----
    void index() {
        for (auto top : comp.getRoot().topInstances)
            indexInstance(*top, nullptr);
    }
    void indexInstance(const InstanceSymbol& inst, const InstanceSymbol* parent) {
        instances[inst.getHierarchicalPath()] = &inst;
        parents[&inst] = parent;
        indexScope(inst.body, inst);
    }
    void indexScope(const Scope& scope, const InstanceSymbol& owner) {
        for (auto& m : scope.members()) {
            if (m.kind == SymbolKind::Instance) {
                indexInstance(m.as<InstanceSymbol>(), &owner);
            }
            else if (m.kind == SymbolKind::GenerateBlock) {
                auto& g = m.as<GenerateBlockSymbol>();
                if (!g.isUninstantiated)
                    indexScope(g, owner);
            }
            else if (m.kind == SymbolKind::GenerateBlockArray) {
                for (auto e : m.as<GenerateBlockArraySymbol>().entries) {
                    if (!e->isUninstantiated)
                        indexScope(*e, owner);
                }
            }
            else if (m.kind == SymbolKind::InstanceArray) {
                indexArray(m.as<InstanceArraySymbol>(), owner);
            }
        }
    }
    void indexArray(const InstanceArraySymbol& arr, const InstanceSymbol& owner) {
        for (auto e : arr.elements) {
            if (e->kind == SymbolKind::Instance)
                indexInstance(e->as<InstanceSymbol>(), &owner);
            else if (e->kind == SymbolKind::InstanceArray)
                indexArray(e->as<InstanceArraySymbol>(), owner);
        }
    }
    // ---- interface port bindings: interface instance -> the instances whose interface port it is ----
    struct InterfaceUser {
        std::string instance, port, modport;
    };
    std::unordered_map<const InstanceSymbol*, std::vector<InterfaceUser>> ifaceUsers;
    bool ifaceUsersBuilt = false;
    // The interface instances a connection names: an instance, each element of an array, or (an
    // interface port of the parent passed on) what that port is bound to.
    static void interfaceInstances(const Symbol* sym, std::vector<const InstanceSymbol*>& out, int depth = 0) {
        if (!sym || depth > 64)
            return;
        if (sym->kind == SymbolKind::Instance)
            out.push_back(&sym->as<InstanceSymbol>());
        else if (sym->kind == SymbolKind::InstanceArray) {
            for (auto e : sym->as<InstanceArraySymbol>().elements)
                interfaceInstances(e, out, depth + 1);
        }
        else if (sym->kind == SymbolKind::InterfacePort)
            interfaceInstances(sym->as<InterfacePortSymbol>().getConnection().first, out, depth + 1);
    }
    const std::vector<InterfaceUser>& interfaceUsers(const InstanceSymbol& iface) {
        if (!ifaceUsersBuilt) {
            ifaceUsersBuilt = true;
            for (auto& [path, inst] : instances) {
                for (auto p : inst->body.getPortList()) {
                    if (p->kind != SymbolKind::InterfacePort)
                        continue;
                    auto& port = p->as<InterfacePortSymbol>();
                    auto conn = inst->getPortConnection(port);
                    if (!conn)
                        continue;
                    auto [sym, modport] = conn->getIfaceConn();
                    std::vector<const InstanceSymbol*> bound;
                    interfaceInstances(sym, bound);
                    for (auto b : bound)
                        ifaceUsers[b].push_back({path, std::string(port.name), modport ? std::string(modport->name) : std::string(port.modport)});
                }
            }
            for (auto& [_, users] : ifaceUsers)
                std::sort(users.begin(), users.end(), [](auto& a, auto& b) { return std::tie(a.instance, a.port) < std::tie(b.instance, b.port); });
        }
        static const std::vector<InterfaceUser> none;
        auto it = ifaceUsers.find(&iface);
        return it == ifaceUsers.end() ? none : it->second;
    }

    const InstanceSymbol* parentOf(const InstanceSymbol& inst) const {
        auto it = parents.find(&inst);
        return it == parents.end() ? nullptr : it->second;
    }

    void collect(const Scope& scope, std::vector<const Symbol*>& signals, std::vector<const Symbol*>& assigns,
                 std::vector<const Symbol*>& procs, std::vector<const Symbol*>& children) {
        for (auto& m : scope.members()) {
            switch (m.kind) {
                case SymbolKind::Variable:
                case SymbolKind::Net: signals.push_back(&m); break;
                case SymbolKind::ContinuousAssign: assigns.push_back(&m); break;
                case SymbolKind::ProceduralBlock: procs.push_back(&m); break;
                case SymbolKind::Instance: children.push_back(&m); break;
                case SymbolKind::InstanceArray: collectArray(m.as<InstanceArraySymbol>(), children); break;
                case SymbolKind::GenerateBlock:
                    if (!m.as<GenerateBlockSymbol>().isUninstantiated)
                        collect(m.as<GenerateBlockSymbol>(), signals, assigns, procs, children);
                    break;
                case SymbolKind::GenerateBlockArray:
                    for (auto e : m.as<GenerateBlockArraySymbol>().entries) {
                        if (!e->isUninstantiated)
                            collect(*e, signals, assigns, procs, children);
                    }
                    break;
                default: break;
            }
        }
    }
    void collectArray(const InstanceArraySymbol& arr, std::vector<const Symbol*>& children) {
        for (auto e : arr.elements) {
            if (e->kind == SymbolKind::Instance)
                children.push_back(e);
            else if (e->kind == SymbolKind::InstanceArray)
                collectArray(e->as<InstanceArraySymbol>(), children);
        }
    }

    // ---- names ----
    std::string rel(const std::string& path) const {
        if (path.size() > curPath.size() && path.compare(0, curPath.size(), curPath) == 0 &&
            path[curPath.size()] == '.')
            return path.substr(curPath.size() + 1);
        return "$abs:" + path;
    }
    std::string relName(const Symbol& sym) const {
        auto scope = sym.getParentScope();
        if (scope && scope->isProceduralContext())
            return "$local:" + std::string(sym.name);
        return rel(sym.getHierarchicalPath());
    }
    // A written variable's name: one declared in another instance (a testbench's force, $deposit
    // or hierarchical write into dut) by its $abs: path, so that instance's drivers can find it.
    std::string writtenName(const Symbol& sym) const {
        auto scope = sym.getParentScope();
        if (scope && scope->isProceduralContext())
            return "$local:" + std::string(sym.name);
        for (auto sc = scope; sc; sc = sc->asSymbol().getParentScope()) {
            if (sc->asSymbol().kind == SymbolKind::InstanceBody) {
                if (cur && &sc->asSymbol() != &cur->body)
                    return "$abs:" + sym.getHierarchicalPath();
                break;
            }
        }
        return relName(sym);
    }
    static const Symbol& throughModport(const Symbol& sym) {
        const Symbol* s = &sym;
        while (s->kind == SymbolKind::ModportPort) {
            auto inner = s->as<ModportPortSymbol>().internalSymbol;
            if (!inner)
                break;
            s = inner;
        }
        return *s;
    }

    // ---- locations ----
    Loc loc(SourceRange r) const {
        Loc l;
        if (!r.start().valid())
            return l;
        auto s = sm.getFullyOriginalLoc(r.start());
        auto e = sm.getFullyOriginalLoc(r.end());
        if (!s.valid() || !s.buffer().valid())
            return l;
        l.file = sm.getFullPath(s.buffer()).string();
        if (l.file.empty())
            l.file = std::string(sm.getFileName(s));
        l.line = sm.getLineNumber(s);
        l.col = sm.getColumnNumber(s);
        if (e.valid() && e.buffer() == s.buffer()) {
            l.endLine = sm.getLineNumber(e);
            l.endCol = sm.getColumnNumber(e);
        }
        else {
            l.endLine = l.line;
            l.endCol = l.col;
        }
        l.valid = true;
        return l;
    }
    // A location: [file index (into the model's files), line, col, endLine, endCol], 1-based.
    void writeLoc(JsonWriter& w, const Loc& l) const {
        auto it = fileIndex.find(l.file);
        size_t f = files.size();
        if (it == fileIndex.end()) {
            fileIndex.emplace(l.file, f);
            files.push_back(l.file);
        }
        else {
            f = it->second;
        }
        w.startArray();
        w.writeValue(uint64_t(f));
        w.writeValue(uint64_t(l.line));
        w.writeValue(uint64_t(l.col));
        w.writeValue(uint64_t(l.endLine));
        w.writeValue(uint64_t(l.endCol));
        w.endArray();
    }
    void writeLocProp(JsonWriter& w, std::string_view name, SourceRange r) const {
        auto l = loc(r);
        if (!l.valid)
            return;
        w.writeProperty(name);
        writeLoc(w, l);
    }
    void writeLocProp(JsonWriter& w, std::string_view name, SourceLocation at, size_t len) const {
        writeLocProp(w, name, SourceRange(at, at + len));
    }
    std::string text(const Expression& e) const { return e.syntax ? trim(e.syntax->toString()) : ""; }
    std::string text(const Statement& s) const { return s.syntax ? trim(s.syntax->toString()) : ""; }
    // An expression's own text, without the comments and line breaks before it.
    std::string ownText(const Expression& e) const {
        if (!e.syntax)
            return "";
        auto all = e.syntax->toString();
        size_t lead = 0;
        for (auto& t : e.syntax->getFirstToken().trivia())
            lead += t.getRawText().size();
        return trim(lead <= all.size() ? all.substr(lead) : all);
    }
    static std::string trim(std::string s) {
        // Comments and line breaks inside a statement: one line, spaces collapsed.
        std::string out;
        bool space = false;
        for (char c : s) {
            if (c == '\n' || c == '\r' || c == '\t' || c == ' ') {
                space = !out.empty();
                continue;
            }
            if (space)
                out += ' ';
            space = false;
            out += c;
        }
        return out;
    }

    // ---- expressions ----
    std::optional<SVInt> constantInt(const Expression& e) const {
        if (auto cv = e.getConstant(); cv && cv->isInteger())
            return cv->integer();
        if (e.kind == ExpressionKind::IntegerLiteral)
            return e.as<IntegerLiteral>().getValue();
        // Parameters, genvars and folded subexpressions.
        if (!isConstTree(e))
            return std::nullopt;
        EvalContext ctx(cur ? static_cast<const Symbol&>(cur->body) : comp.getRoot());
        auto cv = e.eval(ctx);
        if (cv && cv.isInteger())
            return cv.integer();
        return std::nullopt;
    }
    static bool isConstTree(const Expression& e) {
        bool ok = true;
        e.visitSymbolReferences([&](const Expression&, const Symbol& sym) {
            if (sym.kind != SymbolKind::Parameter && sym.kind != SymbolKind::EnumValue &&
                sym.kind != SymbolKind::Genvar && sym.kind != SymbolKind::Specparam)
                ok = false;
        });
        return ok;
    }
    static std::optional<int64_t> toInt(const std::optional<SVInt>& v) {
        if (!v || v->hasUnknown())
            return std::nullopt;
        return v->as<int64_t>();
    }

    std::string leaf(Expr& out, const std::string& name, SourceRange r) {
        for (size_t k = 0; k < out.leaves.size(); k++) {
            if (out.leaves[k] == name) {
                out.leafLocs[k].push_back(loc(r));
                return "_L" + std::to_string(k) + "_";
            }
        }
        out.leaves.push_back(name);
        out.leafLocs.push_back({loc(r)});
        return "_L" + std::to_string(out.leaves.size() - 1) + "_";
    }
    std::string opaque(Expr& out, const Expression& e, std::string why) {
        Opaque o;
        o.src = text(e);
        o.kind = std::string(toString(e.kind));
        o.why = std::move(why);
        o.loc = loc(e.sourceRange);
        out.opaque.push_back(std::move(o));
        auto w = e.type ? e.type->getBitWidth() : 0;
        // An opaque operand of known width keeps the expression's widths right.
        return "_O" + std::to_string(out.opaque.size() - 1) + "_";
    }

    std::unique_ptr<Expr> lower(const Expression& e) {
        auto out = std::make_unique<Expr>();
        out->text = lowerInto(e, *out);
        out->src = text(e);
        out->loc = loc(e.sourceRange);
        if (e.type) {
            out->width = e.type->getBitWidth();
            out->isSigned = e.type->isSigned();
        }
        return out;
    }

    // The bit window an lvalue-like select chain names (a leaf, an element, a member, a select).
    Window window(const Expression& e, Expr& out) {
        Window win;
        switch (e.kind) {
            case ExpressionKind::NamedValue: {
                auto& sym = e.as<NamedValueExpression>().symbol;
                if (sym.kind == SymbolKind::Parameter || sym.kind == SymbolKind::EnumValue)
                    return win;
                win.tok = leaf(out, relName(sym), e.sourceRange);
                break;
            }
            case ExpressionKind::HierarchicalValue: {
                auto& sym = throughModport(e.as<HierarchicalValueExpression>().symbol);
                win.tok = leaf(out, "$abs:" + sym.getHierarchicalPath(), e.sourceRange);
                break;
            }
            case ExpressionKind::ElementSelect: {
                auto& es = e.as<ElementSelectExpression>();
                auto& vt = es.value().type->getCanonicalType();
                if (vt.isUnpackedArray()) {
                    // An unpacked element: its own leaf (the dump names it arr[k]).
                    if (es.value().kind != ExpressionKind::NamedValue &&
                        es.value().kind != ExpressionKind::HierarchicalValue)
                        return win;
                    auto& vsym = es.value().kind == ExpressionKind::NamedValue
                                     ? es.value().as<NamedValueExpression>().symbol
                                     : throughModport(es.value().as<HierarchicalValueExpression>().symbol);
                    Elem el;
                    el.array = es.value().kind == ExpressionKind::NamedValue
                                   ? relName(vsym)
                                   : "$abs:" + vsym.getHierarchicalPath();
                    el.index = lower(es.selector());
                    auto r = vt.getFixedRange();
                    el.lo = r.lower();
                    el.hi = r.upper();
                    el.width = e.type->getBitWidth();
                    out.elems.push_back(std::move(el));
                    win.tok = "_E" + std::to_string(out.elems.size() - 1) + "_";
                    win.tokWidth = e.type->getBitWidth();
                    win.constOff = 0;
                    win.width = win.tokWidth;
                    win.ok = true;
                    return win;
                }
                auto base = window(es.value(), out);
                if (!base.ok)
                    return win;
                auto [range, ew] = packedRange(vt);
                if (ew <= 0)
                    return win;
                if (auto k = toInt(constantInt(es.selector()))) {
                    return shifted(base, offsetOf(range, *k) * ew, ew);
                }
                auto idx = lowerInto(es.selector(), out);
                return shiftedVar(base, scaledIndex(range, idx, ew), ew);
            }
            case ExpressionKind::RangeSelect: {
                auto& rs = e.as<RangeSelectExpression>();
                auto& vt = rs.value().type->getCanonicalType();
                if (vt.isUnpackedArray())
                    return win;
                auto base = window(rs.value(), out);
                if (!base.ok)
                    return win;
                auto [range, ew] = packedRange(vt);
                if (ew <= 0)
                    return win;
                auto width = int64_t(e.type->getBitWidth());
                if (rs.getSelectionKind() == RangeSelectionKind::Simple) {
                    auto l = toInt(constantInt(rs.left()));
                    auto r = toInt(constantInt(rs.right()));
                    if (!l || !r)
                        return win;
                    // The element nearer bit 0: the lower index of a descending range, else the higher.
                    auto lsbIndex = range.isDescending() ? std::min(*l, *r) : std::max(*l, *r);
                    return shifted(base, offsetOf(range, lsbIndex) * ew, width);
                }
                auto count = toInt(constantInt(rs.right()));
                if (!count)
                    return win;
                bool up = rs.getSelectionKind() == RangeSelectionKind::IndexedUp;
                // The lsb-side index: b (up, descending), b+n-1 (up, ascending), b-n+1 (down,
                // descending), b (down, ascending).
                int64_t adjust = 0;
                if (up && !range.isDescending())
                    adjust = *count - 1;
                if (!up && range.isDescending())
                    adjust = -(*count - 1);
                if (auto b = toInt(constantInt(rs.left())))
                    return shifted(base, offsetOf(range, *b + adjust) * ew, width);
                auto bt = lowerInto(rs.left(), out);
                if (adjust)
                    bt = "(" + bt + (adjust > 0 ? " + " : " - ") + std::to_string(std::llabs(adjust)) + ")";
                return shiftedVar(base, scaledIndex(range, bt, ew), width);
            }
            case ExpressionKind::MemberAccess: {
                auto& ma = e.as<MemberAccessExpression>();
                auto& vt = ma.value().type->getCanonicalType();
                if (!vt.isIntegral())
                    return win;
                auto base = window(ma.value(), out);
                if (!base.ok)
                    return win;
                if (ma.member.kind != SymbolKind::Field)
                    return win;
                auto& f = ma.member.as<FieldSymbol>();
                int64_t off = vt.isPackedUnion() ? 0 : int64_t(f.bitOffset);
                return shifted(base, off, int64_t(f.getType().getBitWidth()));
            }
            default: return win;
        }
        win.tokWidth = e.type ? int64_t(e.type->getBitWidth()) : 0;
        win.constOff = 0;
        win.width = win.tokWidth;
        win.ok = win.tokWidth > 0;
        return win;
    }

    // The outermost packed dimension of a type and its element width (bits per index).
    static std::pair<ConstantRange, int64_t> packedRange(const Type& t) {
        auto& ct = t.getCanonicalType();
        if (ct.kind == SymbolKind::PackedArrayType) {
            auto& pa = ct.as<PackedArrayType>();
            return {pa.range, int64_t(pa.elementType.getBitWidth())};
        }
        if (ct.isIntegral()) {
            auto w = int64_t(ct.getBitWidth());
            return {ConstantRange(int32_t(w - 1), 0), 1};
        }
        return {ConstantRange(0, 0), 0};
    }
    // The 0-based element offset of index k in a range: k - right (descending), right - k (ascending).
    static int64_t offsetOf(ConstantRange r, int64_t k) {
        return r.isDescending() ? k - r.right : r.right - k;
    }
    static std::string scaledIndex(ConstantRange r, const std::string& idx, int64_t ew) {
        std::string off;
        if (r.isDescending())
            off = r.right == 0 ? idx : "(" + idx + " - " + std::to_string(r.right) + ")";
        else
            off = "(" + std::to_string(r.right) + " - " + idx + ")";
        return ew == 1 ? off : "(" + off + " * " + std::to_string(ew) + ")";
    }
    static Window shifted(Window base, int64_t off, int64_t width) {
        if (base.constOff)
            base.constOff = *base.constOff + off;
        else
            base.offText = "(" + base.offText + " + " + std::to_string(off) + ")";
        base.width = width;
        return base;
    }
    static Window shiftedVar(Window base, const std::string& off, int64_t width) {
        if (base.constOff)
            base.offText = *base.constOff == 0 ? off : "(" + off + " + " + std::to_string(*base.constOff) + ")";
        else
            base.offText = "(" + base.offText + " + " + off + ")";
        base.constOff.reset();
        base.width = width;
        return base;
    }
    static std::string windowText(const Window& w) {
        if (w.constOff) {
            if (*w.constOff == 0 && w.width == w.tokWidth)
                return w.tok;
            return w.tok + "[" + std::to_string(*w.constOff + w.width - 1) + ":" + std::to_string(*w.constOff) + "]";
        }
        return w.tok + "[" + w.offText + " +: " + std::to_string(w.width) + "]";
    }

    std::string lowerInto(const Expression& e, Expr& out) {
        auto k = e.kind;
        // Parameters, genvars and folded constants as sized literals.
        if (k != ExpressionKind::Assignment && e.type && e.type->isIntegral()) {
            if (auto cv = e.getConstant(); cv && cv->isInteger())
                return sizedBits(cv->integer());
            if (k == ExpressionKind::NamedValue) {
                auto& sym = e.as<NamedValueExpression>().symbol;
                if (sym.kind == SymbolKind::Parameter || sym.kind == SymbolKind::EnumValue ||
                    sym.kind == SymbolKind::Genvar) {
                    if (auto v = constantInt(e))
                        return sizedBits(*v);
                }
            }
        }
        switch (k) {
            case ExpressionKind::IntegerLiteral: return sizedBits(e.as<IntegerLiteral>().getValue());
            case ExpressionKind::UnbasedUnsizedIntegerLiteral: {
                auto v = e.as<UnbasedUnsizedIntegerLiteral>().getLiteralValue();
                char c = v.isUnknown() ? (v.value == logic_t::Z_VALUE ? 'z' : 'x') : (v.value ? '1' : '0');
                return std::string("'") + c;
            }
            case ExpressionKind::NamedValue:
            case ExpressionKind::HierarchicalValue:
            case ExpressionKind::ElementSelect:
            case ExpressionKind::RangeSelect:
            case ExpressionKind::MemberAccess: {
                auto w = window(e, out);
                if (!w.ok)
                    return opaque(out, e, "select");
                return windowText(w);
            }
            case ExpressionKind::Conversion: {
                auto& c = e.as<ConversionExpression>();
                auto inner = lowerInto(c.operand(), out);
                if (c.isImplicit() || !e.type || !e.type->isIntegral() || !c.operand().type ||
                    !c.operand().type->isIntegral())
                    return inner;
                // A cast to a width: keep that many bits (zero- or sign-extended by the context).
                auto w = e.type->getBitWidth();
                auto from = c.operand().type->getBitWidth();
                if (w == from && e.type->isSigned() == c.operand().type->isSigned())
                    return inner;
                if (e.type->isSigned() != c.operand().type->isSigned())
                    return opaque(out, e, "signedCast");
                if (w < from)
                    return "{" + inner + "}[" + std::to_string(w - 1) + ":0]";
                return "{" + std::to_string(w - from) + "'b0, " + inner + "}";
            }
            case ExpressionKind::UnaryOp: {
                auto& u = e.as<UnaryExpression>();
                const char* op = nullptr;
                switch (u.op) {
                    case UnaryOperator::Plus: op = "+"; break;
                    case UnaryOperator::Minus: op = "-"; break;
                    case UnaryOperator::BitwiseNot: op = "~"; break;
                    case UnaryOperator::BitwiseAnd: op = "&"; break;
                    case UnaryOperator::BitwiseOr: op = "|"; break;
                    case UnaryOperator::BitwiseXor: op = "^"; break;
                    case UnaryOperator::BitwiseNand: op = "~&"; break;
                    case UnaryOperator::BitwiseNor: op = "~|"; break;
                    case UnaryOperator::BitwiseXnor: op = "~^"; break;
                    case UnaryOperator::LogicalNot: op = "!"; break;
                    default: break;
                }
                if (!op)
                    return opaque(out, e, "operator");
                return std::string("(") + op + lowerInto(u.operand(), out) + ")";
            }
            case ExpressionKind::BinaryOp: {
                auto& b = e.as<BinaryExpression>();
                const char* op = nullptr;
                switch (b.op) {
                    case BinaryOperator::Add: op = "+"; break;
                    case BinaryOperator::Subtract: op = "-"; break;
                    case BinaryOperator::Multiply: op = "*"; break;
                    case BinaryOperator::BinaryAnd: op = "&"; break;
                    case BinaryOperator::BinaryOr: op = "|"; break;
                    case BinaryOperator::BinaryXor: op = "^"; break;
                    case BinaryOperator::BinaryXnor: op = "~^"; break;
                    case BinaryOperator::Equality: op = "=="; break;
                    case BinaryOperator::Inequality: op = "!="; break;
                    case BinaryOperator::CaseEquality: op = "==="; break;
                    case BinaryOperator::CaseInequality: op = "!=="; break;
                    case BinaryOperator::GreaterThanEqual: op = ">="; break;
                    case BinaryOperator::GreaterThan: op = ">"; break;
                    case BinaryOperator::LessThanEqual: op = "<="; break;
                    case BinaryOperator::LessThan: op = "<"; break;
                    case BinaryOperator::LogicalAnd: op = "&&"; break;
                    case BinaryOperator::LogicalOr: op = "||"; break;
                    case BinaryOperator::LogicalShiftLeft: op = "<<"; break;
                    case BinaryOperator::LogicalShiftRight: op = ">>"; break;
                    case BinaryOperator::ArithmeticShiftLeft: op = "<<<"; break;
                    case BinaryOperator::ArithmeticShiftRight: op = ">>>"; break;
                    default: break;
                }
                if (!op)
                    return opaque(out, e, "operator");
                auto l = lowerInto(b.left(), out);
                auto r = lowerInto(b.right(), out);
                return "(" + l + " " + op + " " + r + ")";
            }
            case ExpressionKind::ConditionalOp: {
                auto& c = e.as<ConditionalExpression>();
                if (c.conditions.size() != 1 || c.conditions[0].pattern)
                    return opaque(out, e, "pattern");
                auto cc = lowerInto(*c.conditions[0].expr, out);
                auto l = lowerInto(c.left(), out);
                auto r = lowerInto(c.right(), out);
                return "(" + cc + " ? " + l + " : " + r + ")";
            }
            case ExpressionKind::Concatenation: {
                auto& c = e.as<ConcatenationExpression>();
                std::string s = "{";
                bool first = true;
                for (auto op : c.operands()) {
                    // A zero-width replication {0{x}} contributes nothing.
                    if (op->type && op->type->getBitWidth() == 0)
                        continue;
                    if (!first)
                        s += ", ";
                    first = false;
                    s += lowerInto(*op, out);
                }
                return first ? opaque(out, e, "empty") : s + "}";
            }
            case ExpressionKind::Replication: {
                auto& r = e.as<ReplicationExpression>();
                auto n = toInt(constantInt(r.count()));
                if (!n || *n <= 0)
                    return opaque(out, e, "replication");
                return "{" + std::to_string(*n) + "{" + lowerInto(r.concat(), out) + "}}";
            }
            case ExpressionKind::SimpleAssignmentPattern:
            case ExpressionKind::StructuredAssignmentPattern: {
                if (!e.type || !e.type->isIntegral())
                    return opaque(out, e, "pattern");
                auto& p = static_cast<const AssignmentPatternExpressionBase&>(e);
                std::string s = "{";
                bool first = true;
                for (auto el : p.elements()) {
                    if (!first)
                        s += ", ";
                    first = false;
                    s += lowerInto(*el, out);
                }
                return first ? opaque(out, e, "pattern") : s + "}";
            }
            case ExpressionKind::Call: return opaque(out, e, "call");
            default: return opaque(out, e, "expression");
        }
    }

    void writeExpr(JsonWriter& w, const Expr& x) const {
        w.startObject();
        w.writeProperty("text");
        w.writeValue(x.text);
        w.writeProperty("leaves");
        w.startArray();
        for (auto& l : x.leaves)
            w.writeValue(l);
        w.endArray();
        w.writeProperty("leafLocs");
        w.startArray();
        for (auto& ls : x.leafLocs) {
            w.startArray();
            for (auto& l : ls) {
                if (l.valid)
                    writeLoc(w, l);
            }
            w.endArray();
        }
        w.endArray();
        if (!x.elems.empty()) {
            w.writeProperty("elems");
            w.startArray();
            for (auto& el : x.elems) {
                w.startObject();
                w.writeProperty("array");
                w.writeValue(el.array);
                w.writeProperty("index");
                writeExpr(w, *el.index);
                w.writeProperty("width");
                w.writeValue(el.width);
                w.writeProperty("lo");
                w.writeValue(el.lo);
                w.writeProperty("hi");
                w.writeValue(el.hi);
                w.endObject();
            }
            w.endArray();
        }
        if (!x.opaque.empty()) {
            w.writeProperty("opaque");
            w.startArray();
            for (auto& o : x.opaque) {
                w.startObject();
                w.writeProperty("src");
                w.writeValue(o.src);
                w.writeProperty("kind");
                w.writeValue(o.kind);
                w.writeProperty("why");
                w.writeValue(o.why);
                if (o.loc.valid) {
                    w.writeProperty("loc");
                    writeLoc(w, o.loc);
                }
                w.endObject();
            }
            w.endArray();
        }
        w.writeProperty("width");
        w.writeValue(x.width);
        if (x.isSigned) {
            w.writeProperty("signed");
            w.writeValue(true);
        }
        w.writeProperty("src");
        w.writeValue(x.src);
        if (x.loc.valid) {
            w.writeProperty("loc");
            writeLoc(w, x.loc);
        }
        w.endObject();
    }
    void writeExpr(JsonWriter& w, const Expression& e) { writeExpr(w, *lower(e)); }

    // ---- lvalues ----
    // {name, lsb?, msb?} (a constant window), {name, off: Expr, width} (a variable one),
    // {name, elem: Expr, ...} (an unpacked element), {concat: [lval...]}, or {opaque}.
    void writeLval(JsonWriter& w, const Expression& e) {
        if (e.kind == ExpressionKind::Concatenation) {
            w.startObject();
            w.writeProperty("concat");
            w.startArray();
            for (auto op : e.as<ConcatenationExpression>().operands())
                writeLval(w, *op);
            w.endArray();
            w.writeProperty("width");
            w.writeValue(int64_t(e.type->getBitWidth()));
            w.endObject();
            return;
        }
        Expr scratch;
        auto win = window(e, scratch);
        w.startObject();
        if (!win.ok || scratch.opaque.size()) {
            w.writeProperty("opaque");
            w.writeValue(text(e));
            // The variable under it, so the write is still found as one to that variable.
            if (auto sym = WriteFinder::base(&e)) {
                auto n = relName(throughModport(*sym));
                if (n.rfind("$local:", 0) != 0) {
                    w.writeProperty("name");
                    w.writeValue(n);
                }
            }
            w.writeProperty("width");
            w.writeValue(int64_t(e.type ? e.type->getBitWidth() : 0));
            w.endObject();
            return;
        }
        // The window's root: a leaf (its name) or an element (the array and the index).
        if (win.tok.rfind("_E", 0) == 0) {
            auto& el = scratch.elems.back();
            w.writeProperty("name");
            w.writeValue(el.array);
            w.writeProperty("elem");
            writeExpr(w, *el.index);
            w.writeProperty("elemWidth");
            w.writeValue(el.width);
        }
        else {
            w.writeProperty("name");
            w.writeValue(scratch.leaves.front());
        }
        w.writeProperty("width");
        w.writeValue(win.width);
        w.writeProperty("full");
        w.writeValue(win.tokWidth);
        if (win.constOff) {
            if (!(*win.constOff == 0 && win.width == win.tokWidth)) {
                w.writeProperty("lsb");
                w.writeValue(*win.constOff);
                w.writeProperty("msb");
                w.writeValue(*win.constOff + win.width - 1);
            }
        }
        else {
            // The offset's text reads leaves of the same scratch Expr: emit it as one.
            Expr off;
            off.text = win.offText;
            off.leaves = scratch.leaves;
            off.leafLocs = scratch.leafLocs;
            for (auto& el : scratch.elems) {
                Elem copy;
                copy.array = el.array;
                copy.index = std::make_unique<Expr>();
                copy.index->text = el.index->text;
                copy.index->leaves = el.index->leaves;
                copy.index->leafLocs = el.index->leafLocs;
                copy.index->width = el.index->width;
                copy.width = el.width;
                copy.lo = el.lo;
                copy.hi = el.hi;
                off.elems.push_back(std::move(copy));
            }
            off.width = 32;
            off.src = text(e);
            w.writeProperty("off");
            writeExpr(w, off);
        }
        auto l = loc(e.sourceRange);
        if (l.valid) {
            w.writeProperty("loc");
            writeLoc(w, l);
        }
        w.endObject();
    }

    // ---- members ----
    void writeSignal(JsonWriter& w, const ValueSymbol& v) {
        auto& t = v.getType();
        w.writeProperty(relName(v));
        w.startObject();
        w.writeProperty("width");
        w.writeValue(int64_t(t.getBitWidth()));
        w.writeProperty("kind");
        w.writeValue(v.kind == SymbolKind::Net ? std::string_view("net") : std::string_view("var"));
        if (t.isSigned()) {
            w.writeProperty("signed");
            w.writeValue(true);
        }
        // A 2-state type (bit, int, byte...) starts at 0; a 4-state one at x (cmux-trace.js startValue).
        if (!t.isFourState()) {
            w.writeProperty("twoState");
            w.writeValue(true);
        }
        auto& ct = t.getCanonicalType();
        if (ct.isUnpackedArray() && ct.hasFixedRange()) {
            auto r = ct.getFixedRange();
            auto el = ct.getArrayElementType();
            w.writeProperty("array");
            w.startObject();
            w.writeProperty("lo");
            w.writeValue(int64_t(r.lower()));
            w.writeProperty("hi");
            w.writeValue(int64_t(r.upper()));
            w.writeProperty("elemWidth");
            w.writeValue(int64_t(el ? el->getBitWidth() : 0));
            w.endObject();
        }
        else if (ct.isIntegral()) {
            // The declared range (for the dump's names and for display).
            auto [range, ew] = packedRange(ct);
            if (ew == 1 || ct.kind == SymbolKind::PackedArrayType) {
                w.writeProperty("msb");
                w.writeValue(int64_t(range.left));
                w.writeProperty("lsb");
                w.writeValue(int64_t(range.right));
            }
            if (ct.isEnum()) {
                w.writeProperty("enum");
                w.writeValue(true);
            }
        }
        if (auto init = v.getInitializer()) {
            w.writeProperty("init");
            writeExpr(w, *init);
        }
        writeLocProp(w, "loc", v.location, v.name.size());
        w.endObject();
    }

    void writeAssign(JsonWriter& w, const ContinuousAssignSymbol& ca) {
        auto& a = ca.getAssignment();
        w.startObject();
        if (a.kind != ExpressionKind::Assignment) {
            w.writeProperty("opaque");
            w.writeValue(text(a));
        }
        else {
            auto& as = a.as<AssignmentExpression>();
            w.writeProperty("lhs");
            writeLval(w, as.left());
            w.writeProperty("rhs");
            writeExpr(w, as.right());
            // `assign #d y = ...` keeps its delay on the symbol, not on the assignment.
            if (as.timingControl || ca.getDelay()) {
                w.writeProperty("delay");
                w.writeValue(true);
            }
        }
        w.writeProperty("src");
        w.writeValue(ca.getSyntax() ? trim(ca.getSyntax()->toString()) : text(a));
        writeLocProp(w, "loc", ca.getSyntax() ? ca.getSyntax()->sourceRange() : a.sourceRange);
        w.endObject();
    }

    void writeEvents(JsonWriter& w, const TimingControl& tc) {
        switch (tc.kind) {
            case TimingControlKind::EventList:
                for (auto ev : tc.as<EventListControl>().events)
                    writeEvents(w, *ev);
                break;
            case TimingControlKind::SignalEvent: {
                auto& se = tc.as<SignalEventControl>();
                w.startObject();
                w.writeProperty("edge");
                w.writeValue(toString(se.edge));
                w.writeProperty("expr");
                writeExpr(w, se.expr);
                if (se.iffCondition) {
                    w.writeProperty("iff");
                    writeExpr(w, *se.iffCondition);
                }
                w.endObject();
                break;
            }
            default:
                w.startObject();
                w.writeProperty("edge");
                w.writeValue(std::string_view("Other"));
                w.writeProperty("kind");
                w.writeValue(toString(tc.kind));
                w.endObject();
                break;
        }
    }

    void writeProc(JsonWriter& w, const ProceduralBlockSymbol& p, int id) {
        auto& body = p.getBody();
        w.startObject();
        w.writeProperty("id");
        w.writeValue(int64_t(id));
        w.writeProperty("kind");
        w.writeValue(toString(p.procedureKind));
        w.writeProperty("events");
        w.startArray();
        const Statement* inner = &body;
        if (body.kind == StatementKind::Timed) {
            writeEvents(w, body.as<TimedStatement>().timing);
            inner = &body.as<TimedStatement>().stmt;
        }
        w.endArray();
        w.writeProperty("body");
        writeStmt(w, *inner);
        writeLocProp(w, "loc", p.getSyntax() ? p.getSyntax()->sourceRange() : body.sourceRange);
        w.endObject();
    }

    // "writes": [{name, at?: [{src, loc}...]}...], the variables `f` finds written (procedural locals
    // left out), if any, with where each is written (an opaque statement's own lines).
    void writeWrites(JsonWriter& w, const WriteFinder& f) {
        std::vector<std::string> names;
        std::vector<std::vector<const Expression*>> at;
        for (size_t i = 0; i < f.out.size(); i++) {
            auto n = writtenName(throughModport(*f.out[i]));
            if (n.rfind("$local:", 0) == 0)
                continue;
            auto k = std::find(names.begin(), names.end(), n);
            if (k == names.end()) {
                names.push_back(n);
                at.emplace_back();
                k = names.end() - 1;
            }
            auto& here = at[size_t(k - names.begin())];
            for (auto e : f.sites[i])
                if (here.size() < 8)
                    here.push_back(e);
        }
        if (names.empty())
            return;
        w.writeProperty("writes");
        w.startArray();
        for (size_t i = 0; i < names.size(); i++) {
            w.startObject();
            w.writeProperty("name");
            w.writeValue(names[i]);
            bool any = false;
            for (auto e : at[i]) {
                if (!loc(e->sourceRange).valid)
                    continue;
                if (!any) {
                    w.writeProperty("at");
                    w.startArray();
                    any = true;
                }
                w.startObject();
                auto src = ownText(*e);
                if (src.size() > 160)
                    src = src.substr(0, 157) + "...";
                // (none for a write slang made up, such as a $value$plusargs output argument)
                if (!src.empty()) {
                    w.writeProperty("src");
                    w.writeValue(src);
                }
                writeLocProp(w, "loc", e->sourceRange);
                w.endObject();
            }
            if (any)
                w.endArray();
            w.endObject();
        }
        w.endArray();
    }

    void writeStmt(JsonWriter& w, const Statement& s) {
        w.startObject();
        // Opaque statements (not re-executed) and conditions with side effects say what they
        // write, so the driver search still finds them.
        bool opq = false;
        switch (s.kind) {
            case StatementKind::Block: {
                auto& b = s.as<BlockStatement>();
                if (b.blockKind != StatementBlockKind::Sequential) {
                    w.writeProperty("k");
                    w.writeValue(std::string_view("opaque"));
                    opq = true;
                    w.writeProperty("why");
                    w.writeValue(std::string_view("fork"));
                    break;
                }
                w.writeProperty("k");
                w.writeValue(std::string_view("seq"));
                w.writeProperty("s");
                w.startArray();
                writeStmt(w, b.body);
                w.endArray();
                break;
            }
            case StatementKind::List: {
                w.writeProperty("k");
                w.writeValue(std::string_view("seq"));
                w.writeProperty("s");
                w.startArray();
                for (auto x : s.as<StatementList>().list)
                    writeStmt(w, *x);
                w.endArray();
                break;
            }
            case StatementKind::Empty:
                w.writeProperty("k");
                w.writeValue(std::string_view("seq"));
                w.writeProperty("s");
                w.startArray();
                w.endArray();
                break;
            case StatementKind::VariableDeclaration: {
                auto& v = s.as<VariableDeclStatement>().symbol;
                w.writeProperty("k");
                w.writeValue(std::string_view("decl"));
                w.writeProperty("name");
                w.writeValue(relName(v));
                w.writeProperty("width");
                w.writeValue(int64_t(v.getType().getBitWidth()));
                if (auto init = v.getInitializer()) {
                    w.writeProperty("init");
                    writeExpr(w, *init);
                }
                break;
            }
            case StatementKind::Timed: {
                // A delay or event inside a procedure: the statement runs, its timing is not modelled.
                w.writeProperty("k");
                w.writeValue(std::string_view("timed"));
                w.writeProperty("stmt");
                writeStmt(w, s.as<TimedStatement>().stmt);
                break;
            }
            case StatementKind::ExpressionStatement: {
                auto& e = s.as<ExpressionStatement>().expr;
                if (e.kind == ExpressionKind::Assignment) {
                    auto& a = e.as<AssignmentExpression>();
                    if (a.isCompound() || a.timingControl) {
                        w.writeProperty("k");
                        w.writeValue(std::string_view("opaque"));
                        opq = true;
                        w.writeProperty("why");
                        w.writeValue(a.timingControl ? std::string_view("intraDelay") : std::string_view("compound"));
                        break;
                    }
                    w.writeProperty("k");
                    w.writeValue(std::string_view("asgn"));
                    w.writeProperty("lhs");
                    writeLval(w, a.left());
                    w.writeProperty("rhs");
                    writeExpr(w, a.right());
                    w.writeProperty("nb");
                    w.writeValue(a.isNonBlocking());
                }
                else {
                    w.writeProperty("k");
                    w.writeValue(std::string_view("opaque"));
                    opq = true;
                    w.writeProperty("why");
                    w.writeValue(e.kind == ExpressionKind::Call ? std::string_view("call") : std::string_view("expression"));
                }
                break;
            }
            case StatementKind::Conditional: {
                auto& c = s.as<ConditionalStatement>();
                if (c.conditions.size() != 1 || c.conditions[0].pattern) {
                    w.writeProperty("k");
                    w.writeValue(std::string_view("opaque"));
                    opq = true;
                    w.writeProperty("why");
                    w.writeValue(std::string_view("pattern"));
                    break;
                }
                w.writeProperty("k");
                w.writeValue(std::string_view("if"));
                w.writeProperty("c");
                writeExpr(w, *c.conditions[0].expr);
                w.writeProperty("check");
                w.writeValue(toString(c.check));
                w.writeProperty("t");
                writeStmt(w, c.ifTrue);
                if (c.ifFalse) {
                    w.writeProperty("f");
                    writeStmt(w, *c.ifFalse);
                }
                break;
            }
            case StatementKind::Case: {
                auto& c = s.as<CaseStatement>();
                w.writeProperty("k");
                w.writeValue(std::string_view("case"));
                w.writeProperty("e");
                writeExpr(w, c.expr);
                w.writeProperty("cond");
                w.writeValue(toString(c.condition));
                w.writeProperty("check");
                w.writeValue(toString(c.check));
                w.writeProperty("items");
                w.startArray();
                for (auto& it : c.items) {
                    w.startObject();
                    w.writeProperty("m");
                    w.startArray();
                    for (auto m : it.expressions)
                        writeExpr(w, *m);
                    w.endArray();
                    w.writeProperty("s");
                    writeStmt(w, *it.stmt);
                    w.endObject();
                }
                w.endArray();
                if (c.defaultCase) {
                    w.writeProperty("dflt");
                    writeStmt(w, *c.defaultCase);
                }
                break;
            }
            default:
                w.writeProperty("k");
                w.writeValue(std::string_view("opaque"));
                opq = true;
                w.writeProperty("why");
                w.writeValue(toString(s.kind));
                break;
        }
        {
            WriteFinder f;
            if (opq)
                s.visit(f);
            else if (s.kind == StatementKind::Conditional) {
                for (auto& c : s.as<ConditionalStatement>().conditions)
                    c.expr->visit(f);
            }
            else if (s.kind == StatementKind::Case) {
                auto& c = s.as<CaseStatement>();
                c.expr.visit(f);
                for (auto& it : c.items)
                    for (auto m : it.expressions)
                        m->visit(f);
            }
            else if (s.kind == StatementKind::ExpressionStatement &&
                     s.as<ExpressionStatement>().expr.kind == ExpressionKind::Assignment) {
                // An assignment's right side: what the functions it calls write.
                s.as<ExpressionStatement>().expr.as<AssignmentExpression>().right().visit(f);
            }
            writeWrites(w, f);
        }
        w.writeProperty("src");
        auto src = text(s);
        // A block's text is its whole body: the first line is enough to name it.
        if (src.size() > 160)
            src = src.substr(0, 157) + "...";
        w.writeValue(src);
        writeLocProp(w, "loc", s.sourceRange);
        w.endObject();
    }

    void writePorts(JsonWriter& w, const InstanceSymbol& inst, const InstanceSymbol* parent) {
        w.startArray();
        auto saved = cur;
        auto savedPath = curPath;
        for (auto p : inst.body.getPortList()) {
            if (p->kind != SymbolKind::Port)
                continue;
            auto& port = p->as<PortSymbol>();
            w.startObject();
            w.writeProperty("name");
            w.writeValue(port.name);
            w.writeProperty("dir");
            w.writeValue(toString(port.direction));
            if (port.internalSymbol) {
                // The internal side, relative to the port's own instance.
                cur = &inst;
                curPath = inst.getHierarchicalPath();
                w.writeProperty("internal");
                w.writeValue(relName(*port.internalSymbol));
            }
            w.writeProperty("width");
            w.writeValue(int64_t(port.getType().getBitWidth()));
            auto conn = inst.getPortConnection(port);
            auto ce = conn ? conn->getExpression() : nullptr;
            if (ce && parent) {
                // The connection, relative to the instance it is written in.
                cur = parent;
                curPath = parent->getHierarchicalPath();
                if (ce->kind == ExpressionKind::Assignment) {
                    auto& a = ce->as<AssignmentExpression>();
                    w.writeProperty("connLval");
                    writeLval(w, a.left());
                    w.writeProperty("conn");
                    writeExpr(w, a.left());
                }
                else {
                    w.writeProperty("conn");
                    writeExpr(w, *ce);
                    if (port.direction == ArgumentDirection::InOut || port.direction == ArgumentDirection::Ref) {
                        w.writeProperty("connLval");
                        writeLval(w, *ce);
                    }
                }
                writeLocProp(w, "loc", ce->sourceRange);
            }
            else {
                writeLocProp(w, "loc", port.location, port.name.size());
            }
            w.endObject();
        }
        cur = saved;
        curPath = savedPath;
        w.endArray();
    }
};

// ---------------------------------------------------------------------------------------------
// The session: one design loaded at a time.
// A file a load read, as it was on disk after the load read it (size -1: missing; -2: written
// while the load read it, so never taken as unchanged).
struct SourceStamp {
    std::string path;
    int64_t size = -1;
    int64_t mtime = 0;
    bool operator==(const SourceStamp&) const = default;
};

SourceStamp stampOf(const std::string& path) {
    SourceStamp st{path};
    std::error_code ec;
    auto size = std::filesystem::file_size(path, ec);
    if (ec)
        return st;
    auto t = std::filesystem::last_write_time(path, ec);
    if (ec)
        return st;
    st.size = int64_t(size);
    st.mtime = int64_t(t.time_since_epoch().count());
    return st;
}

// FNV-1a (64 bits) over length-delimited parts: tells designs apart, not a security hash.
struct Fingerprint {
    uint64_t h = 1469598103934665603ull;
    void add(std::string_view text) {
        auto mix = [this](unsigned char c) {
            h ^= c;
            h *= 1099511628211ull;
        };
        for (unsigned char c : text)
            mix(c);
        for (int i = 0; i < 8; i++)
            mix((unsigned char)(text.size() >> (8 * i)));
    }
    std::string hex() const {
        char out[17];
        std::snprintf(out, sizeof out, "%016llx", (unsigned long long)h);
        return out;
    }
};

struct Session {
    std::unique_ptr<driver::Driver> drv;
    std::unique_ptr<Compilation> comp;
    std::unique_ptr<Model> model;
    // writers: instance path -> the other instances that write into it (built on first use).
    std::optional<std::map<std::string, std::vector<std::string>>> writers;
    // The files the last load read, and its fingerprint (empty: nothing loaded).
    std::vector<SourceStamp> stamps;
    std::string fingerprint;
};

// The files the load read (every file buffer, and every command file) stamped, and the
// fingerprint over the command line, the folder and their text. A file whose size is not the
// text's, or whose time is from while the load read it (between `start` and now: a host clock
// behind a file server's makes times later than now, which say nothing), is stamped as never
// matching. Not seen: a file a load could not find that is made later, and on a file server
// whose clock is behind, an edit of the same size while the load read it.
void stampSources(Session& s, const std::vector<std::string>& args, const std::string& cwd,
                  std::filesystem::file_time_type start) {
    auto end = std::filesystem::file_time_type::clock::now();
    auto& sm = s.drv->sourceManager;
    std::map<std::string, std::string> files;
    for (auto buffer : sm.getAllBuffers()) {
        auto& path = sm.getFullPath(buffer);
        if (!path.empty())
            files.emplace(path.string(), std::string(sm.getSourceText(buffer)));
    }
    std::map<std::string, std::string> commandFiles;
    for (auto& [path, _] : s.drv->getCommandFileMetadata()) {
        std::ifstream in(path, std::ios::binary);
        std::ostringstream text;
        text << in.rdbuf();
        commandFiles.emplace(path.string(), text.str());
    }
    Fingerprint fp;
    fp.add("args");
    for (size_t i = 1; i < args.size(); i++)
        fp.add(args[i]);
    fp.add("cwd");
    fp.add(cwd);
    for (auto* group : {&files, &commandFiles}) {
        fp.add(group == &files ? "files" : "commandFiles");
        for (auto& [path, text] : *group) {
            fp.add(path);
            fp.add(text);
            auto st = stampOf(path);
            size_t length = text.size();
            if (length > 0 && text.back() == '\0')
                length--;
            bool during = st.mtime >= int64_t(start.time_since_epoch().count()) &&
                          st.mtime <= int64_t(end.time_since_epoch().count());
            if (st.size >= 0 && (size_t(st.size) != length || during))
                st.size = -2;
            s.stamps.push_back(st);
        }
    }
    s.fingerprint = fp.hex();
}

// The written ($abs: lvalue) paths in each instance's model, mapped to the instance they are in.
std::map<std::string, std::vector<std::string>> buildWriters(Model& model) {
    std::map<std::string, std::vector<std::string>> out;
    const std::string key = "\"name\":\"$abs:";
    for (auto& p : model.instancePaths()) {
        JsonWriter w;
        model.writeInstance(w, *model.instance(p));
        std::string_view text = w.view();
        for (size_t at = text.find(key); at != std::string_view::npos; at = text.find(key, at + 1)) {
            size_t start = at + key.size();
            size_t end = text.find('"', start);
            if (end == std::string_view::npos)
                break;
            auto target = model.lookup(std::string(text.substr(start, end - start)));
            if (!target || target->first == p)
                continue;
            auto& list = out[target->first];
            if (std::find(list.begin(), list.end(), p) == list.end())
                list.push_back(p);
        }
    }
    for (auto& [k, v] : out)
        std::sort(v.begin(), v.end());
    return out;
}

void reply(JsonWriter& w) {
    std::string line(w.view());
    line += '\n';
    fwrite(line.data(), 1, line.size(), stdout);
    fflush(stdout);
}

void fail(int64_t id, std::string_view code, std::string_view message) {
    JsonWriter w;
    w.startObject();
    w.writeProperty("id");
    w.writeValue(id);
    w.writeProperty("ok");
    w.writeValue(false);
    w.writeProperty("error");
    w.writeValue(code);
    w.writeProperty("message");
    w.writeValue(message);
    w.endObject();
    reply(w);
}

void load(Session& s, int64_t id, const JValue& req) {
    auto t0 = std::chrono::steady_clock::now();
    s.model.reset();
    s.writers.reset();
    s.comp.reset();
    s.stamps.clear();
    s.fingerprint.clear();
    auto start = std::filesystem::file_time_type::clock::now();
    s.drv = std::make_unique<driver::Driver>();
    auto& d = *s.drv;
    d.addStandardArgs();
    std::vector<std::string> args{"cmux-sv-model"};
    if (auto a = req.get("args"); a && a->kind == JValue::Array) {
        for (auto& x : a->a) {
            if (x.kind == JValue::String)
                args.push_back(x.s);
        }
    }
    auto cwd = req.str("cwd");
    std::error_code ec;
    auto oldCwd = std::filesystem::current_path(ec);
    if (!cwd.empty()) {
        std::filesystem::current_path(cwd, ec);
        if (ec) {
            fail(id, "badCwd", ec.message());
            return;
        }
    }
    std::vector<const char*> argv;
    for (auto& a : args)
        argv.push_back(a.c_str());
    // The driver prints its diagnostics to stderr; stdout is the protocol.
    d.diagEngine.setErrorLimit(50);
    bool ok = d.parseCommandLine(int(argv.size()), argv.data());
    // Each instance gets its own body: paths in the model are per instance.
    d.options.compilationFlags[CompilationFlags::DisableInstanceCaching] = true;
    ok = ok && d.processOptions() && d.parseAllSources();
    if (!ok) {
        std::filesystem::current_path(oldCwd, ec);
        fail(id, "badArgs", "the slang command line or its files could not be read");
        return;
    }
    s.comp = d.createCompilation();
    {
        std::set<std::string> names;
        for (auto& tree : d.syntaxTrees)
            systemNames(tree->root(), names);
        for (auto& n : names)
            if (!s.comp->getSystemSubroutine(n))
                s.comp->addSystemSubroutine(std::make_shared<UnknownSystemCall>(n));
    }
    auto& diags = s.comp->getAllDiagnostics();
    std::vector<std::string> messages;
    int64_t errors = 0;
    for (auto& diag : diags) {
        if (!diag.isError())
            continue;
        errors++;
        if (messages.size() < 20) {
            auto loc = diag.location;
            std::string where;
            if (loc.valid() && loc.buffer().valid()) {
                auto o = s.drv->sourceManager.getFullyOriginalLoc(loc);
                where = std::string(s.drv->sourceManager.getFileName(o)) + ":" +
                        std::to_string(s.drv->sourceManager.getLineNumber(o)) + ": ";
            }
            messages.push_back(where + std::string(toString(diag.code)));
        }
    }
    s.model = std::make_unique<Model>(*s.comp, s.drv->sourceManager);
    s.writers.reset();
    stampSources(s, args, cwd, start);
    std::filesystem::current_path(oldCwd, ec);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    JsonWriter w;
    w.startObject();
    w.writeProperty("id");
    w.writeValue(id);
    w.writeProperty("ok");
    w.writeValue(true);
    w.writeProperty("tops");
    w.startArray();
    for (auto& t : s.model->tops())
        w.writeValue(t);
    w.endArray();
    w.writeProperty("errors");
    w.writeValue(errors);
    w.writeProperty("messages");
    w.startArray();
    for (auto& m : messages)
        w.writeValue(m);
    w.endArray();
    w.writeProperty("fingerprint");
    w.writeValue(s.fingerprint);
    w.writeProperty("files");
    w.writeValue(int64_t(s.stamps.size()));
    w.writeProperty("ms");
    w.writeValue(int64_t(ms));
    w.endObject();
    reply(w);
}

// The files the last load read and their modification times (ms since 1970), for cmux's check
// that none is newer than the compile a KDB came from.
void sources(Session& s, int64_t id) {
    if (s.fingerprint.empty()) {
        fail(id, "notLoaded", "no design is loaded");
        return;
    }
    JsonWriter w;
    w.startObject();
    w.writeProperty("id");
    w.writeValue(id);
    w.writeProperty("ok");
    w.writeValue(true);
    w.writeProperty("sources");
    w.startArray();
    for (auto& st : s.stamps) {
        struct stat info;
        if (::stat(st.path.c_str(), &info) != 0)
            continue;
#ifdef __APPLE__
        auto ms = int64_t(info.st_mtimespec.tv_sec) * 1000 + info.st_mtimespec.tv_nsec / 1000000;
#else
        auto ms = int64_t(info.st_mtim.tv_sec) * 1000 + info.st_mtim.tv_nsec / 1000000;
#endif
        w.startObject();
        w.writeProperty("path");
        w.writeValue(st.path);
        w.writeProperty("mtime");
        w.writeValue(ms);
        w.endObject();
    }
    w.endArray();
    w.endObject();
    reply(w);
}

// Whether a file the last load read changed on disk since (another size or time, gone, or
// written while the load read it).
void stale(Session& s, int64_t id) {
    if (s.fingerprint.empty()) {
        fail(id, "notLoaded", "no design is loaded");
        return;
    }
    bool changed = false;
    for (auto& st : s.stamps) {
        if (st.size == -2 || !(stampOf(st.path) == st)) {
            changed = true;
            break;
        }
    }
    JsonWriter w;
    w.startObject();
    w.writeProperty("id");
    w.writeValue(id);
    w.writeProperty("ok");
    w.writeValue(true);
    w.writeProperty("changed");
    w.writeValue(changed);
    w.writeProperty("fingerprint");
    w.writeValue(s.fingerprint);
    w.endObject();
    reply(w);
}

void handle(Session& s, const JValue& req) {
    int64_t id = 0;
    if (auto v = req.get("id"); v && v->kind == JValue::Number)
        id = int64_t(v->n);
    auto cmd = req.str("cmd");
    if (cmd == "version") {
        JsonWriter w;
        w.startObject();
        w.writeProperty("id");
        w.writeValue(id);
        w.writeProperty("ok");
        w.writeValue(true);
        w.writeProperty("model");
        w.writeValue(int64_t(kModelVersion));
        w.writeProperty("slang");
        w.writeValue(std::to_string(VersionInfo::getMajor()) + "." + std::to_string(VersionInfo::getMinor()));
        w.endObject();
        reply(w);
        return;
    }
    if (cmd == "load") {
        load(s, id, req);
        return;
    }
    if (cmd == "stale") {
        stale(s, id);
        return;
    }
    if (cmd == "sources") {
        sources(s, id);
        return;
    }
    if (!s.model) {
        fail(id, "notLoaded", "no design is loaded");
        return;
    }
    if (cmd == "instances") {
        JsonWriter w;
        w.startObject();
        w.writeProperty("id");
        w.writeValue(id);
        w.writeProperty("ok");
        w.writeValue(true);
        w.writeProperty("tops");
        w.startArray();
        for (auto& t : s.model->tops())
            w.writeValue(t);
        w.endArray();
        w.writeProperty("instances");
        w.startArray();
        for (auto& p : s.model->instancePaths())
            w.writeValue(p);
        w.endArray();
        w.endObject();
        reply(w);
        return;
    }
    auto path = req.str("path");
    if (cmd == "instance") {
        auto inst = s.model->instance(path);
        if (!inst) {
            fail(id, "noInstance", path);
            return;
        }
        JsonWriter w;
        w.startObject();
        w.writeProperty("id");
        w.writeValue(id);
        w.writeProperty("ok");
        w.writeValue(true);
        w.writeProperty("model");
        s.model->writeInstance(w, *inst);
        w.endObject();
        reply(w);
        return;
    }
    if (cmd == "writers") {
        if (!s.model->instance(path)) {
            fail(id, "noInstance", path);
            return;
        }
        if (!s.writers)
            s.writers = buildWriters(*s.model);
        JsonWriter w;
        w.startObject();
        w.writeProperty("id");
        w.writeValue(id);
        w.writeProperty("ok");
        w.writeValue(true);
        w.writeProperty("writers");
        w.startArray();
        if (auto it = s.writers->find(path); it != s.writers->end())
            for (auto& p : it->second)
                w.writeValue(p);
        w.endArray();
        w.endObject();
        reply(w);
        return;
    }
    if (cmd == "lookup") {
        auto r = s.model->lookup(path);
        if (!r) {
            fail(id, "noInstance", path);
            return;
        }
        JsonWriter w;
        w.startObject();
        w.writeProperty("id");
        w.writeValue(id);
        w.writeProperty("ok");
        w.writeValue(true);
        w.writeProperty("instance");
        w.writeValue(r->first);
        w.writeProperty("name");
        w.writeValue(r->second);
        w.endObject();
        reply(w);
        return;
    }
    fail(id, "unknownCommand", cmd);
}

} // namespace

int main(int argc, char** argv) {
    // `cmux-sv-model --once <instance> <slang args...>`: load, print one instance model, exit
    // (for tests and debugging).
    Session s;
    if (argc >= 3 && std::string_view(argv[1]) == "--once") {
        JValue req;
        req.kind = JValue::Object;
        JValue args;
        args.kind = JValue::Array;
        for (int k = 3; k < argc; k++) {
            JValue a;
            a.kind = JValue::String;
            a.s = argv[k];
            args.a.push_back(a);
        }
        req.o.emplace_back("args", args);
        load(s, 1, req);
        if (!s.model)
            return 1;
        std::string what = argv[2];
        // "*": every instance, as one object {tops, instances: {path: model}}.
        if (what == "*") {
            JsonWriter w;
            w.startObject();
            w.writeProperty("tops");
            w.startArray();
            for (auto& t : s.model->tops())
                w.writeValue(t);
            w.endArray();
            w.writeProperty("instances");
            w.startObject();
            for (auto& p : s.model->instancePaths()) {
                w.writeProperty(p);
                s.model->writeInstance(w, *s.model->instance(p));
            }
            w.endObject();
            w.endObject();
            reply(w);
            return 0;
        }
        auto inst = s.model->instance(what);
        if (!inst)
            return 2;
        JsonWriter w;
        s.model->writeInstance(w, *inst);
        reply(w);
        return 0;
    }
    {
        JsonWriter w;
        w.startObject();
        w.writeProperty("id");
        w.writeValue(int64_t(0));
        w.writeProperty("ready");
        w.writeValue(true);
        w.writeProperty("model");
        w.writeValue(int64_t(kModelVersion));
        // The install's build (sv-model.sh: its folder, named by the sources' hash), when started by it.
        if (const char* build = std::getenv("CMUX_SV_MODEL_BUILD"); build && *build) {
            w.writeProperty("build");
            w.writeValue(std::string_view(build));
        }
        w.endObject();
        reply(w);
    }
    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty())
            continue;
        auto req = JParser(line).parse();
        if (!req || req->kind != JValue::Object) {
            fail(-1, "badRequest", "not a JSON object");
            continue;
        }
        handle(s, *req);
    }
    return 0;
}
