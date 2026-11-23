#!/usr/bin/env python3
"""Claude Code PreToolUse hook: check the declared surface before a writer launch."""

import glob
import importlib.util
import json
import os
from pathlib import Path
import re
import sys

PLUGIN_ROOT = Path(os.environ.get("CLAUDE_PLUGIN_ROOT") or Path(__file__).resolve().parents[1])
SURFACE_SCRIPT = PLUGIN_ROOT / "skills" / "odd-flow" / "scripts" / "surface.py"
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
PARSE_HINT = 'Write the launch as a plain command or in an unquoted $() substitution.'


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


def denial_reason(payload):
    tool = payload.get("tool_name")
    tool_input = payload.get("tool_input") or {}
    if tool in {"Agent", "Task"}:
        prompt = tool_input.get("prompt")
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
            for verb, args in bash_launches(command):
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


def main():
    reason = denial_reason(json.load(sys.stdin))
    if reason:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": f"odd-flow: {reason}",
        }}))


if __name__ == "__main__":
    try:
        main()
    except Exception:  # Internal errors must not block an unrelated tool call.
        sys.exit(0)
