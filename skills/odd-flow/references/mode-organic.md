# Organic mode

Load this file when the `mode:` line of `profile.py show` says `organic`. It is the only mode file a session loads; the latest `mode:` line wins over the rules injected at session start.

## Who writes

- Work inline by default. Launch a worker only when a trigger in this file or in `delegation.md` names its reason; never one worker per role by habit.
- No trigger holds by default. When in doubt, work inline. Each trigger is mandatory only when its condition truly holds; record the reason in one line before launching.
- Never delegate for size, file count, a large task alone, or price. Units of ~100 changed lines or less run inline.
- Small path: inline; no workers.

## Writer triggers

| Trigger | Condition | Role |
|---|---|---|
| Writer: parallel | Two or more independent units with disjoint edit surfaces, each several minutes of work (several files or ~100+ changed lines), launched together in one turn | `write`, one per unit |
| Writer: context | `scripts/context.py` reports `holds` (the parent context is at 150k tokens or more); delegate the next bounded unit | `write` |

## Measuring context

Run `python3 <skill-dir>/scripts/context.py` before the first write of each implementation unit, and quote its line in the one-line reason. Never estimate the context from the conversation's length when the script reports a number.

- Claude Code: tokens of the last main-thread reply in the session transcript (input, cache creation and cache read).
- Codex: input tokens of the last `token_count` event in the session rollout, with the model's context window.
- `unknown` (Antigravity, a missing file, no session id): judge the trigger yourself and say that the number was unavailable.

The trigger holds from 150k tokens whatever the model's window: a long parent context degrades its attention to the specs before it runs out.

## Without Orca

When no subagent can run (`orca-dispatch.md`, Without Orca):

- Inline otherwise: the parent runs the role itself, one unit at a time. A `verify`, `review` or `refute` run inline is not independent; say so in the close.

Print the notice with `fallback: subagent` or `fallback: inline`, and record the route as `subagent:<role>` or `inline` in the feature document.

## Feature-document routes

A task's route is `inline`, `orca:<role>` or `subagent:<role>`.

## After a worker exhausts its bound

Name the cause; fix inline when small and understood, otherwise relaunch once with the diagnosis and a new hypothesis. A repeated cause blocks the unit.

## Review correction

Write it inline or with one `write` worker.

## Switching mode

The user switches with `/odd-flow --mode full-delegation` (this session only) or `/odd-flow --profile-mode <p> full-delegation` (saved in the profile). It applies from the next request, with no new session: load `mode-full-delegation.md` instead of this file.
