#!/usr/bin/env python3
"""Check writer launches and full-delegation parent edits in Claude Code, Codex and Antigravity."""

import glob
import importlib.util
import json
import os
from pathlib import Path, PureWindowsPath
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
EVAL_COMMANDS = {"eval", "invoke-expression", "iex"}
NESTED_SHELLS = {"powershell", "pwsh", "cmd", "bash", "sh", "zsh", "dash", "ksh"} | EVAL_COMMANDS
DIRECTORY_CHANGES = {"cd", "set-location", "push-location", "pop-location", "pushd", "popd", "sl", "chdir"}
POSIX_PREFIXES = {"{", "!", "if", "then", "do", "else", "elif", "while", "until", "time", "function", "coproc"}
COMMAND_WRAPPERS = {"env", "command", "exec", "builtin", "nohup", "nice", "timeout"}
WRAPPER_VALUE_OPTIONS = {
    "env": {"-u", "--unset", "-C", "--chdir", "-P", "-S", "--split-string"},
    "exec": {"-a"},
    "nice": {"-n", "--adjustment"},
    "timeout": {"-k", "--kill-after", "-s", "--signal"},
}
RAW_LAUNCH = re.compile(r"(?<![\w-])orchestration(?:\s|\\\n)+(?:task-create|worker-start)(?![\w-])")
ORCHESTRATION_ARG = re.compile(r"(?<![\w-])orchestration(?![\w-])", re.IGNORECASE)
NESTED_LAUNCH_ARG = re.compile(r"(?<![\w-])(?:orca|task-create|worker-start|--spec(?:-file)?)(?![\w-])",
                               re.IGNORECASE)
SPEC_FLAGS = {"--spec", "--spec-file", "--task"}
VALUE_FLAGS = {
    "--agent", "--base-branch", "--comment", "--deps", "--display-name", "--effort",
    "--environment", "--for", "--from", "--item", "--model", "--name", "--on",
    "--pairing-code", "--parent", "--repo", "--retry-of", "--retry-request", "--run",
    "--setup", "--task-title", "--terminal", "--timeout-ms", "--worktree",
}

# Tokenize the literal launch forms, not the evaluated shell program. Keep quoted
# operators and newlines inside their words, and never run a command to find a spec.
WORD_FRAGMENT = re.compile(r"""(?:'[^']*'|\\[\s\S]|\$(?!\()|[^\s;&|()<>'"`\\$])+|\$\(|""" r'["`]')
SHELL_TOKEN = re.compile(
    r"""(?P<space>[ \t]+|\\\n)|(?P<comment>\#[^\n]*)|"""
    r"""(?P<redirect>[0-9]*(?:<<<|<<-?|<>|>>|>&|<&|>\||[<>]))|"""
    r"""(?P<operator>;;&|;;|;&|&&|\|\||\|&|[\n;&|()])|"""
    rf"(?P<word>{WORD_FRAGMENT.pattern})"
)
WORD_PART = re.compile(r"""'[^']*'|"(?:\\[\s\S]|[^"\\])*"|\\[\s\S]|[^'"\\]+""")
DOUBLE_QUOTE_PART = re.compile(r"\\[$`\"\\\n]|(?P<expansion>[$`])")
QUOTED_FRAGMENT = re.compile(r'\\[\s\S]|\$\(|["`]|[^"`\\$]+|\$')
BACKTICK_BODY = re.compile(r'((?:\\[\s\S]|[^\\`])*)`')
POWERSHELL_TOKEN = re.compile(
    r"(?P<space>[ \t]+)|(?P<separator>\r?\n|&&|\|\||[;|])|"
    r"""(?:(?P<single>'(?:[^'"&|<>\r\n]|'')+')|(?P<double>"[^"$`&|<>\r\n]+")|"""
    r"""(?P<bare>[^\s;|&'"$`@{}()#<>,]+))(?=[ \t\r\n;|&]|\Z)"""
)
POWERSHELL_UNSUPPORTED = re.compile(r"[%^\x00\u2018-\u201e]|[^\S \t\r\n]|\r(?!\n)")
PARSE_HINT = 'Write the launch as a plain command or in an unquoted $() substitution.'
NESTED_SHELL_ERROR = ("cannot parse the orchestration launch inside a nested shell; "
                      "run orca orchestration directly without a nested shell")
DYNAMIC_VERB_HINT = "write the literal orchestration verb instead of an expansion or substitution"
PATCH_HEADER = re.compile(r"\*\*\* (Add|Delete|Update) File: (.+)", re.DOTALL)
# Match Rust str::trim, not Python's extra ASCII record separators.
PATCH_WHITESPACE = " \t\n\r\v\f\x85\xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000"


class LaunchError(ValueError):
    """A literal Orca launch could not be checked."""


class LaunchScan:
    # Shared by substitutions and their enclosing scan so hazards also apply
    # when the direct launch appears earlier or in a different segment.
    def __init__(self):
        self.nested_script = False
        self.literal_nonlaunches = 0


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


def launch(words, *, posix=False, start=0):
    orca = start < len(words) and (program_name(words[start][0]) == "orca" or words[start][1])
    for i in range(len(words) - 1):
        if words[i][0] != "orchestration":
            continue
        verb, dynamic = words[i + 1]
        if posix and orca and i == start + 1 and dynamic:
            raise LaunchError(DYNAMIC_VERB_HINT)
        if verb in LAUNCHES:
            return verb, words[i + 2:]
    return None


def program_name(word):
    name = re.split(r"[/\\]", word)[-1].casefold()
    return name.removesuffix(".exe").removesuffix(".cmd")


def command_start(words, *, posix):
    """Locate the invoked program and collect wrapper cwd and re-parsing effects."""
    start = 0
    changes_cwd = reparses = False
    allow_assignment = posix
    while start < len(words):
        word = words[start][0]
        if posix and word in POSIX_PREFIXES:
            start += 1
            if word == "time":
                while start < len(words) and words[start][0] in {"-p", "--"}:
                    start += 1
            elif word == "function":
                start += 1  # Skip the function name, not the body.
            continue
        if allow_assignment and re.match(r"[a-zA-Z_]\w*=", word):
            start += 1
            continue
        wrapper = program_name(word)
        if wrapper not in COMMAND_WRAPPERS:
            break
        start += 1
        while start < len(words) and words[start][0].startswith("-"):
            option = words[start][0]
            start += 1
            if option == "--":
                break
            takes_value = WRAPPER_VALUE_OPTIONS.get(wrapper, ())
            if option.startswith("--"):
                option, attached, _ = option.partition("=")
            else:
                # The first value-taking flag owns the rest of a short bundle.
                for i, flag in enumerate(option[1:], 2):
                    if "-" + flag in takes_value:
                        option, attached = "-" + flag, option[i:]
                        break
                else:
                    continue
            if wrapper == "env":
                changes_cwd |= option in {"-C", "--chdir"}
                reparses |= option in {"-S", "--split-string"}
            if option in takes_value and not attached:
                start += 1
        if wrapper == "timeout":
            start += 1  # Skip the duration before unwrapping the command.
        allow_assignment = wrapper == "env"
    return start, changes_cwd, reparses


def mentions_orchestration(raw, words):
    return bool(ORCHESTRATION_ARG.search(raw)) or any(ORCHESTRATION_ARG.search(word) for word, _ in words)


def command_launch(words, raw, directory_changed, scan, *, posix=False,
                   stdin_script=False, pipeline_mentions_orchestration=False, scope_positions=()):
    """Classify a literal command without evaluating shell input."""
    start, wrapper_cwd, reparses = command_start(words, posix=posix)
    program = program_name(words[start][0]) if start < len(words) else ""
    nested_script = reparses or program in EVAL_COMMANDS
    nested_launch = False
    if program in NESTED_SHELLS:
        args = [word for word, _ in words[start + 1:]]
        command_line = " ".join(args)
        nested_script |= stdin_script or any(arg.casefold() in {"-c", "-command", "/c"} for arg in args)
        nested_launch = bool(ORCHESTRATION_ARG.search(command_line) and NESTED_LAUNCH_ARG.search(command_line))
    if nested_script:
        scan.nested_script = True
        nested_launch |= pipeline_mentions_orchestration or mentions_orchestration(raw, words)
    current = None if nested_launch else launch(words, posix=posix, start=start)
    if nested_launch or ((current or RAW_LAUNCH.search(raw)) and any(
        words[i][0] == "orchestration" and program_name(words[i - 1][0]) in NESTED_SHELLS
        for i in range(1, len(words))
    )):
        raise LaunchError(NESTED_SHELL_ERROR)
    if (not current and program == "orca" and len(words) > start + 2
            and (not posix or start + 1 in scope_positions)):
        (_, executable_dynamic), (scope, scope_dynamic), (verb, verb_dynamic) = words[start:start + 3]
        if not posix:
            scope, verb = scope.casefold(), verb.casefold()
        if (not (executable_dynamic or scope_dynamic or verb_dynamic) and scope == "orchestration"
                and verb and verb not in LAUNCHES):
            scan.literal_nonlaunches += 1
    directory_changed |= program in DIRECTORY_CHANGES
    if not posix and start < len(words):
        directory_changed |= words[start][0].casefold() in {"cd..", "cd\\"}
    return ((*current, directory_changed or wrapper_cwd) if current else None), directory_changed


def backtick_launches(command, pos, directory_changed, scan, *, quoted=False):
    """Check a legacy substitution and return the offset after its closing backtick."""
    body = BACKTICK_BODY.match(command, pos)
    if body is None:
        return None
    # The outer shell removes only escapes special to backtick substitution.
    escapes = r'\\([$`"\\\n])' if quoted else r'\\([$`\\\n])'
    inner = re.sub(escapes, lambda m: m[1].replace("\n", ""), body[1])
    for current in bash_launches(inner, directory_changed=directory_changed, scan=scan):
        if quoted:
            # Quoted legacy launch substitutions are not a supported literal form.
            raise LaunchError("cannot parse the orchestration launch inside double-quoted backticks")
        yield current
    return body.end()


def launch_word(command, pos, directory_changed, scan):
    """Read one shell word and yield launches inside its substitutions."""
    parts = []
    while fragment := WORD_FRAGMENT.match(command, pos):
        pos = fragment.end()
        if fragment[0] == "$(":
            pos = yield from bash_launches(command, pos, substitution=True,
                                           directory_changed=directory_changed, scan=scan)
            parts.append("$")
            continue
        if fragment[0] == "`":
            end = yield from backtick_launches(command, pos, directory_changed, scan)
            if end is None:
                return None, pos
            pos = end
            parts.append("$")
            continue
        if fragment[0] != '"':
            parts.append(fragment[0])
            continue
        parts.append('"')
        while quoted := QUOTED_FRAGMENT.match(command, pos):
            pos = quoted.end()
            if quoted[0] == "$(":
                pos = yield from bash_launches(command, pos, substitution=True,
                                               directory_changed=directory_changed, scan=scan)
                parts.append("$")  # Keep the resulting word dynamic without evaluating it.
            elif quoted[0] == "`":
                end = yield from backtick_launches(command, pos, directory_changed, scan, quoted=True)
                if end is None:
                    return None, pos
                pos = end
                parts.append("$")
            else:
                parts.append(quoted[0])
                if quoted[0] == '"':
                    break
        else:
            return None, pos
    return shell_word("".join(parts)), pos


def bash_launches(command, pos=0, *, scan, substitution=False, directory_changed=False):
    """Yield direct launches, including each command in a parallel batch."""
    words = []
    scope_positions = set()
    depth = int(substitution)
    redirected = False
    stdin_redirect = stdin_pipe = False
    pipe_orchestration = False
    cases = []
    start = pos
    while pos < len(command):
        token = SHELL_TOKEN.match(command, pos)
        if token is None:
            if launch(words, posix=True, start=command_start(words, posix=True)[0]) or substitution:
                raise LaunchError("cannot parse the orchestration launch arguments")
            # An unrelated malformed shell command is for Bash to handle.
            return
        pos = token.end()
        kind, value = token.lastgroup, token[0]
        if kind == "redirect":
            redirected = True
            stdin_redirect |= value.startswith(("<", "0<"))
        elif kind == "word":
            word, pos = yield from launch_word(command, token.start(), directory_changed, scan)
            if word is None:
                if launch(words, posix=True, start=command_start(words, posix=True)[0]) or substitution:
                    raise LaunchError("cannot parse the orchestration launch arguments")
                return
            if redirected:
                redirected = False
            elif cases and cases[-1] == "subject":
                cases[-1] = "in"
            elif cases and cases[-1] == "in":
                if value == "in":
                    cases[-1] = "pattern"
                    words = []
                    scope_positions.clear()
            elif not words and value == "esac" and word[0] == "esac" and cases:
                cases.pop()
            elif cases and cases[-1] == "pattern":
                continue
            else:
                if value == "case" and word[0] == "case" and all(w in POSIX_PREFIXES for w, _ in words):
                    cases.append("subject")
                # Only a scope spelt contiguously can account for a raw occurrence.
                if word[0] == "orchestration" and "orchestration" in command[token.start():pos]:
                    scope_positions.add(len(words))
                words.append(word)
        elif kind == "operator":
            # Pattern delimiters are not subshell parentheses or pipelines.
            if cases and cases[-1] == "pattern":
                if value == ")":
                    cases[-1] = "body"
                    start = pos
                continue
            if value == "\n" and stdin_pipe and not words and not stdin_redirect:
                continue  # A newline after a pipe continues the pipeline.
            segment = command[start:token.start()]
            current, directory_changed = command_launch(
                words, segment, directory_changed, scan,
                posix=True, stdin_script=stdin_redirect or stdin_pipe,
                pipeline_mentions_orchestration=pipe_orchestration, scope_positions=scope_positions,
            )
            if current:
                if redirected:
                    raise LaunchError("cannot parse the orchestration launch redirection")
                yield current
            stdin_pipe = value in {"|", "|&"}
            pipe_orchestration = bool(stdin_pipe and (pipe_orchestration or mentions_orchestration(segment, words)))
            words = []
            scope_positions.clear()
            start = pos
            redirected = False
            stdin_redirect = False
            if cases and value in {";;", ";&", ";;&"}:
                cases[-1] = "pattern"
            if substitution:
                if value == "(":
                    depth += 1
                elif value == ")":
                    depth -= 1
                    if depth == 0:
                        return pos
    if substitution:
        raise LaunchError("cannot parse the orchestration launch substitution")
    current, _ = command_launch(
        words, command[start:], directory_changed, scan, posix=True, stdin_script=stdin_redirect or stdin_pipe,
        pipeline_mentions_orchestration=pipe_orchestration, scope_positions=scope_positions,
    )
    if current:
        if redirected:
            raise LaunchError("cannot parse the orchestration launch redirection")
        yield current


def powershell_launches(command, *, scan):
    """Read the literal PowerShell subset before checking any launch in the command."""
    error = "cannot parse the orchestration launch arguments"
    if POWERSHELL_UNSUPPORTED.search(command):
        raise LaunchError(error)
    launches = []
    words = []
    pos = 0
    start = 0
    directory_changed = False
    stdin_script = False
    pipe_orchestration = False
    while pos < len(command):
        token = POWERSHELL_TOKEN.match(command, pos)
        if token is None:
            raise LaunchError(error)
        pos = token.end()
        kind, raw = token.lastgroup, token[0]
        if kind == "space":
            continue
        if kind == "separator":
            if raw.endswith("\n") and stdin_script and not words:
                continue
            segment = command[start:token.start()]
            current, directory_changed = command_launch(
                words, segment, directory_changed, scan, stdin_script=stdin_script,
                pipeline_mentions_orchestration=pipe_orchestration,
            )
            if current:
                launches.append(current)
            stdin_script = raw == "|"
            pipe_orchestration = bool(stdin_script and (pipe_orchestration or mentions_orchestration(segment, words)))
            words = []
            start = pos
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
    current, _ = command_launch(
        words, command[start:], directory_changed, scan, stdin_script=stdin_script,
        pipeline_mentions_orchestration=pipe_orchestration,
    )
    if current:
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
        if not isinstance(command, str):
            return None
        command_text = command.casefold() if read_launches is powershell_launches else command
        orchestration_count = command_text.count("orchestration")
        if not orchestration_count:
            return None
        surface = None
        launches = []
        try:
            scan = LaunchScan()
            launches.extend(read_launches(command, scan=scan))
            if scan.nested_script and (launches or orchestration_count > scan.literal_nonlaunches):
                raise LaunchError(NESTED_SHELL_ERROR)
            for verb, args, directory_changed in launches:
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
                        if directory_changed and not (
                            Path(value).is_absolute()
                            or (read_launches is powershell_launches and PureWindowsPath(value).is_absolute())
                        ):
                            raise LaunchError("pass an absolute --spec-file path or run the launch "
                                              "without changing directory")
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
            if len(RAW_LAUNCH.findall(command)) > len(launches):
                raise LaunchError("cannot parse the orchestration launch")
        except LaunchError as exc:
            hint = f" {PARSE_HINT}" if str(exc).startswith("cannot parse the orchestration launch") else ""
            return f"{exc}.{hint} Pass a readable file with a literal spec path to --spec-file, and fix the spec before launching."
        except Exception:
            if launches or RAW_LAUNCH.search(command):
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
