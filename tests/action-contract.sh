#!/bin/zsh
# Prompt, typed capability table and dispatcher must name the same actions (no advertised-but-unsupported action,
# no dispatched action the model is never told about, no table entry nothing implements).
set -eu
cd "$(dirname "$0")/.."
python3 - <<'PY'
import re, sys
src = open("Sources/Clinqy/Agent.swift").read()
prompt = open("Sources/Clinqy/AgentPrompt.swift").read()
table = open("Sources/Clinqy/ActionContract.swift").read()
supported = set(re.findall(r'"([a-z_]+)"', re.search(r'supportedKinds: Set<String> = \[(.*?)\]', table, re.S).group(1)))
advertised = set(re.findall(r'\{"do":"([a-z_]+)"', prompt))
body = src[src.index("private func execute("):]
body = body[:body.index("\n    /// Why acting on the app the model saw would be wrong now")]
dispatched = set()
for line in body.split("\n"):
    m = re.match(r'^        case ("[a-z_]+".*?):\s*$', line)
    if m: dispatched |= set(re.findall(r'"([a-z_]+)"', m.group(1).split(" where ")[0]))

problems = []
for k in sorted(advertised - supported): problems.append(f"prompt advertises {k}, absent from ActionContract.supportedKinds")
for k in sorted(advertised - dispatched - {"finish"}): problems.append(f"prompt advertises {k} but execute() has no case for it")
for k in sorted(supported - dispatched - {"parallel_browser"}): problems.append(f"ActionContract.supportedKinds lists {k} but execute() has no case for it")
for k in sorted(dispatched - supported): problems.append(f"execute() handles {k} missing from ActionContract.supportedKinds")
specs = set(re.findall(r'^        "([a-z_]+)": Spec\(', table, re.M))
for k in sorted(specs - supported): problems.append(f"Spec for {k} but it is not a supported action")
if "fill_secret" in prompt: problems.append("prompt mentions fill_secret, which does not exist")
if problems:
    print("\n".join("FAIL: " + p for p in problems)); sys.exit(1)
print(f"PASS: {len(supported)} actions consistent across prompt ({len(advertised)} advertised), table and dispatcher")
PY
