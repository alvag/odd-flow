#!/usr/bin/env python3
"""Check writer launches and full-delegation parent edits in Claude Code, Codex and Antigravity."""

import glob
import importlib.util
import json
import os
from pathlib import Path
import re
import sys

CODEX = sys.argv[1:] == ["--runtime", "codex"]
ANTIGRAVITY = sys.argv[1:] == ["--runtime", "antigravity"]
ROOT_VAR = "PLUGIN_ROOT" if CODEX else "CLAUDE_PLUGIN_ROOT"
# Antigravity is rooted relative to this script, so inherited root variables cannot redirect it.
PLUGIN_ROOT = Path((None if ANTIGRAVITY else os.environ.get(ROOT_VAR)) or Path(__file__).resolve().parents[1])
SURFACE_SCRIPT = PLUGIN_ROOT / "skills" / "odd-flow" / "scripts" / "surface.py"
EDIT_PATH_FIELDS = {"Edit": "file_path", "Write": "file_path", "NotebookEdit": "notebook_path"}
LAUNCHES = {"task-create", "worker-start"}
RAW_LAUNCH = re.compile(r"(?<![\w-])orchestration(?:\s|\\\n)+(?:task-create|worker-start)(?![\w-])")
SPEC_FLAGS = {"--spec", "--spec-file", "--task"}
VALUE_FLAGS = {
    "--agent", "--base-branch", "--comment", "--deps", "--display-name", "--effort",
    "--environment", "--for", "--from", "--item", "--model", "--name", "--on",
    "--pairing-code", "--parent", "--repo", "--retry-of", "--retry-request", "--run",
    "--setup", "--task-title", "--terminal", "--timeout-ms", "--worktree",
}

# Tokenize the literal launch forms, not the evaluated shell program. Keep quoted
# operators and newlines inside their words, and never run a command to find a spec.
WORD_FRAGMENT = re.compile(r"""(?:'[^']*'|\\[\s\S]|[^\s;&|()<>'"`\\])+|""" r'"')
SHELL_TOKEN = re.compile(
    r"""(?P<space>[ \t]+|\\\n)|(?P<comment>\#[^\n]*)|"""
    r"""(?P<redirect>[0-9]*(?:<<<|<<-?|<>|>>|>&|<&|>\||[<>]))|(?P<operator>[\n;&|()`])|"""
    rf"(?P<word>{WORD_FRAGMENT.pattern})"
)
WORD_PART = re.compile(r"""'[^']*'|"(?:\\[\s\S]|[^"\\])*"|\\[\s\S]|[^'"\\]+""")
DOUBLE_QUOTE_PART = re.compile(r"\\[$`\"\\\n]|(?P<expansion>[$`])")
QUOTED_FRAGMENT = re.compile(r'\\[\s\S]|\$\(|"|[^"\\$]+|\$')
POWERSHELL_TOKEN = re.compile(
    r"(?P<space>[ \t]+)|(?P<separator>\r?\n|&&|\|\||[;|])|"
    r"""(?:(?P<single>'(?:[^'"&|<>\r\n]|'')+')|(?P<double>"[^"$`&|<>\r\n]+")|"""
    r"""(?P<bare>[^\s;|&'"$`@{}()#<>,]+))(?=[ \t\r\n;|&]|\Z)"""
)
POWERSHELL_UNSUPPORTED = re.compile(r"[%^\x00\u2018-\u201e]|[^\S \t\r\n]|\r(?!\n)")
PARSE_HINT = 'Write the launch as a plain command or in an unquoted $() substitution.'
PATCH_HEADER = re.compile(r"\*\*\* (Add|Delete|Update) File: (.+)", re.DOTALL)
# Match Rust str::trim, not Python's extra ASCII record separators.
PATCH_WHITESPACE = " \t\n\r\v\f\x85\xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000"


class LaunchError(ValueError):
    """A literal Orca launch could not be checked."""


def shell_word(raw):
    """Return the literal spelling and whether shell expansion may change it."""
    parts = []
    dynamic = False
    for part in WORD_PART.findall(raw):
        if part.startswith("'"):
            parts.append(part[1:-1])
        elif part.startswith('"'):
            inner = part[1:-1]
            dynamic |= any(m.lastgroup == "expansion" for m in DOUBLE_QUOTE_PART.finditer(inner))
            parts.append(re.sub(r'\\([$\`"\\\n])', lambda m: m[1].replace("\n", ""), inner))
        elif part.startswith("\\"):
            parts.append(part[1:].replace("\n", ""))
        else:
            dynamic |= any(char in part for char in "$`*?[{~")
            parts.append(part)
    return "".join(parts), dynamic


def launch(words):
    for i in range(len(words) - 1):
        if words[i][0] == "orchestration" and words[i + 1][0] in LAUNCHES:
            return words[i + 1][0], words[i + 2:]
    return None


def launch_word(command, pos):
    """Read one shell word and yield launches inside its quoted substitutions."""
    parts = []
    while fragment := WORD_FRAGMENT.match(command, pos):
        pos = fragment.end()
        if fragment[0] != '"':
            parts.append(fragment[0])
            continue
        parts.append('"')
        while quoted := QUOTED_FRAGMENT.match(command, pos):
            pos = quoted.end()
            if quoted[0] == "$(":
                pos = yield from bash_launches(command, pos, substitution=True)
                parts.append("$")  # Keep the resulting word dynamic without evaluating it.
            else:
                parts.append(quoted[0])
                if quoted[0] == '"':
                    break
        else:
            return None, pos
    return shell_word("".join(parts)), pos


def bash_launches(command, pos=0, *, substitution=False):
    """Yield direct launches, including each command in a parallel batch."""
    words = []
    depth = int(substitution)
    redirected = False
    while pos < len(command):
        token = SHELL_TOKEN.match(command, pos)
        if token is None:
            if launch(words) or substitution:
                raise LaunchError("cannot parse the orchestration launch arguments")
            # An unrelated malformed shell command is for Bash to handle.
            return
        pos = token.end()
        kind, value = token.lastgroup, token[0]
        if kind == "redirect":
            redirected = True
        elif kind == "word":
            word, pos = yield from launch_word(command, token.start())
            if word is None:
                if launch(words) or substitution:
                    raise LaunchError("cannot parse the orchestration launch arguments")
                return
            if redirected:
                redirected = False
            else:
                words.append(word)
        elif kind == "operator":
            current = launch(words)
            if current:
                if redirected:
                    raise LaunchError("cannot parse the orchestration launch redirection")
                yield current
            words = []
            redirected = False
            if substitution:
                if value == "(":
                    depth += 1
                elif value == ")":
                    depth -= 1
                    if depth == 0:
                        return pos
    if substitution:
        raise LaunchError("cannot parse the orchestration launch substitution")
    current = launch(words)
    if current:
        if redirected:
            raise LaunchError("cannot parse the orchestration launch redirection")
        yield current


def powershell_launches(command):
    """Read the literal PowerShell subset before checking any launch in the command."""
    error = "cannot parse the orchestration launch arguments"
    if POWERSHELL_UNSUPPORTED.search(command):
        raise LaunchError(error)
    launches = []
    words = []
    pos = 0
    while pos < len(command):
        token = POWERSHELL_TOKEN.match(command, pos)
        if token is None:
            raise LaunchError(error)
        pos = token.end()
        kind, raw = token.lastgroup, token[0]
        if kind == "space":
            continue
        if kind == "separator":
            if current := launch(words):
                launches.append(current)
            words = []
            continue
        value = raw if kind == "bare" else raw[1:-1]
        if kind == "single":
            value = value.replace("''", "'")
        # Native binding honors even a quoted stop-parsing token.
        if value == "--%" or (kind == "bare" and value.startswith("~")):
            raise LaunchError(error)
        if kind == "bare" and value.startswith("-") and not value.startswith("--") and "." in value:
            raise LaunchError(error)
        if value.endswith("\\") and any(char.isspace() for char in value):
            raise LaunchError(error)
        words.append((value, False))
    if current := launch(words):
        launches.append(current)
    return launches


def launch_spec(verb, args):
    """Find the spec-or-task option, or return None for a help request."""
    selected = None
    i = 0
    while i < len(args):
        word, dynamic = args[i]
        key, equal, value = word.partition("=")
        i += 1
        if key == "--":
            break
        if word in {"--help", "-h"}:
            return None
        if key not in SPEC_FLAGS | VALUE_FLAGS:
            continue
        if not equal:
            if i == len(args) or args[i][0].startswith("--"):
                raise LaunchError(f"cannot parse {verb} arguments: {key} needs a value")
            value, dynamic = args[i]
            i += 1
        if key in SPEC_FLAGS:
            if selected is not None or not value:
                raise LaunchError(f"cannot parse {verb} arguments: expected exactly one non-empty spec or task option")
            selected = key, value, dynamic
    if selected is None or (selected[0] == "--task" and verb != "worker-start"):
        raise LaunchError(f"cannot parse {verb} arguments: expected a spec file or inline spec")
    return selected


def load_surface():
    sys.dont_write_bytecode = True
    module_spec = importlib.util.spec_from_file_location("odd_flow_surface", SURFACE_SCRIPT)
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


def load_prompt_hook():
    # The hook runs with -I, so the scripts directory is not on sys.path.
    sys.dont_write_bytecode = True
    script = Path(__file__).with_name("prompt-submit.py")
    spec = importlib.util.spec_from_file_location("odd_flow_prompt_submit", script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def workspace_root(cwd, workspace_paths=()):
    import subprocess

    git = subprocess.run(
        ["git", "-C", str(cwd), "rev-parse", "--show-toplevel"],
        capture_output=True, timeout=2, check=False,
    )
    if git.returncode == 0:
        return Path(git.stdout.decode("utf-8").rstrip("\r\n")).resolve()
    if workspace_paths:
        resolved_cwd = cwd.resolve()
        roots = [Path(path).resolve() for path in workspace_paths]
        return next((root for root in roots if workspace_spelling(resolved_cwd, root).is_relative_to(root)), roots[0])
    fallback = None if CODEX or ANTIGRAVITY else os.environ.get("CLAUDE_PROJECT_DIR")
    return Path(fallback or cwd).resolve()


def workspace_spelling(target, root):
    """Use the root's spelling for filesystem aliases, such as case on macOS."""
    depth = len(root.parts)
    if len(target.parts) >= depth and not target.is_relative_to(root):
        prefix = Path(*target.parts[:depth])
        try:
            if prefix.samefile(root):
                return root.joinpath(*target.parts[depth:])
        except (FileNotFoundError, NotADirectoryError):
            pass
    return target


def path_decision(target, root, temp_roots):
    """Classify a resolved target; workspace rules take precedence over temp."""
    if target.is_relative_to(root):
        if target.parent == root / "odd" / "tasks" and target.name.endswith(".md"):
            return None
        return "deny"
    if any(target.is_relative_to(temp_root) for temp_root in temp_roots):
        return None
    return "ask"


def system_temp_roots():
    import tempfile

    return [
        Path(path).resolve()
        for path in (tempfile.gettempdir(), os.environ.get("TMPDIR"), "/tmp", "/private/tmp")
        if path
    ]


def external_edit_reason(target):
    return (
        f"Parent edit to {target!r} outside the workspace requires confirmation. "
        "The parent writes it only after the user named the file and confirmed the exact diff."
    )


def parent_edit_decision(payload, field):
    if payload.get("agent_id"):
        return None, None
    session_id = payload.get("session_id")
    prompt_hook = load_prompt_hook()
    if prompt_hook.is_worker_session(session_id):
        return None, None
    if prompt_hook.mode_state(session_id).get("mode") != "full-delegation":
        return None, None

    target = None
    delegate = "Full delegation sends workspace changes to a bounded writer."
    try:
        tool_input = payload.get("tool_input")
        target = tool_input.get(field) if isinstance(tool_input, dict) else None
        if not isinstance(target, str) or not target:
            return "deny", f"Missing or invalid {field}: {target!r}. {delegate}"
        cwd = Path(payload.get("cwd") or os.getcwd())
        resolved = (cwd / target).resolve()
        root = workspace_root(cwd)
        decision = path_decision(workspace_spelling(resolved, root), root, system_temp_roots())
    except Exception:
        return "deny", f"Could not verify the edit target {target!r}. {delegate}"
    if decision == "deny":
        return decision, f"Parent edit denied for {target!r}. {delegate}"
    if decision == "ask":
        return decision, external_edit_reason(target)
    return None, None


def patch_targets(command):
    """Read the local Codex patch grammar for target classification, not application."""
    if not isinstance(command, str) or "\0" in command:
        raise ValueError("invalid patch command")
    lines = command.strip(PATCH_WHITESPACE).split("\n")
    if lines[0].removesuffix("\r") in {"<<EOF", "<<'EOF'", '<<"EOF"'} and lines[-1].endswith("EOF"):
        lines = lines[1:-1]
    if (
        len(lines) < 3
        or lines[0].strip(PATCH_WHITESPACE) != "*** Begin Patch"
        or lines[-1].strip(PATCH_WHITESPACE) != "*** End Patch"
    ):
        raise ValueError("missing patch boundaries or hunks")

    targets = []
    hunk = None
    moved = False
    chunk = None
    for raw in lines[1:-1]:
        line = raw.removesuffix("\r")
        tail = line.rstrip(PATCH_WHITESPACE)
        header = PATCH_HEADER.fullmatch(tail if hunk == "Update" else tail.lstrip(PATCH_WHITESPACE))
        if header:
            if hunk == "Update" and (chunk == "empty" or (chunk is None and not moved)):
                raise ValueError("empty update")
            hunk, target = header.groups()
            targets.append(target)
            moved, chunk = False, None
        elif hunk == "Add" and line.startswith("+"):
            continue
        elif hunk == "Update":
            if chunk is None and not moved and tail.startswith("*** Move to: "):
                targets.append(tail[len("*** Move to: "):])
                moved = True
            elif (tail == "@@" or tail.startswith("@@ ")) and chunk != "empty":
                chunk = "empty"
            elif tail == "*** End of File" and chunk == "body":
                chunk = "eof"
            elif chunk == "eof" and not tail:
                continue
            elif chunk != "eof" and (not line or line.startswith((" ", "+", "-"))):
                chunk = "body"
            else:
                raise ValueError("unrecognized update line")
        else:
            # An environment selector is not a host path and cannot be classified here.
            raise ValueError("unrecognized patch header or non-local environment")
    if hunk == "Update" and (chunk == "empty" or (chunk is None and not moved)):
        raise ValueError("empty update")
    return targets


def codex_patch_denial(payload):
    delegate = "Full delegation sends workspace changes to a bounded writer."
    try:
        # The tagged runtime sets agent_id for ThreadSpawn children only.
        agent_id = payload.get("agent_id")
        if isinstance(agent_id, str) and agent_id:
            return None
        session_id = payload.get("session_id")
        prompt_hook = load_prompt_hook()
        if prompt_hook.is_worker_session(session_id):
            return None
        mode = prompt_hook.mode_state(session_id).get("mode")
        if mode == "organic":
            return None
        if mode != "full-delegation":
            raise ValueError("unresolved mode")

        targets = patch_targets(payload["tool_input"]["command"])
        cwd = Path(payload["cwd"])
        if not cwd.is_absolute() or not cwd.is_dir():
            raise ValueError("missing local working directory")
        root = workspace_root(cwd)
        temp_roots = system_temp_roots()
        for target in targets:
            # Codex PathUri::join removes dot segments before filesystem lookup.
            absolute = Path(os.path.normpath(cwd / target))
            paths = [absolute.resolve()]
            if absolute.is_symlink():
                # Deletes and moves can affect the link entry, not just its referent.
                paths.append(absolute.parent.resolve() / absolute.name)
            for path in paths:
                decision = path_decision(workspace_spelling(path, root), root, temp_roots)
                if decision == "deny":
                    return f"Parent edit denied for {target!r}. {delegate}"
                if decision == "ask":
                    return external_edit_reason(target)
    except Exception:
        return f"Could not verify the direct apply_patch targets or delegation mode. {delegate}"
    return None


def codex_spawn_prompt(tool_input):
    """Recover the role brief from native plaintext or v1 structured text."""
    if not isinstance(tool_input, dict):
        return None
    message = tool_input.get("message")
    if isinstance(message, str):
        return message
    items = tool_input.get("items")
    if isinstance(items, list):
        return "\n".join(
            item["text"] for item in items
            if isinstance(item, dict) and item.get("type") == "text"
            and isinstance(item.get("text"), str)
        )
    return None


def denial_reason(payload, *, read_launches=bash_launches):
    tool = payload.get("tool_name")
    tool_input = payload.get("tool_input") or {}
    if (CODEX and tool == "spawn_agent") or (not CODEX and tool in {"Agent", "Task"}):
        prompt = codex_spawn_prompt(tool_input) if CODEX else tool_input.get("prompt")
        # Mirror surface.is_writer without loading the parser on the fast path.
        if not isinstance(prompt, str) or next(
            (line.strip().casefold() for line in prompt.lstrip("\ufeff").splitlines() if line.strip()), ""
        ) != "# role: write":
            return None
        try:
            surface = load_surface()
            try:
                surface.check(prompt)
            except surface.SurfaceError as exc:
                return str(exc)
        except Exception:
            return "internal error while checking the writer launch; verify the edit-surface guard before retrying."
    elif tool == "Bash":
        command = tool_input.get("command")
        if not isinstance(command, str) or "orchestration" not in command:
            return None
        surface = None
        parsed = 0
        try:
            for verb, args in read_launches(command):
                parsed += 1
                selected = launch_spec(verb, args)
                if selected is None:
                    continue
                key, value, dynamic = selected
                if key == "--task":
                    continue
                source = "inline spec"
                if surface is None:
                    surface = load_surface()
                try:
                    if key == "--spec-file":
                        if dynamic or any(c in value for c in "$`") or glob.has_magic(value) or value == "-":
                            raise LaunchError(f"{value!r} is not a literal spec path")
                        source = f"spec file {value!r}"
                        cwd = payload.get("cwd") or os.getcwd()
                        spec = surface.read_spec(Path(cwd) / value)
                    else:
                        if dynamic:
                            raise LaunchError("cannot parse the expanded inline spec")
                        spec = value
                    if surface.is_writer(spec):
                        surface.check(spec)
                except surface.SurfaceError as exc:
                    raise LaunchError(f"{source}: {exc}") from exc
            if len(RAW_LAUNCH.findall(command)) > parsed:
                raise LaunchError("cannot parse the orchestration launch")
        except LaunchError as exc:
            hint = f" {PARSE_HINT}" if str(exc).startswith("cannot parse the orchestration launch") else ""
            return f"{exc}.{hint} Pass a readable file with a literal spec path to --spec-file, and fix the spec before launching."
        except Exception:
            if parsed or RAW_LAUNCH.search(command):
                return "internal error while checking the orchestration launch; verify the edit-surface guard before retrying."
    return None


ANTIGRAVITY_EDIT_TOOLS = {
    "write_file", "edit_file", "write_to_file", "replace_file_content", "multi_replace_file_content",
}


def antigravity_edit_decision(payload, args):
    """Classify a parent edit; returns (decision, reason) with decision None to allow."""
    conversation = payload.get("conversationId")
    delegate = "Full delegation sends workspace changes to a bounded writer."
    target = None
    try:
        prompt_hook = load_prompt_hook()
        if prompt_hook.is_worker_session(conversation):
            return None, None
        mode = prompt_hook.mode_state(conversation).get("mode")
        if mode == "organic":
            return None, None
        if mode != "full-delegation":
            raise ValueError("unresolved mode")
        target = next((args[f] for f in ("Path", "TargetFile") if isinstance(args.get(f), str) and args[f]), None)
        if target is None:
            return "deny", f"Missing or invalid edit target. {delegate}"
        workspaces = payload.get("workspacePaths")
        workspaces = workspaces if isinstance(workspaces, list) else []
        payload_cwd = payload.get("cwd")
        cwd = Path(payload_cwd or (workspaces[0] if workspaces else os.getcwd()))
        absolute = cwd / target
        paths = [absolute.resolve()]
        if absolute.is_symlink():
            # The link entry itself changes on replace, not just its referent.
            paths.append(absolute.parent.resolve() / absolute.name)
        root = workspace_root(cwd, workspaces)
        temp_roots = system_temp_roots()
        decisions = [path_decision(workspace_spelling(path, root), root, temp_roots) for path in paths]
    except Exception:
        return "deny", f"Could not verify the edit target {target!r} or delegation mode. {delegate}"
    if "deny" in decisions:
        return "deny", f"Parent edit denied for {target!r}. {delegate}"
    if "ask" in decisions:
        return "force_ask", external_edit_reason(target)
    return None, None


def antigravity_main():
    decision, reason = None, None
    try:
        payload = json.loads(sys.stdin.buffer.read().decode("utf-8"))
        call = payload.get("toolCall")
        name = call.get("name")
        args = call.get("args")
        args = args if isinstance(args, dict) else {}
        if name in ANTIGRAVITY_EDIT_TOOLS:
            decision, reason = antigravity_edit_decision(payload, args)
        elif name in {"run_command", "invoke_subagent"}:
            workspaces = payload.get("workspacePaths")
            normalized = {"cwd": payload.get("cwd") or (workspaces[0] if isinstance(workspaces, list) and workspaces else None)}
            if name == "run_command":
                normalized |= {"tool_name": "Bash", "tool_input": {"command": args.get("CommandLine")}}
            else:
                normalized |= {"tool_name": "Agent", "tool_input": {"prompt": args.get("Prompt")}}
            if name == "run_command" and sys.platform == "win32":
                reason = denial_reason(normalized, read_launches=powershell_launches)
            else:
                reason = denial_reason(normalized)
            decision = "deny" if reason else None
    except UnicodeDecodeError:
        decision, reason = "deny", "Hook input is not valid UTF-8."
    except Exception:  # Internal errors must not block an unrelated tool call.
        decision, reason = None, None
    output = {"decision": decision or "allow"}
    if reason:
        output["reason"] = f"odd-flow: {reason}"
    print(json.dumps(output))


def main():
    if ANTIGRAVITY:
        return antigravity_main()
    payload = json.loads(sys.stdin.buffer.read().decode("utf-8"))
    field = EDIT_PATH_FIELDS.get(payload.get("tool_name"))
    if CODEX and payload.get("tool_name") == "apply_patch":
        decision, reason = "deny", codex_patch_denial(payload)
    elif not CODEX and field:
        decision, reason = parent_edit_decision(payload, field)
    else:
        decision, reason = "deny", denial_reason(payload)
    if reason:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": f"odd-flow: {reason}",
        }}))


if __name__ == "__main__":
    try:
        main()
    except UnicodeDecodeError:
        print("odd-flow: hook input is not valid UTF-8.", file=sys.stderr)
        sys.exit(2)
    except Exception:  # Internal errors must not block an unrelated tool call.
        if ANTIGRAVITY:
            print(json.dumps({"decision": "allow"}))
        sys.exit(0)
