---
name: odd-flow
description: "Trigger: /odd-flow, ODD, Orca workers, role profiles. Run Organic Driven Development and dispatch role workers to Orca with per-role agent, model and effort."
license: Apache-2.0
metadata:
  author: "max"
  version: "0.1.0-draft"
---

## Activation Contract

- Load on `/odd-flow` (in Claude Code, `/odd-flow:odd-flow`) with no argument, `--profile <p>`, `--profile-default <p>`, `--profiles`, `--create-profile <p>` or `init`, or on a request to work in ODD, manage profiles or run role workers through Orca.
- Once loaded, ODD governs every later request of this session.

## Hard Rules

1. Work inline by default. Launch a worker only when a trigger in `references/delegation.md` names its reason; never one worker per role by habit. A worker is an Orca worker inside an Orca terminal, otherwise a subagent or inline work (`references/orca-dispatch.md`, Without Orca); missing Orca never stops the work.
2. Before every launch, resolve the role with `scripts/profile.py resolve <role>`; never reuse flags from memory. Print its `notice` line.
3. If a launch fails because of the agent or model, report role, profile and error. Never switch model or agent on your own; the Without Orca fallback is the only sanctioned switch, and its notice names it.
4. Investigation, explanation, review and planning requests stay read-only until the user asks for a change.
5. Quote user requirements verbatim; hand work to workers by reference, never by paraphrase.
6. The parent owns git, commits and scratch cleanup. Workers never commit, stage, delete scratch or launch workers.
7. Never report a check as passed without observed output; list failed, skipped and pending checks.
8. `/odd-flow init`, `--profile-default` and `--create-profile` never write before the user confirms the diff they showed. Only `scripts/profile.py` writes the profiles file.

## Decision Gates

| Situation | Load before acting |
|---|---|
| Any request in an active session | `references/odd-protocol.md` |
| Task classified large | `references/tracking.md` |
| A delegation trigger may hold | `references/delegation.md` |
| About to launch a worker | `references/orca-dispatch.md`, `assets/roles/<role>.md` |
| Profile command, unknown profile, resolve error | `references/profiles.md` |
| Past work, a decision worth keeping, resume, compaction | `references/memory.md` |
| Risk line names an item, or the user asks for review | `references/review.md` |
| About to commit or amend | `references/commit.md` |
| `/odd-flow init` | `references/init.md` |

## Execution Steps

1. On activation with a profile command (`--profile`, `--profile-default`, `--profiles`, `--create-profile`), load `references/profiles.md` and follow its Commands section. Otherwise run `python3 <skill-dir>/scripts/profile.py show`. Report the profile line in one sentence.
2. Run each request through ODD: Authorize, Explore, Resolve uncertainty, Classify, Track (large only), Implement, Close.
3. Load only the references the Decision Gates name for the current step.

## Output Contract

Close every request with: verified outcome; every failed, skipped or pending check; next step; `Risk: item N (reason)` or `Risk: none` for code changes; and the profile and roles used when workers ran.

## References

- `references/odd-protocol.md` — steps, task size, high-risk items, test-first policy.
- `references/delegation.md` — triggers, units, edit surfaces, correction bounds.
- `references/orca-dispatch.md` — launch, wait and collect Orca workers; subagent or inline fallback without Orca.
- `references/profiles.md` — profile file, session binding, commands.
- `references/tracking.md` — feature document and commit units.
- `references/commit.md` — commit procedure, message format, failures and amend.
- `references/memory.md` — Engram reads and writes.
- `references/review.md` — lenses, refuter, one bounded correction.
- `references/init.md` — fallback: install the core block where the plugin hook does not run.
- `assets/` — spec template, role prompts, profile and feature-doc templates.
