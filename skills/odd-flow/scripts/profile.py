#!/usr/bin/env python3
"""Resolve odd-flow role profiles for the current agent session.

Profiles live in $ODD_FLOW_HOME/profiles.json (default ~/.config/odd-flow).
A session binding written by `use` lives in $ODD_FLOW_HOME/sessions/<key>.json,
keyed by the agent's own session id, or by the Orca pane as a fallback.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time

BASE_ROLES = ("explore", "write", "verify", "review", "refute")
LENSES = ("risk", "resilience", "readability", "reliability")
ROLES = BASE_ROLES + tuple(f"review-{lens}" for lens in LENSES)
ENTRY_FIELDS = ("agent", "model", "effort")

# First present variable wins. The agent column is the Orca agent id of the
# runtime that sets the variable; the pane key identifies no agent.
SESSION_VARS = (
    ("CLAUDE_CODE_SESSION_ID", "claude"),
    ("CODEX_THREAD_ID", "codex"),
    ("CODEX_SESSION_ID", "codex"),
    ("ANTIGRAVITY_CONVERSATION_ID", "antigravity"),
    ("ORCA_PANE_KEY", None),
)


class ProfileError(Exception):
    pass


def home_dir():
    return os.environ.get("ODD_FLOW_HOME") or os.path.join(
        os.path.expanduser("~"), ".config", "odd-flow"
    )


def profiles_path():
    return os.path.join(home_dir(), "profiles.json")


def session_key():
    """Return (variable, value, agent) for the first session variable present."""
    for var, agent in SESSION_VARS:
        value = os.environ.get(var, "").strip()
        if value:
            return var, value, agent
    return None, None, None


def current_agent():
    """Orca agent id of the runtime this session runs in, if known."""
    _, _, agent = session_key()
    return agent or os.environ.get("ODD_FLOW_AGENT", "").strip() or None


def session_file(value):
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", value)
    return os.path.join(home_dir(), "sessions", f"{safe}.json")


def write_json_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2)
            handle.write("\n")
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def load_profiles():
    """Return the validated profile document, or an empty one when no file exists."""
    path = profiles_path()
    if not os.path.exists(path):
        return {"default": None, "profiles": {}, "path": path, "exists": False}
    try:
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
    except json.JSONDecodeError as exc:
        raise ProfileError(f"{path}: invalid JSON: {exc}") from exc
    if not isinstance(doc, dict):
        raise ProfileError(f"{path}: top level must be an object")
    profiles = doc.get("profiles", {})
    if not isinstance(profiles, dict):
        raise ProfileError(f"{path}: 'profiles' must be an object")
    for name, roles in profiles.items():
        if not isinstance(roles, dict):
            raise ProfileError(f"{path}: profile '{name}' must be an object")
        for role, entry in roles.items():
            where = f"{path}: profile '{name}', role '{role}'"
            if role not in ROLES:
                raise ProfileError(f"{where}: unknown role (known: {', '.join(ROLES)})")
            if not isinstance(entry, dict):
                raise ProfileError(f"{where}: must be an object")
            extra = set(entry) - set(ENTRY_FIELDS)
            if extra:
                raise ProfileError(f"{where}: unknown fields {sorted(extra)}")
            for field in ENTRY_FIELDS:
                if field in entry and (not isinstance(entry[field], str) or not entry[field].strip()):
                    raise ProfileError(f"{where}: '{field}' must be a non-empty string")
            if "effort" in entry and "model" not in entry:
                raise ProfileError(f"{where}: 'effort' requires 'model'")
    default = doc.get("default")
    if default is not None and default not in profiles:
        raise ProfileError(f"{path}: default profile '{default}' is not defined")
    return {"default": default, "profiles": profiles, "path": path, "exists": True}


def read_binding():
    var, value, _ = session_key()
    if not value:
        return None
    path = session_file(value)
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise ProfileError(f"{path}: unreadable session binding: {exc}") from exc
    name = data.get("profile") if isinstance(data, dict) else None
    if not isinstance(name, str) or not name:
        raise ProfileError(f"{path}: session binding has no profile")
    return name, f"session ({var})"


def selected_profile(doc):
    """Return (name, source). name is None when no profile applies."""
    binding = read_binding()
    if binding:
        name, source = binding
    elif os.environ.get("ODD_PROFILE", "").strip():
        name, source = os.environ["ODD_PROFILE"].strip(), "env ODD_PROFILE"
    elif doc["default"]:
        name, source = doc["default"], "file default"
    else:
        return None, "none"
    if name not in doc["profiles"]:
        known = ", ".join(sorted(doc["profiles"])) or "none"
        raise ProfileError(f"profile '{name}' from {source} is not defined in {doc['path']} (known: {known})")
    return name, source


def resolve_role(doc, role):
    if role not in ROLES:
        raise ProfileError(f"unknown role '{role}' (known: {', '.join(ROLES)})")
    name, source = selected_profile(doc)
    roles = doc["profiles"].get(name, {}) if name else {}
    entry = roles.get(role)
    entry_role = role
    if entry is None and role.startswith("review-"):
        entry, entry_role = roles.get("review"), "review"
    entry = dict(entry or {})
    agent = entry.get("agent") or current_agent()
    if not agent:
        raise ProfileError(
            f"cannot determine the agent for role '{role}': add it to the profile or set ODD_FLOW_AGENT"
        )
    flags = ["--agent", agent]
    if entry.get("model"):
        flags += ["--model", entry["model"]]
        if entry.get("effort"):
            flags += ["--effort", entry["effort"]]
    from_profile = bool(entry)
    parts = [agent, entry.get("model") or "agent default model"]
    if entry.get("effort"):
        parts.append(f"effort {entry['effort']}")
    notice = (
        f"profile: {name or 'none'} ({source}) | {role} -> " + " / ".join(parts)
        + ("" if from_profile else " (role not in profile)")
    )
    return {
        "role": role,
        "profile": name,
        "profile_source": source,
        "entry_role": entry_role if from_profile else None,
        "agent": agent,
        "model": entry.get("model"),
        "effort": entry.get("effort"),
        "flags": flags,
        "notice": notice,
    }


def cmd_resolve(args):
    result = resolve_role(load_profiles(), args.role)
    if args.json:
        print(json.dumps(result))
    else:
        print(result["notice"])
        print(" ".join(result["flags"]))


def cmd_use(args):
    doc = load_profiles()
    if args.name not in doc["profiles"]:
        known = ", ".join(sorted(doc["profiles"])) or "none"
        raise ProfileError(f"profile '{args.name}' is not defined in {doc['path']} (known: {known})")
    var, value, _ = session_key()
    if not value:
        raise ProfileError("no session id found (Claude, Codex, Antigravity or ORCA_PANE_KEY); launch with ODD_PROFILE instead")
    write_json_atomic(session_file(value), {"profile": args.name, "key": var, "updated_at": int(time.time())})
    note = " (bound to the Orca pane, not the conversation)" if var == "ORCA_PANE_KEY" else ""
    print(f"profile: {args.name} bound to this session via {var}{note}")


def cmd_clear(_args):
    var, value, _ = session_key()
    if not value:
        print("no session id found; nothing to clear")
        return
    path = session_file(value)
    if os.path.exists(path):
        os.unlink(path)
        print(f"session binding removed ({var})")
    else:
        print("no session binding for this session")


def cmd_list(_args):
    doc = load_profiles()
    if not doc["exists"]:
        print(f"no profiles file at {doc['path']}; every role uses the current agent and its own model")
        return
    for name in sorted(doc["profiles"]):
        marker = " (default)" if name == doc["default"] else ""
        print(f"{name}{marker}: {', '.join(sorted(doc['profiles'][name])) or 'no roles'}")


def cmd_show(_args):
    doc = load_profiles()
    var, _, _ = session_key()
    name, source = selected_profile(doc)
    print(f"profile: {name or 'none'} ({source}); session key: {var or 'none'}; agent: {current_agent() or 'unknown'}")
    for role in BASE_ROLES:
        try:
            print("  " + resolve_role(doc, role)["notice"].split(" | ", 1)[1])
        except ProfileError as exc:
            print(f"  {role} -> error: {exc}")


def cmd_check(_args):
    doc = load_profiles()
    try:
        out = subprocess.run(
            [os.environ.get("ORCA_CLI_COMMAND", "orca"), "agent", "installed", "--json"],
            capture_output=True, text=True, timeout=30, check=True,
        ).stdout
        data = json.loads(out)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        raise ProfileError(f"cannot list Orca agents: {exc}") from exc
    items = data.get("result", data)
    if isinstance(items, dict):
        items = items.get("agents", [])
    installed = {item.get("id") for item in items if isinstance(item, dict)}
    problems = [
        f"{name}.{role}: agent '{entry['agent']}' is not installed or enabled in Orca"
        for name, roles in sorted(doc["profiles"].items())
        for role, entry in sorted(roles.items())
        if entry.get("agent") and entry["agent"] not in installed
    ]
    print(f"Orca agents: {', '.join(sorted(a for a in installed if a))}")
    if problems:
        print("\n".join(problems))
        sys.exit(1)
    print("all profile agents are available (models are only checked at launch)")


def cmd_prune(args):
    folder = os.path.join(home_dir(), "sessions")
    if not os.path.isdir(folder):
        print("no session bindings")
        return
    cutoff = time.time() - args.days * 86400
    removed = 0
    for entry in os.listdir(folder):
        path = os.path.join(folder, entry)
        if entry.endswith(".json") and os.path.isfile(path) and os.path.getmtime(path) < cutoff:
            os.unlink(path)
            removed += 1
    print(f"removed {removed} session binding(s) older than {args.days} days")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="profile.py", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    resolve = sub.add_parser("resolve", help="print launch flags for a role")
    resolve.add_argument("role")
    resolve.add_argument("--json", action="store_true")
    resolve.set_defaults(func=cmd_resolve)
    use = sub.add_parser("use", help="bind a profile to this session")
    use.add_argument("name")
    use.set_defaults(func=cmd_use)
    sub.add_parser("clear", help="remove this session's binding").set_defaults(func=cmd_clear)
    sub.add_parser("list", help="list profiles").set_defaults(func=cmd_list)
    sub.add_parser("show", help="show the active profile and every role").set_defaults(func=cmd_show)
    sub.add_parser("check", help="check profile agents against Orca").set_defaults(func=cmd_check)
    prune = sub.add_parser("prune", help="remove old session bindings")
    prune.add_argument("--days", type=int, default=30)
    prune.set_defaults(func=cmd_prune)
    args = parser.parse_args(argv)
    try:
        args.func(args)
    except ProfileError as exc:
        print(f"odd-flow: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
