#!/usr/bin/env python3
"""Resolve odd-flow role profiles for the current agent session.

Profiles live in $ODD_FLOW_HOME/profiles.json (default ~/.config/odd-flow).
A session binding written by `use` or `session-mode` lives in
$ODD_FLOW_HOME/sessions/<key>.json, keyed by the agent's own session id, or by
the Orca pane as a fallback.

Each profile runs the orchestrator in one of two peer modes, organic (default)
or full-delegation, stored in the file's top-level `workflow` map. The map sits
beside `profiles` because a profile's keys are roles only.
"""

import argparse
import difflib
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
MODES = ("organic", "full-delegation")
DEFAULT_MODE = "organic"
MODE_ENV = "ODD_ORCHESTRATOR_MODE"
WORKFLOW_FIELDS = ("orchestratorMode",)
# Claude Code exposes no model list; these ids are suggestions, reported as unverified.
CLAUDE_MODELS = ("claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5")
CLAUDE_EFFORTS = ("low", "medium", "high", "xhigh", "max")
ORCA_HANDLE_RE = re.compile(r"[A-Za-z0-9_:.-]{1,200}")
CODEX_LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "codex-worker.sh")

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


def orca_terminal():
    """Handle of the Orca terminal this session runs in, or None.

    Orca addresses worker reports to the launching terminal's mailbox; without
    this handle `orchestration worker-start` fails with no_active_sender_terminal.
    """
    handle = os.environ.get("ORCA_TERMINAL_HANDLE", "").strip()
    # The handle reaches the session context through the SessionStart hook;
    # anything outside a plain identifier is treated as no terminal.
    return handle if ORCA_HANDLE_RE.fullmatch(handle) else None


def orca_line(mode=None):
    handle = orca_terminal()
    if handle:
        return f"orca: terminal {handle}; workers launch through Orca"
    fallback = "subagents" if mode == "full-delegation" else "subagents or inline"
    if os.environ.get("ORCA_TERMINAL_HANDLE", "").strip():
        return f"orca: ORCA_TERMINAL_HANDLE is malformed (ignored); workers fall back to {fallback}"
    return f"orca: no Orca terminal (ORCA_TERMINAL_HANDLE unset); workers fall back to {fallback}"


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


def read_raw():
    """Return (text, document) of the profiles file; ("", None) when it does not exist."""
    path = profiles_path()
    if not os.path.exists(path):
        return "", None
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    try:
        return text, json.loads(text)
    except json.JSONDecodeError as exc:
        raise ProfileError(f"{path}: invalid JSON: {exc}") from exc


def load_profiles():
    """Return the validated profile document, or an empty one when no file exists."""
    path = profiles_path()
    _, doc = read_raw()
    if doc is None:
        return {"default": None, "profiles": {}, "workflow": {}, "path": path, "exists": False}
    return validate_doc(doc, path)


def validate_doc(doc, path):
    """Validate a raw profile document; return its normalized view."""
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
    workflow = doc.get("workflow", {})
    if not isinstance(workflow, dict):
        raise ProfileError(f"{path}: 'workflow' must be an object")
    for name, entry in workflow.items():
        where = f"{path}: workflow '{name}'"
        if name not in profiles:
            raise ProfileError(f"{where}: profile is not defined")
        if not isinstance(entry, dict):
            raise ProfileError(f"{where}: must be an object")
        extra = set(entry) - set(WORKFLOW_FIELDS)
        if extra:
            raise ProfileError(f"{where}: unknown fields {sorted(extra)}")
        mode = entry.get("orchestratorMode", DEFAULT_MODE)
        if mode not in MODES:
            raise ProfileError(f"{where}: unknown orchestratorMode '{mode}' (known: {', '.join(MODES)})")
    return {"default": default, "profiles": profiles, "workflow": workflow, "path": path, "exists": True}


def read_session():
    """Return (data, var) of this session's binding file; data is {} when there is none."""
    var, value, _ = session_key()
    if not value:
        return {}, var
    path = session_file(value)
    if not os.path.exists(path):
        return {}, var
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise ProfileError(f"{path}: unreadable session binding: {exc}") from exc
    if not isinstance(data, dict):
        raise ProfileError(f"{path}: session binding must be an object")
    name, mode = data.get("profile"), data.get("mode")
    if name is not None and (not isinstance(name, str) or not name):
        raise ProfileError(f"{path}: session binding has an invalid profile")
    if mode is not None and mode not in MODES:
        raise ProfileError(f"{path}: session binding has unknown mode '{mode}' (known: {', '.join(MODES)})")
    if name is None and mode is None:
        raise ProfileError(f"{path}: session binding has no profile")
    return data, var


def read_binding():
    data, var = read_session()
    if not data.get("profile"):
        return None
    return data["profile"], f"session ({var})"


def write_session(data):
    """Write this session's binding, or remove it when it holds nothing."""
    var, value, _ = session_key()
    if not value:
        raise ProfileError("no session id found (Claude, Codex, Antigravity or ORCA_PANE_KEY); launch with ODD_PROFILE instead")
    path = session_file(value)
    data = {k: v for k, v in data.items() if k in ("profile", "mode") and v}
    if not data:
        if os.path.exists(path):
            os.unlink(path)
        return var
    write_json_atomic(path, {**data, "key": var, "updated_at": int(time.time())})
    return var


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


def env_mode():
    """Return (mode, source) from ODD_ORCHESTRATOR_MODE, or None when it is unset or blank."""
    env = os.environ.get(MODE_ENV, "").strip()
    if not env:
        return None
    if env not in MODES:
        raise ProfileError(f"{MODE_ENV}: unknown mode '{env}' (known: {', '.join(MODES)})")
    return env, f"env {MODE_ENV}"


def resolve_mode(doc, name):
    """Return (mode, source) of the orchestrator mode for the selected profile name.

    Order: the ODD_ORCHESTRATOR_MODE override, this session's `session-mode`,
    the profile's `workflow` entry, then organic. An unknown value fails rather
    than falling back, so a typo never silently runs the other mode.
    """
    env = env_mode()
    if env:
        return env
    data, var = read_session()
    if data.get("mode"):
        return data["mode"], f"session ({var})"
    entry = doc["workflow"].get(name) if name else None
    if entry and "orchestratorMode" in entry:
        return entry["orchestratorMode"], f"profile {name}"
    return DEFAULT_MODE, "default"


def mode_reference(mode):
    return f"references/mode-{mode}.md"


def mode_line(doc, name):
    mode, source = resolve_mode(doc, name)
    return f"mode: {mode} ({source}); rules: {mode_reference(mode)}"


def shell_quote(value):
    """Single-quote a value for a POSIX shell, always, so the command reads the same everywhere."""
    return "'" + value.replace("'", "'\\''") + "'"


def terminal_command(agent, model, effort):
    """Command for `orca terminal create` when the agent cannot use `worker-start --agent`.

    Codex started by `worker-start --agent codex` runs in a sandbox that blocks the
    connection to Orca, so its worker could never report; scripts/codex-worker.sh
    pins the workspace-write sandbox and the network override that lets it reach Orca.
    """
    if agent != "codex":
        return None
    args = [shell_quote(arg) for arg in (model, effort) if arg]
    return " ".join(["sh", shell_quote(CODEX_LAUNCHER)] + args)


# Agents whose CLI Orca can start in a split pane with --model and --effort flags.
SPLIT_CLIS = {"claude": "claude", "antigravity": "agy"}


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
    command = terminal_command(agent, entry.get("model"), entry.get("effort") if entry.get("model") else None)
    split_command = command
    if agent in SPLIT_CLIS:
        split_command = SPLIT_CLIS[agent]
        if entry.get("model"):
            split_command += f" --model {shell_quote(entry['model'])}"
            if entry.get("effort"):
                split_command += f" --effort {shell_quote(entry['effort'])}"
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
        "launch": "terminal" if command else "worker-start",
        "terminal_command": command,
        "orca_terminal": orca_terminal(),
        "split_command": split_command,
    }


def cmd_resolve(args):
    result = resolve_role(load_profiles(), args.role)
    if args.json:
        print(json.dumps(result))
    else:
        print(result["notice"])
        print(" ".join(result["flags"]))
        if result["terminal_command"]:
            print(f"launch: terminal ({result['terminal_command']})")


def cmd_use(args):
    doc = load_profiles()
    if args.name not in doc["profiles"]:
        known = ", ".join(sorted(doc["profiles"])) or "none"
        raise ProfileError(f"profile '{args.name}' is not defined in {doc['path']} (known: {known})")
    # Binding a profile drops a session mode override, so the new profile's own mode applies.
    var = write_session({"profile": args.name})
    note = " (bound to the Orca pane, not the conversation)" if var == "ORCA_PANE_KEY" else ""
    print(f"profile: {args.name} bound to this session via {var}{note}")
    print(mode_line(doc, args.name))


def cmd_session_mode(args):
    doc = load_profiles()
    if not session_key()[1]:
        raise ProfileError("no session id found (Claude, Codex, Antigravity or ORCA_PANE_KEY); launch with ODD_ORCHESTRATOR_MODE instead")
    data, _ = read_session()
    var = write_session({**data, "mode": args.mode})
    note = " (bound to the Orca pane, not the conversation)" if var == "ORCA_PANE_KEY" else ""
    print(f"mode: {args.mode} bound to this session via {var}{note}")
    name, _ = selected_profile(doc)
    print(mode_line(doc, name))


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
        mode = doc["workflow"].get(name, {}).get("orchestratorMode", DEFAULT_MODE)
        print(f"{name}{marker}: {', '.join(sorted(doc['profiles'][name])) or 'no roles'} | mode: {mode}")


def cmd_show(_args):
    doc = load_profiles()
    var, _, _ = session_key()
    name, source = selected_profile(doc)
    print(f"profile: {name or 'none'} ({source}); session key: {var or 'none'}; agent: {current_agent() or 'unknown'}")
    print(mode_line(doc, name))
    for role in BASE_ROLES:
        try:
            print("  " + resolve_role(doc, role)["notice"].split(" | ", 1)[1])
        except ProfileError as exc:
            print(f"  {role} -> error: {exc}")
    print(orca_line(resolve_mode(doc, name)[0]))


def cmd_mode(args):
    # The override is the first source, so it answers even when the profiles file is invalid.
    override = env_mode()
    if override:
        mode, source = override
        try:
            name, _ = selected_profile(load_profiles())
        except ProfileError:
            name = None  # an invalid file must not hide the override
    else:
        doc = load_profiles()
        name, _ = selected_profile(doc)
        mode, source = resolve_mode(doc, name)
    if args.json:
        print(json.dumps({"mode": mode, "source": source, "profile": name, "rules": mode_reference(mode)}))
    else:
        print(f"mode: {mode} ({source}); rules: {mode_reference(mode)}")


def orca_agents():
    """Agent ids Orca reports as installed, in Orca's order."""
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
    return [item["id"] for item in items if isinstance(item, dict) and item.get("id")]


def cmd_check(_args):
    doc = load_profiles()
    installed = set(orca_agents())
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


def codex_models():
    """Listed models and their efforts from Codex's own models cache, or None if unreadable."""
    path = os.path.join(
        os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex"),
        "models_cache.json",
    )
    try:
        with open(path, encoding="utf-8") as handle:
            cache = json.load(handle)
    except (OSError, ValueError):
        return None
    models = cache.get("models") if isinstance(cache, dict) else None
    if not isinstance(models, list):
        return None
    result = []
    for model in models:
        if not isinstance(model, dict) or not isinstance(model.get("slug"), str) or not model["slug"]:
            continue
        if model.get("visibility", "list") != "list":
            continue
        levels = model.get("supported_reasoning_levels")
        efforts = [level["effort"] for level in levels if isinstance(level, dict)
                   and isinstance(level.get("effort"), str) and level["effort"]] if isinstance(levels, list) else []
        result.append({"id": model["slug"], "efforts": efforts})
    return result


def discover():
    """Agents Orca can launch and the models each one is known to accept.

    `verified` is true when the models come from the agent's own data, false for the
    built-in Claude list, and null when there is no source at all.
    """
    result = {"agents": []}
    try:
        agents = orca_agents()
    except ProfileError as exc:
        result["orca_error"] = str(exc)
        agents = []
    for agent in agents:
        entry = {"id": agent, "models": [], "verified": None, "source": None}
        if agent == "codex":
            models = codex_models()
            if models is not None:
                entry.update(models=models, verified=True, source="codex models cache")
        elif agent == "claude":
            entry.update(
                models=[{"id": model, "efforts": list(CLAUDE_EFFORTS)} for model in CLAUDE_MODELS],
                verified=False, source="built-in list",
            )
        result["agents"].append(entry)
    return result


def cmd_discover(args):
    result = discover()
    if args.json:
        print(json.dumps(result))
        return
    if "orca_error" in result:
        print(f"Orca agents unavailable: {result['orca_error']}")
    for agent in result["agents"]:
        if not agent["models"]:
            print(f"{agent['id']}: agent default model only (no model list found)")
            continue
        models = ", ".join(
            f"{model['id']} ({', '.join(model['efforts'])})" if model["efforts"] else model["id"]
            for model in agent["models"]
        )
        state = "verified" if agent["verified"] else "unverified"
        print(f"{agent['id']}: {models} [{state}: {agent['source']}]")


def inline(value):
    """One-line JSON for a role entry, in the `{ "agent": "x" }` style of a hand-written file."""
    if isinstance(value, dict) and value:
        return "{ " + ", ".join(f"{dumps(k)}: {dumps(v)}" for k, v in value.items()) + " }"
    return dumps(value)


def dumps(value, **kwargs):
    """JSON text that keeps non-ASCII characters as written, so diffs show only real changes."""
    return json.dumps(value, ensure_ascii=False, **kwargs)


def format_doc(doc):
    """Serialize the profile document with one line per role, so diffs show only real changes."""
    lines = ["{"]
    items = list(doc.items())
    for i, (key, value) in enumerate(items):
        comma = "," if i < len(items) - 1 else ""
        if key == "workflow" and isinstance(value, dict) and value:
            lines.append('  "workflow": {')
            entries = list(value.items())
            for k, (name, entry) in enumerate(entries):
                wcomma = "," if k < len(entries) - 1 else ""
                lines.append(f"    {dumps(name)}: {inline(entry)}{wcomma}")
            lines.append(f"  }}{comma}")
            continue
        if key != "profiles" or not isinstance(value, dict) or not value:
            body = dumps(value, indent=2).replace("\n", "\n  ")
            lines.append(f"  {dumps(key)}: {body}{comma}")
            continue
        lines.append('  "profiles": {')
        profiles = list(value.items())
        for j, (name, roles) in enumerate(profiles):
            pcomma = "," if j < len(profiles) - 1 else ""
            if not isinstance(roles, dict) or not roles:
                lines.append(f"    {dumps(name)}: {inline(roles)}{pcomma}")
                continue
            lines.append(f"    {dumps(name)}: {{")
            entries = list(roles.items())
            for k, (role, entry) in enumerate(entries):
                rcomma = "," if k < len(entries) - 1 else ""
                lines.append(f"      {dumps(role)}: {inline(entry)}{rcomma}")
            lines.append(f"    }}{pcomma}")
        lines.append(f"  }}{comma}")
    lines.append("}")
    return "\n".join(lines) + "\n"


def write_text_atomic(path, text):
    """Replace a user-owned file atomically: follow a symlink to its target, keep its mode."""
    target = os.path.realpath(path)
    try:
        mode = os.stat(target).st_mode & 0o7777
    except FileNotFoundError:
        mode = 0o644
    tmp = None
    try:
        os.makedirs(os.path.dirname(target), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target), prefix=".tmp-")
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, target)
    except OSError as exc:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)
        raise ProfileError(f"cannot write {target}: {exc}") from exc


def write_profiles(text_before, doc, yes):
    """Validate doc, print the diff against the current file, and write it only with yes."""
    path = profiles_path()
    validate_doc(doc, path)
    after = format_doc(doc)
    if json.loads(after) != doc:
        raise ProfileError("internal error: formatted profiles do not round-trip; nothing written")
    diff = "".join(difflib.unified_diff(
        text_before.splitlines(keepends=True), after.splitlines(keepends=True),
        fromfile=path, tofile=path,
    ))
    if not diff:
        print("no changes")
        return False
    print(diff, end="" if diff.endswith("\n") else "\n")
    if not yes:
        print("dry run: nothing written; re-run with --yes to write")
        return False
    write_text_atomic(path, after)
    return True


def cmd_save(args):
    try:
        with open(args.roles_file, encoding="utf-8") as handle:
            roles = json.load(handle)
    except (OSError, ValueError) as exc:  # ValueError covers bad JSON and non-UTF-8 bytes
        raise ProfileError(f"{args.roles_file}: cannot read roles: {exc}") from exc
    if not isinstance(roles, dict):
        raise ProfileError(f"{args.roles_file}: roles must be an object of role -> entry")
    text, doc = read_raw()
    doc = doc if doc is not None else {"profiles": {}}
    if not isinstance(doc, dict) or not isinstance(doc.get("profiles", {}), dict):
        validate_doc(doc, profiles_path())
    doc.setdefault("profiles", {})
    if args.name in doc["profiles"] and not args.replace:
        raise ProfileError(f"profile '{args.name}' already exists; pass --replace to overwrite it")
    doc["profiles"][args.name] = roles
    if write_profiles(text, doc, args.yes):
        print(f"profile '{args.name}' saved to {profiles_path()}")


def cmd_default(args):
    text, doc = read_raw()
    view = validate_doc(doc, profiles_path()) if doc is not None else {"profiles": {}}
    if args.name not in view["profiles"]:
        known = ", ".join(sorted(view["profiles"])) or "none"
        raise ProfileError(f"profile '{args.name}' is not defined in {profiles_path()} (known: {known})")
    if view["default"] == args.name:
        print(f"'{args.name}' is already the default profile; nothing written")
        return
    if "default" in doc:
        doc["default"] = args.name
    else:
        doc = {"default": args.name, **doc}
    if write_profiles(text, doc, args.yes):
        print(f"default profile: {args.name}")


def cmd_set_mode(args):
    text, doc = read_raw()
    view = validate_doc(doc, profiles_path()) if doc is not None else {"profiles": {}, "workflow": {}}
    if args.name not in view["profiles"]:
        known = ", ".join(sorted(view["profiles"])) or "none"
        raise ProfileError(f"profile '{args.name}' is not defined in {profiles_path()} (known: {known})")
    current = view["workflow"].get(args.name, {}).get("orchestratorMode", DEFAULT_MODE)
    if current == args.mode:
        print(f"profile '{args.name}' is already {args.mode}; nothing written")
        return
    workflow = {k: dict(v) for k, v in view["workflow"].items()}
    if args.mode == DEFAULT_MODE:
        # Organic is the default: drop the entry instead of writing it, and an empty map with it.
        entry = workflow.pop(args.name, {})
        entry.pop("orchestratorMode", None)
        if entry:
            workflow[args.name] = entry
    else:
        workflow.setdefault(args.name, {})["orchestratorMode"] = args.mode
    # Keep the map in the profiles' order so the diff stays stable.
    ordered = {name: workflow[name] for name in view["profiles"] if name in workflow}
    if ordered:
        doc["workflow"] = ordered
    else:
        doc.pop("workflow", None)
    if write_profiles(text, doc, args.yes):
        print(f"profile '{args.name}' mode: {args.mode}")


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
    disc = sub.add_parser("discover", help="list Orca agents and the models each one accepts")
    disc.add_argument("--json", action="store_true")
    disc.set_defaults(func=cmd_discover)
    save = sub.add_parser("save", help="add or replace a profile (dry run unless --yes)")
    save.add_argument("name")
    save.add_argument("--roles-file", required=True, help="JSON object of role -> {agent, model, effort}")
    save.add_argument("--replace", action="store_true", help="overwrite an existing profile")
    save.add_argument("--yes", action="store_true", help="write the file instead of a dry run")
    save.set_defaults(func=cmd_save)
    default = sub.add_parser("default", help="set the file's default profile (dry run unless --yes)")
    default.add_argument("name")
    default.add_argument("--yes", action="store_true", help="write the file instead of a dry run")
    default.set_defaults(func=cmd_default)
    mode = sub.add_parser("mode", help="show the orchestrator mode that applies to this session")
    mode.add_argument("--json", action="store_true")
    mode.set_defaults(func=cmd_mode)
    set_mode = sub.add_parser("set-mode", help="set a profile's orchestrator mode (dry run unless --yes)")
    set_mode.add_argument("name")
    set_mode.add_argument("mode", choices=MODES)
    set_mode.add_argument("--yes", action="store_true", help="write the file instead of a dry run")
    set_mode.set_defaults(func=cmd_set_mode)
    session_mode = sub.add_parser("session-mode", help="set the orchestrator mode for this session only")
    session_mode.add_argument("mode", choices=MODES)
    session_mode.set_defaults(func=cmd_session_mode)
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
