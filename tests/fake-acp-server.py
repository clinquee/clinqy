#!/usr/bin/env python3
"""Small deterministic ACP peer used by ACPAgentSessionTests; no provider account or model is contacted."""

import json
import os
import sys

provider, log_path = sys.argv[1:3]


def record(value):
    with open(log_path, "a", encoding="utf-8") as log:
        log.write(json.dumps(value) + "\n")


def send(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()


def response(request, result):
    send({"jsonrpc": "2.0", "id": request["id"], "result": result})


cwd = os.getcwd()
setup = {"cwd": cwd}
if provider == "opencode-cli":
    setup["apiKeyPassed"] = os.environ.get("OPENCODE_API_KEY") == "test-opencode-key"
    setup["databaseOverridePassed"] = os.environ.get("OPENCODE_DB") == "test-opencode.db"
    inline_raw = os.environ.get("OPENCODE_CONFIG_CONTENT", "{}")
    try:
        inline = json.loads(inline_raw)
    except json.JSONDecodeError:
        inline = {}
    global_rules = inline.get("permissions", [])
    agent_rules = inline.get("agents", {}).get("clinqy", {}).get("permissions", [])
    setup["pureMode"] = os.environ.get("OPENCODE_PURE") == "true"
    setup["inlineModelPreserved"] = inline.get("model") == "openai/gpt-4o"
    setup["globalDenyLast"] = bool(global_rules) and global_rules[-1] == {
        "action": "*", "resource": "*", "effect": "deny"
    }
    setup["agentDenyLast"] = bool(agent_rules) and agent_rules[-1] == {
        "action": "*", "resource": "*", "effect": "deny"
    }
    try:
        with open(os.path.join(cwd, "opencode.json"), encoding="utf-8") as config:
            setup["opencodeConfig"] = json.load(config)
        with open(os.path.join(cwd, ".opencode", "agents", "clinqy.md"), encoding="utf-8") as agent:
            setup["agentRules"] = agent.read()
    except OSError:
        setup["opencodeConfig"] = {}
        setup["agentRules"] = ""
elif provider == "cursor-cli":
    setup["apiKeyPassed"] = os.environ.get("CURSOR_API_KEY") == "test-cursor-key"
    try:
        with open(os.path.join(cwd, ".cursor", "cli.json"), encoding="utf-8") as config:
            setup["cursorCliConfig"] = json.load(config)
        with open(os.path.join(cwd, "AGENTS.md"), encoding="utf-8") as rules:
            setup["cursorInstructions"] = rules.read()
    except OSError:
        setup["cursorCliConfig"] = {}
        setup["cursorInstructions"] = ""
record(setup)

for line in sys.stdin:
    message = json.loads(line)
    record(message)
    method = message.get("method")
    if not method or "id" not in message:
        continue
    if method == "initialize":
        auth = [{"id": "opencode-login", "type": "agent"}] if provider == "opencode-cli" else []
        response(message, {"protocolVersion": 1, "authMethods": auth})
    elif method == "authenticate":
        response(message, {})
    elif method == "session/new":
        response(message, {"sessionId": "fake-session"})
    elif method == "session/prompt":
        reject_id = "reject" if provider == "opencode-cli" else "reject-once"
        send({"jsonrpc": "2.0", "id": 77, "method": "session/request_permission", "params": {
            "sessionId": "fake-session",
            "options": [{"optionId": reject_id, "name": "Reject", "kind": "reject_once"}],
        }})
        permission_response = json.loads(sys.stdin.readline())
        record(permission_response)
        outcome = permission_response.get("result", {}).get("outcome", {})
        if outcome.get("optionId") != reject_id or outcome.get("outcome") != "selected":
            raise RuntimeError("the test agent expected its advertised rejection option to be selected")
        for chunk in ("Hello ", "from ACP"):
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "fake-session",
                "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": chunk}},
            }})
        response(message, {"stopReason": "end_turn"})
    else:
        response(message, {})
