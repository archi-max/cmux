# Extract the page strings ("key": String(localized: "...", defaultValue: "...")) from the app's Swift files.
import re, sys, json, glob
pat = re.compile(r'"([\w.]+)"\s*:\s*String\(\s*localized:\s*"[^"]*",\s*defaultValue:\s*"((?:[^"\\]|\\.)*)"', re.S)
out = {}
for f in sys.argv[2:]:
    for k, v in pat.findall(open(f, encoding='utf-8').read()):
        v = re.sub(r'\\u\{([0-9a-fA-F]+)\}', lambda m: chr(int(m.group(1), 16)), v).replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')
        out.setdefault(k, v)
out.update({"netlist": "Netlist", "loading": "Loading waveform…", "openFailed": "Unable to open waveform", "addSignal": "Add to viewer"})
json.dump(out, open(sys.argv[1], 'w'), ensure_ascii=False, indent=0)
print(len(out), "strings")
