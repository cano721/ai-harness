#!/usr/bin/env python3
"""Langfuse CLI: official MCP tools over plain HTTP + public REST, multi-project by alias.

Credentials (per Langfuse project): LANGFUSE_PUBLIC_KEY[_ALIAS], LANGFUSE_SECRET_KEY[_ALIAS],
LANGFUSE_HOST[_ALIAS]. Lookup order: process env -> ~/.claude/settings.json "env" ->
${HARNESS_METRICS_DIR:-~/.ai-harness}/secrets.env. When a key has no value, LANGFUSE_PUBLIC_KEY_CMD[_ALIAS] /
LANGFUSE_SECRET_KEY_CMD[_ALIAS] name a shell command that prints it (AWS SSM, Vault, 1Password, ...). Commands are read
only from those two user files; a *_CMD in the process env is ignored.
Secrets are never printed.
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_HOST = "https://cloud.langfuse.com"
CACHE_DIR = os.path.expanduser("~/.cache/langfuse-skill")
CACHE_TTL = 24 * 3600
CMD_TIMEOUT = 60
KEY_PREFIX = {"LANGFUSE_PUBLIC_KEY": "pk-lf-", "LANGFUSE_SECRET_KEY": "sk-lf-"}
SETTINGS_FILES = [os.path.expanduser("~/.claude/settings.json")]


def die(msg, code=2):
    print(msg, file=sys.stderr)
    sys.exit(code)


SECRETS_FILE = os.path.join(os.environ.get("HARNESS_METRICS_DIR") or os.path.expanduser("~/.ai-harness"), "secrets.env")


def secrets_env():
    out = {}
    try:
        with open(SECRETS_FILE) as f:
            for line in f:
                m = re.fullmatch(r"export ([A-Z0-9_]+)='(.*)'", line.rstrip("\n"))
                if m:
                    out[m.group(1)] = m.group(2).replace("'\\''", "'")
    except OSError:
        pass
    return out


def settings_env():
    merged = secrets_env()
    for path in SETTINGS_FILES:
        try:
            with open(path) as f:
                merged.update(json.load(f).get("env", {}) or {})
        except (OSError, ValueError):
            pass
    return merged


def lookup(name):
    return os.environ.get(name) or settings_env().get(name)


def suffix(alias):
    return "_" + alias.upper().replace("-", "_") if alias else ""


def aliases():
    files = settings_env()
    found = set()
    for n in set(os.environ) | set(files):
        m = re.fullmatch(r"LANGFUSE_PUBLIC_KEY(_CMD)?(?:_([A-Z0-9_]+))?", n)
        if m and not (m.group(1) and n not in files):
            found.add(m.group(2).lower().replace("_", "-") if m.group(2) else "")
    return sorted(found)


def key_value(base, alias):
    value = lookup(base + suffix(alias))
    if value:
        return value
    name = base + "_CMD" + suffix(alias)
    command = settings_env().get(name)
    if not command:
        return None
    try:
        r = subprocess.run(["/bin/sh", "-c", command], capture_output=True, text=True, timeout=CMD_TIMEOUT,
                           stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        die(f"{name} timed out after {CMD_TIMEOUT}s", 1)
    if r.returncode:
        tail = "\n".join(r.stderr.strip().splitlines()[-5:])
        die(f"{name} failed (exit {r.returncode}){': ' + tail if tail else ''}", 1)
    value = r.stdout.strip()
    if "\n" in value or not value.startswith(KEY_PREFIX[base]):
        die(f"{name} must print one line starting with {KEY_PREFIX[base]} (output not shown)", 1)
    return value


def credentials(alias):
    if alias and not re.fullmatch(r"[a-z0-9][a-z0-9-]*", alias):
        die("alias: lowercase letters, digits and '-' only")
    if alias == "cmd" or alias.startswith("cmd-"):
        die(f"alias '{alias}' is reserved: its env names collide with the *_CMD keys")
    s = suffix(alias)
    pk, sk = key_value("LANGFUSE_PUBLIC_KEY", alias), key_value("LANGFUSE_SECRET_KEY", alias)
    if not (pk and sk):
        known = ", ".join(a or "(default)" for a in aliases()) or "none"
        die(f"Langfuse keys not registered for project '{alias or '(default)'}'. Registered: {known}")
    host = (lookup("LANGFUSE_HOST" + s) or lookup("LANGFUSE_HOST") or DEFAULT_HOST).rstrip("/")
    return host, "Basic " + base64.b64encode(f"{pk}:{sk}".encode()).decode()


def http(method, url, auth, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": auth,
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode()
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        die(f"HTTP {e.code} {method} {url}\n{raw[:2000]}", 1)
    except (urllib.error.URLError, OSError) as e:
        die(f"cannot reach {url}: {getattr(e, 'reason', e)} (check LANGFUSE_HOST)", 1)
    if raw.startswith("event:") or raw.startswith("data:"):
        raw = "\n".join(l[5:].strip() for l in raw.splitlines() if l.startswith("data:"))
    try:
        return json.loads(raw) if raw else None
    except ValueError:
        return raw


def mcp(host, auth, method, params):
    res = http("POST", host + "/api/public/mcp", auth, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    if isinstance(res, dict) and res.get("error"):
        die("MCP error: " + json.dumps(res["error"], ensure_ascii=False), 1)
    return res.get("result") if isinstance(res, dict) else res


def tool_list(host, auth, refresh=False):
    os.makedirs(CACHE_DIR, exist_ok=True)
    path = os.path.join(CACHE_DIR, re.sub(r"[^a-z0-9]+", "_", host.lower()) + ".tools.json")
    if not refresh and os.path.exists(path) and time.time() - os.path.getmtime(path) < CACHE_TTL:
        with open(path) as f:
            return json.load(f)
    tools = mcp(host, auth, "tools/list", {})["tools"]
    with open(path, "w") as f:
        json.dump(tools, f)
    return tools


def risk(tool):
    a = tool.get("annotations") or {}
    if a.get("destructiveHint"):
        return "destructive"
    if a.get("readOnlyHint"):
        return "read" + ("+expensive" if a.get("expensiveHint") else "")
    return "write" + ("+expensive" if a.get("expensiveHint") else "")


def clip(value, limit):
    if limit <= 0:
        return value
    if isinstance(value, str):
        if len(value) > limit:
            return value[:limit] + f"...[+{len(value) - limit} chars]"
        stripped = value.strip()
        if stripped[:1] in "[{":
            try:
                return clip(json.loads(stripped), limit)
            except ValueError:
                pass
        return value
    if isinstance(value, list):
        return [clip(v, limit) for v in value]
    if isinstance(value, dict):
        return {k: clip(v, limit) for k, v in value.items()}
    return value


def emit(value, limit):
    print(json.dumps(clip(value, limit), ensure_ascii=False, indent=2))


def warn_deprecation(res):
    if isinstance(res, dict) and res.get("_deprecation"):
        print("WARNING deprecated endpoint: " + json.dumps(res["_deprecation"], ensure_ascii=False)[:600], file=sys.stderr)


def parse_kv(pairs):
    out = []
    for p in pairs:
        if "=" not in p:
            die(f"expected key=value, got '{p}'")
        out.append(tuple(p.split("=", 1)))
    return out


def main():
    ap = argparse.ArgumentParser(prog="lf.py", description=__doc__)
    ap.add_argument("-p", "--project", default="", help="project alias (env suffix); empty = default keys")
    ap.add_argument("--max-str", type=int, default=500, help="truncate string values longer than N (0 = off)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("aliases", help="list registered project aliases")
    sub.add_parser("whoami", help="show host and project the keys point to")
    t = sub.add_parser("tools", help="list MCP tools with risk class")
    t.add_argument("grep", nargs="?", default="")
    t.add_argument("--refresh", action="store_true")
    s = sub.add_parser("schema", help="show a tool's input schema")
    s.add_argument("tool")
    c = sub.add_parser("call", help="call an MCP tool with JSON arguments")
    c.add_argument("tool")
    c.add_argument("args", nargs="?", default="{}")
    c.add_argument("--yes", action="store_true", help="allow non-read-only tool (after user confirmation)")
    c.add_argument("--allow-destructive", action="store_true", help="allow destructive tool (explicit user request only)")
    r = sub.add_parser("rest", help="call a public REST endpoint")
    r.add_argument("method", choices=["GET", "POST", "PATCH", "PUT", "DELETE"])
    r.add_argument("path")
    r.add_argument("params", nargs="*", help="query params key=value")
    r.add_argument("--body", help="JSON body")
    r.add_argument("--yes", action="store_true", help="allow non-GET (after user confirmation)")
    a = ap.parse_args()

    if a.cmd == "aliases":
        for name in aliases():
            print(name or "(default)")
        return

    host, auth = credentials(a.project)

    if a.cmd == "whoami":
        res = http("GET", host + "/api/public/projects", auth)
        emit({"host": host, "projects": [{"id": p.get("id"), "name": p.get("name")} for p in (res or {}).get("data", [])]}, 0)
    elif a.cmd == "tools":
        for tool in tool_list(host, auth, a.refresh):
            if a.grep.lower() in tool["name"].lower():
                desc = ((tool.get("description") or "").strip().splitlines() or [""])[0][:110]
                print(f"{tool['name']:<36} {risk(tool):<20} {desc}")
    elif a.cmd == "schema":
        tool = next((x for x in tool_list(host, auth) if x["name"] == a.tool), None)
        if not tool:
            die(f"unknown tool '{a.tool}' (try: tools {a.tool[:5]})")
        emit({"name": tool["name"], "risk": risk(tool), "description": tool.get("description"),
              "inputSchema": tool.get("inputSchema")}, 0)
    elif a.cmd == "call":
        tool = next((x for x in tool_list(host, auth) if x["name"] == a.tool), None)
        if not tool:
            die(f"unknown tool '{a.tool}' (try: tools --refresh)")
        level = risk(tool)
        if level == "destructive" and not a.allow_destructive:
            die(f"BLOCKED: '{a.tool}' is destructive. Only with an explicit user request, rerun with --allow-destructive.")
        if level.startswith("write") and not (a.yes or a.allow_destructive):
            die(f"BLOCKED: '{a.tool}' changes data ({level}). Confirm with the user, then rerun with --yes.")
        try:
            args = json.loads(a.args)
        except ValueError as e:
            die(f"arguments must be JSON: {e}")
        res = mcp(host, auth, "tools/call", {"name": a.tool, "arguments": args})
        if not isinstance(res, dict):
            emit(res, a.max_str)
            sys.exit(1)
        texts = [x.get("text", "") for x in res.get("content", []) if x.get("type") == "text"]
        payload = texts[0] if len(texts) == 1 else texts
        if isinstance(payload, str):
            try:
                payload = json.loads(payload)
            except ValueError:
                pass
        emit(payload, a.max_str)
        if res.get("isError"):
            sys.exit(1)
    elif a.cmd == "rest":
        if a.method != "GET" and not a.yes:
            die(f"BLOCKED: {a.method} changes data. Confirm with the user, then rerun with --yes.")
        if a.method == "DELETE":
            die("BLOCKED: REST DELETE is not supported. Use the matching MCP tool with --allow-destructive on explicit user request.")
        path = a.path if a.path.startswith("/") else "/" + a.path
        query = urllib.parse.urlencode(parse_kv(a.params))
        url = host + path + ("?" + query if query else "")
        body = json.loads(a.body) if a.body else None
        res = http(a.method, url, auth, body)
        warn_deprecation(res)
        emit(res, a.max_str)


if __name__ == "__main__":
    main()
