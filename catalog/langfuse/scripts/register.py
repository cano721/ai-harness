#!/usr/bin/env python3
"""Register Langfuse project keys under an alias without the keys passing through the chat.

  register.py <alias> --stage pk   # user copied the public key; read it from the clipboard
  register.py <alias> --stage sk   # user copied the secret key
  register.py <alias>              # verify staged keys (or ask via hidden macOS dialogs) and save
  register.py <alias> --pk-cmd '<command>' --sk-cmd '<command>'
                                   # keys live in a secret store (AWS SSM, Vault, 1Password, ...): save the commands
                                   # that print them; lf.py runs them on each call and keeps the keys in memory only

Use "default" as alias for the unsuffixed LANGFUSE_* keys. Saves to ~/.claude/settings.json "env"
(Claude Code) and, when ${HARNESS_METRICS_DIR:-~/.ai-harness}/secrets.env already exists, there too (Codex).
Without ~/.claude it creates secrets.env.
Saving one form removes the other form for that alias, since a stored key would shadow the command.
Key values are never printed.
"""
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request

HOSTS = ["https://cloud.langfuse.com", "https://us.cloud.langfuse.com", "https://jp.cloud.langfuse.com",
         "https://hipaa.cloud.langfuse.com"]
PREFIX = {"pk": "pk-lf-", "sk": "sk-lf-"}
DATA_DIR = os.environ.get("HARNESS_METRICS_DIR") or os.path.expanduser("~/.ai-harness")
STAGE_DIR = os.path.join(DATA_DIR if os.path.isdir(DATA_DIR) else os.path.expanduser("~/.cache"), "langfuse-staging")
SETTINGS = os.path.expanduser("~/.claude/settings.json")
SECRETS = os.path.join(DATA_DIR, "secrets.env")
CMD_TIMEOUT = 60


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def clipboard():
    for cmd in (["pbpaste"], ["wl-paste", "-n"], ["xclip", "-o", "-selection", "clipboard"]):
        try:
            return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            continue
    die("cannot read the clipboard (pbpaste / wl-paste / xclip)")


def clear_clipboard():
    for cmd in (["pbcopy"], ["wl-copy", "--clear"], ["xclip", "-selection", "clipboard"]):
        try:
            subprocess.run(cmd, input=b"", check=True)
            return
        except (OSError, subprocess.CalledProcessError):
            continue


def dialog(label, title):
    script = f'text returned of (display dialog "{label}" default answer "" with hidden answer with title "{title}")'
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode:
        die("dialog cancelled or unavailable — use --stage pk / --stage sk with the clipboard instead")
    return r.stdout.strip()


def run_key_command(command, kind):
    try:
        r = subprocess.run(["/bin/sh", "-c", command], capture_output=True, text=True, timeout=CMD_TIMEOUT,
                           stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        die(f"--{kind}-cmd timed out after {CMD_TIMEOUT}s — nothing saved")
    if r.returncode:
        tail = "\n".join(r.stderr.strip().splitlines()[-5:])
        die(f"--{kind}-cmd failed (exit {r.returncode}){': ' + tail if tail else ''} — nothing saved")
    value = r.stdout.strip()
    if "\n" in value or not value.startswith(PREFIX[kind]):
        die(f"--{kind}-cmd must print one line starting with {PREFIX[kind]} (output not shown) — nothing saved")
    return value


def write_private(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)


def find_host(pk, sk):
    auth = "Basic " + base64.b64encode(f"{pk}:{sk}".encode()).decode()
    preset = os.environ.get("LANGFUSE_HOST")
    for host in ([preset.rstrip("/")] if preset else []) + HOSTS:
        try:
            req = urllib.request.Request(host + "/api/public/projects", headers={"Authorization": auth})
            with urllib.request.urlopen(req, timeout=15) as r:
                data = json.load(r)
            return host, [p.get("name") for p in data.get("data", [])]
        except Exception as e:  # noqa: BLE001 — try the next region
            print(f"{host} -> {getattr(e, 'code', e)}", file=sys.stderr)
    return None, None


def load_settings():
    if not os.path.exists(SETTINGS):
        return {}
    try:
        with open(SETTINGS) as f:
            data = json.load(f)
    except (OSError, ValueError):
        data = None
    if not isinstance(data, dict) or not isinstance(data.get("env", {}), dict):
        die(f"not a JSON object (or its env is not), left unchanged: {SETTINGS} — nothing saved")
    return data


def save_settings(data, values, drop):
    if not os.path.isdir(os.path.dirname(SETTINGS)):
        return False
    if os.path.exists(SETTINGS):
        shutil.copy(SETTINGS, SETTINGS + ".bak-langfuse")
    env = data.setdefault("env", {})
    for k in drop:
        env.pop(k, None)
    env.update(values)
    tmp = f"{SETTINGS}.tmp.{os.getpid()}"
    write_private(tmp, json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    if os.path.exists(SETTINGS):
        shutil.copymode(SETTINGS, tmp)
    os.replace(tmp, SETTINGS)
    return True


def save_secrets(values, drop, create):
    if not (os.path.exists(SECRETS) or create):
        return False
    lines = []
    if os.path.exists(SECRETS):
        with open(SECRETS) as f:
            lines = [l for l in f.read().splitlines()
                     if not any(l.startswith(f"export {k}=") for k in [*values, *drop])]
    os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)
    for k, v in values.items():
        lines.append(f"export {k}='" + v.replace("'", "'\\''") + "'")
    write_private(SECRETS, "\n".join(lines) + "\n")
    return True


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return
    alias = args[0]
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", alias):
        die("alias: lowercase letters, digits and '-' only")
    if alias == "cmd" or alias.startswith("cmd-"):
        die("alias: 'cmd' and 'cmd-*' are reserved (they collide with the *_CMD keys)")
    suffix = "" if alias == "default" else "_" + alias.upper().replace("-", "_")
    direct = [f"LANGFUSE_PUBLIC_KEY{suffix}", f"LANGFUSE_SECRET_KEY{suffix}"]
    commands = [f"LANGFUSE_PUBLIC_KEY_CMD{suffix}", f"LANGFUSE_SECRET_KEY_CMD{suffix}"]

    if "--pk-cmd" in args or "--sk-cmd" in args:
        opts = dict(zip(args[1::2], args[2::2]))
        if len(args) != 5 or set(opts) != {"--pk-cmd", "--sk-cmd"} or not all(opts.values()):
            die("usage: register.py <alias> --pk-cmd '<command>' --sk-cmd '<command>'")
        pk, sk = run_key_command(opts["--pk-cmd"], "pk"), run_key_command(opts["--sk-cmd"], "sk")
        settings = load_settings()
        host, projects = find_host(pk, sk)
        if not host:
            die("authentication failed in every region — nothing saved")
        values = {commands[0]: opts["--pk-cmd"], commands[1]: opts["--sk-cmd"], f"LANGFUSE_HOST{suffix}": host}
        report(alias, save_all(settings, values, direct), host, projects)
        clear_stage(os.path.join(STAGE_DIR, alias))
        return

    os.makedirs(STAGE_DIR, mode=0o700, exist_ok=True)
    stage = os.path.join(STAGE_DIR, alias)

    if len(args) == 3 and args[1] == "--stage" and args[2] in PREFIX:
        kind = args[2]
        value = clipboard()
        if not value.startswith(PREFIX[kind]):
            die(f"clipboard does not start with {PREFIX[kind]} — copy the key again")
        write_private(f"{stage}.{kind}", value)
        clear_clipboard()
        print(f"[{alias}] {kind} staged (clipboard cleared)")
        return

    if os.path.exists(stage + ".pk") and os.path.exists(stage + ".sk"):
        pk, sk = (open(stage + ext).read().strip() for ext in (".pk", ".sk"))
    else:
        pk = dialog("Public Key (pk-lf-...)", f"Langfuse: {alias}")
        sk = dialog("Secret Key (sk-lf-...)", f"Langfuse: {alias}")
    if not (pk.startswith(PREFIX["pk"]) and sk.startswith(PREFIX["sk"])):
        die("key format mismatch (pk-lf- / sk-lf-)")
    settings = load_settings()

    host, projects = find_host(pk, sk)
    if not host:
        die("authentication failed in every region — nothing saved (staged keys kept for retry)")
    values = {direct[0]: pk, direct[1]: sk, f"LANGFUSE_HOST{suffix}": host}
    targets = save_all(settings, values, commands)
    clear_stage(stage)
    report(alias, targets, host, projects)


def clear_stage(stage):
    for ext in (".pk", ".sk"):
        if os.path.exists(stage + ext):
            os.remove(stage + ext)


def save_all(settings, values, drop):
    claude = save_settings(settings, values, drop)
    secrets = save_secrets(values, drop, create=not claude)
    return [name for name, ok in (("~/.claude/settings.json", claude), ("secrets.env", secrets)) if ok]


def report(alias, targets, host, projects):
    print(f"[{alias}] saved to {', '.join(targets) or 'nowhere'} — host={host} project={projects}. "
          "New env applies to the next session; lf.py reads the files directly.")


if __name__ == "__main__":
    main()
