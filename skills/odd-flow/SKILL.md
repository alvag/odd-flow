---
name: odd-flow
description: "Trigger: /odd-flow, ODD, Orca workers, role profiles. Run Organic Driven Development and dispatch role workers to Orca with per-role agent, model and effort."
license: Apache-2.0
metadata:
  author: "max"
  version: "0.1.0-draft"
---

## Activation Contract

- Load on `/odd-flow`, `/odd-flow <profile>`, `/odd-flow profiles`, `/odd-flow init`, or a request to work in ODD or to run role workers through Orca.
- Once loaded, ODD governs every later request of this session.

## Hard Rules

1. Work inline by default. Launch an Orca worker only when a trigger in `references/delegation.md` names its reason; never one worker per role by habit.
2. Before every launch, resolve the role with `scripts/profile.py resolve <role>`; never reuse flags from memory. Print its `notice` line.
3. If a launch fails because of the agent or model, report role, profile and error. Never switch model or agent on your own.
4. Investigation, explanation, review and planning requests stay read-only until the user asks for a change.
5. Quote user requirements verbatim; hand work to workers by reference, never by paraphrase.
6. The parent owns git, commits and scratch cleanup. Workers never commit, stage, delete scratch or launch workers.
7. Never report a check as passed without observed output; list failed, skipped and pending checks.
8. `/odd-flow init` never writes before the user confirms the diff it showed.

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
| `/odd-flow init` | `references/init.md` |

## Execution Steps

1. On activation, run `python3 <skill-dir>/scripts/profile.py use <profile>` when a profile was given, `list` for `/odd-flow profiles`, else `show`. Report the profile line in one sentence.
2. Run each request through ODD: Authorize, Explore, Resolve uncertainty, Classify, Track (large only), Implement, Close.
3. Load only the references the Decision Gates name for the current step.

## Output Contract

Close every request with: verified outcome; every failed, skipped or pending check; next step; `Risk: item N (reason)` or `Risk: none` for code changes; and the profile and roles used when workers ran.

## References

- `references/odd-protocol.md` — steps, task size, high-risk items, test-first policy.
- `references/delegation.md` — triggers, units, edit surfaces, correction bounds.
- `references/orca-dispatch.md` — launch, wait and collect Orca workers.
- `references/profiles.md` — profile file, session binding, commands.
- `references/tracking.md` — feature document and commits.
- `references/memory.md` — Engram reads and writes.
- `references/review.md` — lenses, refuter, one bounded correction.
- `references/init.md` — fallback: install the core block where the plugin hook does not run.
- `assets/` — spec template, role prompts, profile and feature-doc templates.
