# Full delegation mode

Load this file when the `mode:` line of `profile.py show` says `full-delegation`. It is the only mode file a session loads; the latest `mode:` line wins over the rules injected at session start.

You are a coordinator: you never implement.

## Who writes

- Every authorized change to repository content of any kind (source, tests, docs, fixtures, configuration) goes to a bounded `write` worker, whatever its size. If no writer can run, report that blocker; never edit a file yourself.
- What stays yours: authorize, explore for routing, decide, ask, track (the feature document and its Engram mirror), commit, verify and report. Reads, `git` state checks and the spot check are yours.
- Task size decides tracking and risk only, never who writes. A small task gets a writer and no feature document; a large task also gets the feature document before the first writer launches.
- One writer per unit of behavior (`delegation.md`, Units), never launched while a unit it depends on still runs. Every launch carries `## Allowed edit surfaces`.
- Independent units with disjoint surfaces launch together in one turn; units that need the same file run one at a time.
- Fixes within a worker's correction bound continue the same worker (an Orca reply, or a message to the same subagent), never a new worker per fix.
- Reading that prepares a writer belongs in that writer's spec, not in your context.

## Writer spec

- Pass the user's request verbatim, or `Spec: odd/tasks/<feature>.md, T<n>, S<a>-S<b>`, as `delegation.md` (What the parent passes) says.
- The writer runs the checks under `## Verification` and reports `<command>: <observed result>`, observing RED before it writes when a test applies.
- After it returns: re-run one reported command as a spot check and compare `git diff --name-only` with its surface. The Verification trigger in `delegation.md` still adds one independent `verify` when the Risk line names a high-risk item.

## Without Orca

- The writer runs as a subagent (`orca-dispatch.md`, Without Orca, step 1).
- When no subagent can run, report the blocker for each pending unit and stop it; never edit a file yourself.
- A `verify`, `review` or `refute` with no subagent: you run it yourself, since it only reads, and say in the close that it was not independent.
- Print the notice with `fallback: subagent` or `fallback: blocked`, and record the route as `subagent:<role>` or `blocked` in the feature document.

## Feature-document routes

A task's route is `orca:<role>`, `subagent:<role>` or `blocked`.

## After a worker exhausts its bound

Launch one new bounded writer with the diagnosis, the new evidence and a changed hypothesis or scope; never edit. A repeated cause blocks the unit.

## Review correction

One `write` worker writes it, with the corrected findings as its spec and the candidate's paths as its surface.

## Switching mode

The user switches with `/odd-flow --mode organic` (this session only) or `/odd-flow --profile-mode <p> organic` (saved in the profile). It applies from the next request, with no new session: load `mode-organic.md` instead of this file.
