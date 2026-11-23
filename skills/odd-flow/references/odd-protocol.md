# ODD protocol

Run these steps in order on every request.

## 1. Authorize

- Investigation, explanation, review, audit, comparison and proposal requests are read-only: no file writes, no writer workers, no implementation artifacts.
- Ambiguous or conditional change intent gets one clarification question; stay read-only until answered.
- Hedged wording ("I may stop you", "we resume later") asks for notes and separate commits, not a stop.

## 2. Explore

- Explore proportionately, before proposing or writing.
- Explore only for a map you need to decide or route. Never explore files you will read anyway before writing inline.
- Inline evidence budget: one parallel batch, at most 3 calls, about 10k tokens. Beyond that, the mapping trigger holds (`delegation.md`).

## 3. Resolve uncertainty

- Recommend research only for a named uncertainty.
- At most one scoped read-only challenge of a high-consequence unproven premise; no debate loops.
- Ask the user only for a real product or scope decision, one question at a time, then stop and wait.

## 4. Classify

Small when all three hold:

1. Understood: outcome, location and approach are known; no open product decision.
2. Contained risk: no high-risk item below.
3. Resumable from the diff: someone could finish from the original request plus `git diff`.

Large only when the resume test fails: several sessions, an external wait, deliverables the user wants apart, or requirements long enough to be lost to compaction. File, command, test or line counts never decide size.

Small path: inline; RED before the fix when a test applies; focused test and suite once each; no feature document, no workers, no commits unless asked.

### High-risk items

1. Data or irreversible effects: migrations, rewriting or deleting stored data, persisted format changes.
2. Security: auth, permissions, credentials, secrets, guards, sandbox.
3. Contracts others consume: changing or removing public API, CLI flags, config formats, exports; unrequested changes in shared code. Adding a flag or optional field is not.
4. Concurrency: locks, races, async ordering.
5. Delivery or environment: installers, release, CI, deploy, dependencies.
6. No test would catch a regression in what changes.

"Unclear" counts as high only when a bounded look cannot tell whether items 1-5 apply.

## 5. Track (large only)

Load `tracking.md` and create the feature document before the first source write. Tell the user in one line which document was created and how many tasks it holds.

## 6. Implement

- Before the first write of each unit, run `scripts/context.py`; if it reports `holds`, load `delegation.md` (Writer: context).
- Test-first when a runnable deterministic test and a clear expected outcome exist: RED, GREEN, refactor. One RED test per requested rule; one preservation test per existing command or option the change touches; no other cases. Otherwise state the exception and run proportionate checks.
- Differential check when the diff changes shared code that an unrequested command also uses: run that command against a base copy in `mktemp -d` and against the change; compare stdout, stderr, exit code. Any unrequested difference is a regression to fix and pin.
- Tests assert every observable effect through the public interface. A user-reported failure is reproduced before deciding it already works.
- Update help text and docs when a command, option or message changes.
- Keep scratch outside the worktree (`mktemp -d`).

## 7. Close

- Report verified outcome, every failed, skipped or pending check, and the next step.
- Before `Risk: none`, check whether the diff changes code that unrequested behavior also uses; if so, that is item 3.
- A launched Orca worker is a wait event: end the turn and resume when Orca wakes you. A subagent fallback returns its report to the parent directly. Only a human decision, an explicit stop, a denial, missing consent or an exhausted limit stops the affected work.
