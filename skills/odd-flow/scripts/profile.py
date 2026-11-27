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
from contextlib import ExitStack, contextmanager, nullcontext
import difflib
import errno
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time

BASE_ROLES = ("explore", "write", "verify", "review", "refute")
LENSES = ("risk", "resilience", "readability", "reliability")
ROLES = BASE_ROLES + tuple(f"review-{lens}" for lens in LENSES) + ("review-second",)
ENTRY_FIELDS = ("agent", "model", "effort")
MODES = ("organic", "full-delegation")
DEFAULT_MODE = "organic"
MODE_ENV = "ODD_ORCHESTRATOR_MODE"
WORKFLOW_FIELDS = ("orchestratorMode",)
# Claude Code exposes no model list; these ids are suggestions, reported as unverified.
CLAUDE_MODELS = ("claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5")
CLAUDE_EFFORTS = ("low", "medium", "high", "xhigh", "max")
ORCA_HANDLE_RE = re.compile(r"[A-Za-z0-9_:.-]{1,200}")
RECORD_NAME_RE = re.compile(r"[0-9a-f]{64}")
CODEX_LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "codex-worker.sh")
CODEX_LAUNCHER_WINDOWS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "codex-worker.ps1")
CLAUDE_WORKER_SETTINGS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "claude-worker-settings.json")

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


def _state_path_error(exc, path):
    return OSError(exc.errno, exc.strerror, str(path))


def remove_session_file(path, *, dir_fd=None, label="session binding"):
    """Remove a state file; return False if missing, raise ProfileError on failure."""
    if os.name == "nt" and dir_fd is not None:
        return _remove_pinned_windows_file(path, dir_fd[path], label)
    try:
        os.unlink(os.path.basename(path) if dir_fd is not None else path, dir_fd=dir_fd)
    except FileNotFoundError:
        return False
    except OSError as exc:
        detail = _state_path_error(exc, path) if dir_fd is not None else exc
        raise ProfileError(f"{path}: cannot remove {label}: {detail}") from exc
    return True


def read_raw():
    """Return (text, document) of the profiles file; ("", None) when it does not exist."""
    path = profiles_path()
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError:
        return "", None
    except OSError as exc:
        raise ProfileError(f"{path}: cannot read profiles: {exc}") from exc
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
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return {}, var
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
        remove_session_file(path)
        return var
    try:
        write_json_atomic(path, {**data, "key": var, "updated_at": int(time.time())})
    except OSError as exc:
        raise ProfileError(f"cannot write session binding: {exc}") from exc
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
    """Single-quote a value for the shell of an Orca terminal, always, so the command reads the same everywhere.

    Orca terminals run PowerShell on Windows and a POSIX shell elsewhere.
    """
    if sys.platform == "win32":
        # PowerShell also ends a single-quoted string at a typographic single quote.
        return "'" + re.sub("['\u2018\u2019\u201a\u201b]", lambda m: m.group() * 2, value) + "'"
    return "'" + value.replace("'", "'\\''") + "'"


def launch_arg(label, value):
    """Quote a model or effort for a launch command, refusing on Windows what cannot pass intact.

    Windows rebuilds a command line for each native program, and Windows PowerShell 5.1
    neither escapes an embedded '"' nor keeps a trailing '\\' from escaping the closing
    quote, so such a value could add flags to the worker or swallow the ones after it.
    """
    if sys.platform == "win32" and re.search(r'["\\\s]', value):
        raise ProfileError(
            f"{label} {value!r} must not contain a double quote, a backslash or whitespace on Windows"
        )
    return shell_quote(value)


def terminal_command(agent, model, effort):
    """Command for `orca terminal create` when the agent cannot use `worker-start --agent`.

    Codex started by `worker-start --agent codex` runs in a sandbox that blocks the
    connection to Orca, so its worker could never report; scripts/codex-worker.sh
    pins workspace-write; codex-worker.ps1 selects it with --approve-for-me on
    Windows. Both set the network override that lets it reach Orca.
    """
    if agent != "codex":
        return None
    args = [launch_arg(label, arg) for label, arg in (("model", model), ("effort", effort)) if arg]
    if sys.platform == "win32":
        # Windows clients refuse every script by default, and RemoteSigned refuses
        # one extracted from a downloaded archive.
        launcher = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]
        return " ".join(launcher + [shell_quote(CODEX_LAUNCHER_WINDOWS)] + args)
    return " ".join(["sh", shell_quote(CODEX_LAUNCHER)] + args)


# Agents whose CLI Orca can start in a split pane with --model and --effort flags.
SPLIT_CLIS = {"claude": "claude", "antigravity": "agy"}


def resolve_role(doc, role, *, selection=None):
    if role not in ROLES:
        raise ProfileError(f"unknown role '{role}' (known: {', '.join(ROLES)})")
    name, source = selected_profile(doc) if selection is None else selection
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
            split_command += f" --model {launch_arg('model', entry['model'])}"
            if entry.get("effort"):
                split_command += f" --effort {launch_arg('effort', entry['effort'])}"
        if agent == "claude":
            split_command += f" --settings {shell_quote(CLAUDE_WORKER_SETTINGS)}"
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
    if remove_session_file(path):
        print(f"session binding removed ({var})")
    else:
        print("no session binding for this session")


def cmd_list(args):
    doc = load_profiles()
    if not args.json and not doc["exists"]:
        print(f"no profiles file at {doc['path']}; every role uses the current agent and its own model")
        return
    profiles = []
    for name in sorted(doc["profiles"]):
        profiles.append({
            "name": name,
            "default": name == doc["default"],
            "mode": doc["workflow"].get(name, {}).get("orchestratorMode", DEFAULT_MODE),
            "roles": doc["profiles"][name],
        })
    if args.json:
        print(json.dumps({
            "path": doc["path"] if doc["exists"] else None,
            "default": doc["default"],
            "profiles": profiles,
        }))
    else:
        for profile in profiles:
            marker = " (default)" if profile["default"] else ""
            roles = ", ".join(sorted(profile["roles"])) or "no roles"
            print(f"{profile['name']}{marker}: {roles} | mode: {profile['mode']}")


def cmd_show(args):
    doc = load_profiles()
    var, _, _ = session_key()
    name, source = selected_profile(doc)
    if args.json:
        mode, mode_source = resolve_mode(doc, name)
        roles = {}
        for role in BASE_ROLES:
            entry = resolve_role(doc, role, selection=(name, source))
            roles[role] = {field: entry[field] for field in ENTRY_FIELDS}
        print(json.dumps({
            "profile": name,
            "source": source,
            "session_key": var,
            "agent": current_agent(),
            "mode": mode,
            "mode_source": mode_source,
            "rules": mode_reference(mode),
            "roles": roles,
            "orca_terminal": orca_terminal(),
        }))
        return
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
            capture_output=True, timeout=30, check=True,
        ).stdout
        # A Windows subprocess reader thread cannot propagate decoding errors.
        data = json.loads(out.decode("utf-8"))
    except (OSError, subprocess.SubprocessError, UnicodeDecodeError, json.JSONDecodeError) as exc:
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


def _win32():
    """Return kernel32 with the handle functions that Windows state cleanup requires."""
    try:
        import ctypes
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateFileW.argtypes = [
            wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
            wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
        ]
        kernel32.CreateFileW.restype = wintypes.HANDLE
        kernel32.GetFileInformationByHandle.argtypes = [wintypes.HANDLE, ctypes.c_void_p]
        kernel32.GetFileInformationByHandle.restype = wintypes.BOOL
        kernel32.SetFileInformationByHandle.argtypes = [
            wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD,
        ]
        kernel32.SetFileInformationByHandle.restype = wintypes.BOOL
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel32.CloseHandle.restype = wintypes.BOOL
    except (ImportError, OSError, AttributeError) as exc:
        raise ProfileError(f"state cleanup requires Windows Win32 handle support: {exc}") from exc
    return kernel32


@contextmanager
def _windows_handle(path, access, share, flags, disposition=3):  # 3: OPEN_EXISTING
    """Yield (kernel32, handle) for path; raise OSError when it cannot be opened."""
    kernel32 = _win32()
    import ctypes

    handle = kernel32.CreateFileW(str(path), access, share, None, disposition, flags, None)
    if handle == ctypes.c_void_p(-1).value:  # INVALID_HANDLE_VALUE
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        yield kernel32, handle
    finally:
        kernel32.CloseHandle(handle)


def _windows_file_info(kernel32, handle):
    import ctypes
    from ctypes import wintypes

    class ByHandleFileInformation(ctypes.Structure):
        _fields_ = [
            ("dwFileAttributes", wintypes.DWORD), ("ftCreationTime", wintypes.FILETIME),
            ("ftLastAccessTime", wintypes.FILETIME), ("ftLastWriteTime", wintypes.FILETIME),
            ("dwVolumeSerialNumber", wintypes.DWORD), ("nFileSizeHigh", wintypes.DWORD),
            ("nFileSizeLow", wintypes.DWORD), ("nNumberOfLinks", wintypes.DWORD),
            ("nFileIndexHigh", wintypes.DWORD), ("nFileIndexLow", wintypes.DWORD),
        ]

    info = ByHandleFileInformation()
    if not kernel32.GetFileInformationByHandle(handle, ctypes.byref(info)):
        raise ctypes.WinError(ctypes.get_last_error())
    return info


def _windows_file_id(info):
    return info.dwVolumeSerialNumber, info.nFileIndexHigh, info.nFileIndexLow


def _is_reparse_point(info):
    """True for an lstat result of a symlink, junction or other Windows reparse point."""
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_file_attributes", 0) & 0x0400)


def _pin_windows_chain(pins, base, parts):
    """Hold a handle on base and each part; False when one is missing or a reparse point."""
    path = base
    for part in (None, *parts):
        if part is None:
            # FILE_READ_ATTRIBUTES | SYNCHRONIZE; BACKUP_SEMANTICS follows the configured base.
            access, flags = 0x00100080, 0x02000000
        else:
            path /= part
            # Windows ignores the share mode of an attribute-only handle: FILE_LIST_DIRECTORY
            # makes the missing FILE_SHARE_DELETE block renaming or removing the directory.
            # OPEN_REPARSE_POINT opens a junction itself instead of its target.
            access, flags = 0x00100081, 0x02200000
        # A base failure names the requested state directory, as on POSIX.
        target = base.joinpath(*parts) if part is None else path
        try:
            # FILE_SHARE_READ | FILE_SHARE_WRITE
            kernel32, handle = pins.enter_context(_windows_handle(path, access, 0x3, flags))
            info = _windows_file_info(kernel32, handle)
        except FileNotFoundError:
            return False
        except OSError as exc:
            raise _state_path_error(exc, target) from exc
        if part is not None and info.dwFileAttributes & 0x0400:  # FILE_ATTRIBUTE_REPARSE_POINT
            return False
        if not info.dwFileAttributes & 0x10:  # FILE_ATTRIBUTE_DIRECTORY
            error = NotADirectoryError(errno.ENOTDIR, os.strerror(errno.ENOTDIR))
            raise _state_path_error(error, target)
    return True


def _windows_scanned_id(path):
    # An attribute-only open succeeds even while another process holds the file exclusively.
    # FILE_READ_ATTRIBUTES, sharing everything, without following a reparse point.
    with _windows_handle(path, 0x80, 0x7, 0x02200000) as (kernel32, handle):
        return _windows_file_id(_windows_file_info(kernel32, handle))


def _remove_pinned_windows_file(path, scanned_id, label):
    try:
        # DELETE | FILE_READ_ATTRIBUTES, sharing everything, without following a reparse point.
        with _windows_handle(path, 0x00010080, 0x7, 0x00200000) as (kernel32, handle):
            import ctypes

            info = _windows_file_info(kernel32, handle)
            # 0x0410: reparse point or directory.
            if info.dwFileAttributes & 0x0410 or _windows_file_id(info) != scanned_id:
                raise ProfileError(f"{path}: cannot remove {label}: it changed since it was scanned")
            delete = ctypes.c_ubyte(1)  # FILE_DISPOSITION_INFO.DeleteFile
            if not kernel32.SetFileInformationByHandle(  # 4: FileDispositionInfo
                    handle, 4, ctypes.byref(delete), ctypes.sizeof(delete)):
                raise ctypes.WinError(ctypes.get_last_error())
    except FileNotFoundError:
        return False
    except OSError as exc:
        detail = _state_path_error(exc, path)
        raise ProfileError(f"{path}: cannot remove {label}: {detail}") from exc
    return True


@contextmanager
def _open_state_dir(base, *parts):
    """Follow the configured base, but not symlinks inside odd-flow state.

    Yield None for a missing or linked directory. Otherwise yield a directory
    descriptor or, on Windows, where the whole chain stays pinned, a dict that
    collects the IDs of the scanned files.
    """
    if os.name == "nt":
        with ExitStack() as pins:
            if _pin_windows_chain(pins, base, parts):
                yield {}
                return
        yield None
        return
    flags = os.O_RDONLY | os.O_DIRECTORY
    try:
        fd = os.open(base, flags)
    except FileNotFoundError:
        yield None
        return
    except OSError as exc:
        raise _state_path_error(exc, base.joinpath(*parts)) from exc
    try:
        path = base
        for part in parts:
            path /= part
            try:
                child = None if stat.S_ISLNK(os.lstat(part, dir_fd=fd).st_mode) else os.open(
                    part, flags | os.O_NOFOLLOW, dir_fd=fd
                )
            except FileNotFoundError:
                child = None
            except OSError as exc:
                raise _state_path_error(exc, path) from exc
            if child is None:
                yield None
                return
            os.close(fd)
            fd = child
        yield fd
    finally:
        os.close(fd)


def _record_state_error(errors, message, cause):
    error = ProfileError(message)
    if errors is None:
        raise error from cause
    errors.append(error)


def discover_plugin_data_dirs(*, errors=None):
    """Yield real odd-flow plugin data directories from installed runtime layouts."""
    home = Path.home()
    claude_config = os.environ.get("CLAUDE_CONFIG_DIR")
    codex_config = Path(os.environ.get("CODEX_HOME") or home / ".codex")
    roots = [home / ".claude", codex_config]
    if claude_config:
        roots.insert(0, Path(claude_config))
    roots = [(root.absolute() / "plugins/data", False) for root in roots]
    roots.append((home.absolute() / ".gemini/antigravity-cli/plugin_data", True))
    found = set()
    for root, antigravity in dict.fromkeys(roots):
        try:
            with _open_state_dir(root) as fd:
                if fd is None:
                    continue
                reported_lookup_error = False
                windows = os.name == "nt"
                for entry in os.listdir(root if windows else fd):
                    if not (entry == "odd-flow" if antigravity else entry.startswith("odd-flow-")):
                        continue
                    try:
                        info = os.lstat(root / entry) if windows else os.lstat(entry, dir_fd=fd)
                    except FileNotFoundError:
                        continue
                    except OSError as exc:
                        if not reported_lookup_error:
                            detail = _state_path_error(exc, root)
                            _record_state_error(errors, f"{root}: cannot discover plugin data: {detail}", exc)
                            reported_lookup_error = True
                        continue
                    identity = info.st_dev, info.st_ino
                    if windows:
                        if _is_reparse_point(info):
                            continue
                        # Without a file ID, aliases of one directory cannot be told apart.
                        if stat.S_ISDIR(info.st_mode) and not info.st_ino:
                            message = f"{root / entry}: cannot discover plugin data: no file ID"
                            _record_state_error(errors, message, None)
                            continue
                    if stat.S_ISDIR(info.st_mode) and identity not in found:
                        found.add(identity)
                        yield root / entry
        except NotADirectoryError:
            continue
        except OSError as exc:
            path = root / exc.filename if exc.filename else root
            detail = _state_path_error(exc, path)
            _record_state_error(errors, f"{root}: cannot discover plugin data: {detail}", exc)


def _state_folders(data_dirs):
    yield "session_bindings", Path(home_dir()), ("sessions",), "session binding"
    for data_dir in data_dirs:
        data_dir = Path(data_dir)
        yield "prompt_sessions", data_dir.parent, (data_dir.name, "prompt-sessions"), "prompt-hook record"
        yield "session_modes", data_dir.parent, (data_dir.name, "session-modes"), "mode-notice record"


def _list_state_files(fd, folder, label, cutoff, errors, deadline):
    windows = os.name == "nt"
    source = folder if windows else fd
    try:
        # Automatic cleanup must not enumerate an entire directory before checking the deadline.
        listing = nullcontext(os.listdir(source)) if deadline is None else os.scandir(source)
    except OSError as exc:
        detail = _state_path_error(exc, folder)
        raise ProfileError(f"{folder}: cannot read {label}s: {detail}") from exc
    with listing as entries:
        for item in entries:
            if deadline is not None and time.monotonic() >= deadline:
                return
            entry = item if deadline is None else item.name
            if not (entry.endswith(".json") if label == "session binding" else RECORD_NAME_RE.fullmatch(entry)):
                continue
            path = folder / entry
            try:
                if windows:
                    # Read before lstat: a file replaced in between then fails the age check
                    # or no longer matches this ID at deletion.
                    scanned_id = _windows_scanned_id(path)
                    info = os.lstat(path)
                else:
                    info = os.lstat(entry, dir_fd=fd)
            except FileNotFoundError:
                continue
            except OSError as exc:
                detail = _state_path_error(exc, path)
                _record_state_error(errors, f"{path}: cannot inspect {label}: {detail}", exc)
                continue
            if windows and _is_reparse_point(info):
                continue
            if stat.S_ISREG(info.st_mode) and (cutoff is None or info.st_mtime < cutoff):
                if deadline is not None and time.monotonic() >= deadline:
                    return
                if windows:
                    fd[path] = scanned_id
                yield path


def _scan_session_state(data_dirs, cutoff, *, remove, errors=None, deadline=None):
    result = {key: [] for key in ("session_bindings", "prompt_sessions", "session_modes")}
    bindings_found = False
    for key, base, parts, label in _state_folders(data_dirs):
        if deadline is not None and time.monotonic() >= deadline:
            break
        folder = base.joinpath(*parts)
        try:
            with _open_state_dir(base, *parts) as fd:
                if fd is None:
                    continue
                if key == "session_bindings":
                    bindings_found = True
                for path in _list_state_files(fd, folder, label, cutoff, errors, deadline):
                    if remove:
                        try:
                            if not remove_session_file(path, dir_fd=fd, label=label):
                                continue
                        except ProfileError as exc:
                            errors.append(exc)
                            continue
                    result[key].append(path)
        except OSError as exc:
            _record_state_error(errors, f"{folder}: cannot read {label}s: {exc}", exc)
        except ProfileError as exc:
            if errors is None:
                raise
            errors.append(exc)
    return result, bindings_found


def list_session_state(data_dirs, *, cutoff=None):
    """List regular state files per category without removing them; cutoff is an mtime."""
    return _scan_session_state(data_dirs, cutoff, remove=False)[0]


def prune_session_state(data_dirs, cutoff, *, errors=None, deadline=None):
    """Return removed counts, optionally collecting failures or stopping at a monotonic deadline."""
    if errors is None:
        errors = []
    removed, bindings_found = _scan_session_state(
        data_dirs, cutoff, remove=True, errors=errors, deadline=deadline,
    )
    counts = {key: len(paths) for key, paths in removed.items()}
    if not bindings_found:
        counts["session_bindings"] = None
    return counts


def cmd_prune(args):
    if os.name == "nt":
        _win32()
    # Older Python versions advertise lstat's dir_fd support under stat.
    elif (not hasattr(os, "O_DIRECTORY")
            or not {os.open, os.stat, os.unlink} <= os.supports_dir_fd
            or os.listdir not in os.supports_fd):
        raise ProfileError("prune requires O_DIRECTORY and directory file descriptor support")
    cutoff = time.time() - args.days * 86400
    errors = []
    counts = prune_session_state(discover_plugin_data_dirs(errors=errors), cutoff, errors=errors)
    suffix = f"older than {args.days} days"
    bindings = counts["session_bindings"]
    if bindings is None and not errors:
        print("no session bindings")
    else:
        print(f"removed {bindings or 0} session binding(s) {suffix}")
    print(f"removed {counts['prompt_sessions']} prompt-hook record(s) {suffix}")
    print(f"removed {counts['session_modes']} mode-notice record(s) {suffix}", flush=bool(errors))
    if errors:
        for error in errors:
            print(f"odd-flow: {error}", file=sys.stderr)
        return 2


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
    listing = sub.add_parser("list", help="list profiles")
    listing.add_argument("--json", action="store_true")
    listing.set_defaults(func=cmd_list)
    show = sub.add_parser("show", help="show the active profile and every role")
    show.add_argument("--json", action="store_true")
    show.set_defaults(func=cmd_show)
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
    prune = sub.add_parser("prune", help="remove old session bindings and hook records")
    prune.add_argument("--days", type=int, default=30)
    prune.set_defaults(func=cmd_prune)
    args = parser.parse_args(argv)
    try:
        return args.func(args) or 0
    except ProfileError as exc:
        print(f"odd-flow: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
