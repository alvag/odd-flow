# Full delegation mode

Objective: let a profile opt into a full delegation orchestrator mode, a peer of today's organic mode, in which the parent never edits repository content and every authorized change goes to a bounded writer; only the active mode's rules reach the context. Branch: `feature/organic-full-delegation`. Delivery: `ask-on-risk`. Runner: `for t in tests/*-check.sh; do bash "$t"; done | grep -E '^FAIL|passed='` (older scripts always exit 0; read their `failed=` count).
Profile: `claude-gpt`.

Design reference: gentle-shell `assets/orchestrator-full-delegation.md`, `assets/orchestrator-full-delegation-card.md`, `lib/orchestrator-mode-policy.ts`, `odd/tasks/full-delegation-mode.md`, `odd/tasks/full-delegation-mode-conflicts.md`.

## Specs

- S1 (user, verbatim): "con esto me permite que el agente con un determinado perfil pueda trabajar de forma organica (como esta implementado hoy odd-flow) y tambien en modo full delegation, quiero que investigues sobre full delegatio en el repo de gentle-shell /Users/max/Personal/repos/gentle-shell y traigamos ese concepto o algo similar a nuestro plugin"
- S2 (user, verbatim, the gentle-shell shape to follow):
  ```
  "workflow": {
      "claude": {
        "orchestratorMode": "full-delegation"
      },
      "gpt-claude": {
        "orchestratorMode": "full-delegation"
      },
      "claude-gpt": {
        "orchestratorMode": "full-delegation"
      },
      "claude-gemini-gpt": {
        "orchestratorMode": "full-delegation"
      }
    }
  ```
- S3 (accepted proposal, verbatim): "Formato: mismo mapa `workflow` que gentle-shell (`{ "<perfil>": { "orchestratorMode": "full-delegation" } }`) en `~/.config/odd-flow/profiles.json`, validado por `profile.py` (valor desconocido → error), más override `ODD_ORCHESTRATOR_MODE`."
- S4 (accepted proposal, verbatim): "Resolución: `profile.py show`/`use` imprimen `mode: organic|full-delegation (source)`."
- S5 (accepted proposal, verbatim): "Contexto: dos core blocks (`core-block.md` / `core-block-full-delegation.md`); el hook elige uno. Lo organic-only de `SKILL.md`, `delegation.md` y `orca-dispatch.md` sale a `references/mode-organic.md` / `references/mode-full-delegation.md`; el Decision Gate carga solo el del modo activo. Un test verifica que ninguna frase organic llegue al modo full."
- S6 (accepted proposal, verbatim): "Cambio en caliente: `--profile B` ya devuelve el modo nuevo y qué referencia cargar; opcionalmente un hook `UserPromptSubmit` que inyecta una línea de modo solo cuando está en full delegation."
- S7 (gentle-shell semantics, carried over): in full delegation the parent never edits repository content (source, tests, docs, fixtures, configuration), whatever the size; it keeps authorize, explore for routing, decide, ask, track, commit, verify (one spot check) and report. Task size decides tracking and risk only, never who writes. Without Orca the writer runs as a subagent; when no writer can run, the parent reports the blocker and never edits. After a writer exhausts its correction bound, the parent relaunches a bounded writer with the diagnosis, never fixes inline. `## Allowed edit surfaces` stays mandatory for every writer.
- S8 (assumption): a profile without a `workflow` entry, an absent file and no override all resolve to `organic`. The organic core block stays byte-identical and the organic rules keep their content (they may move between files); the only new organic context is the `mode:` line S4 asks for.
- S9 (assumption): the context trigger (`scripts/context.py`) and the "Writer: parallel" and "Writer: context" triggers belong to organic mode only; full delegation never tells the parent to work inline.
- S10 (accepted proposal, user: "si, dale"): changing a profile's mode. `/odd-flow --profile-mode <p> <organic|full-delegation>` runs `profile.py mode <p> <mode>` as a dry run, shows the diff of the `workflow` map, and writes only after the user confirms (`--yes`), like `--profile-default`. `/odd-flow --mode <organic|full-delegation>` sets the mode for this session only, in the session binding, without touching the file. `--profiles` shows each profile's mode; `--create-profile` asks the mode as its last question, recommending `organic`. Resolution order: `ODD_ORCHESTRATOR_MODE`, then the session `--mode`, then the profile's `workflow` entry, then `organic`.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S2-S4, S8 | `profile.py`: validate the `workflow` map, resolve the mode with its source, print it in `show`, `use` and `list`; tests | inline | done | RED `tests/mode-check.sh` 28 failing; GREEN 35/35, 37/37 after the verify corrections; `bc37a4f` |
| T2 | S10 | `profile.py set-mode` (dry run, `--yes`), `session-mode`, `mode`; skill commands in `SKILL.md` and `profiles.md`; tests | inline | done | same RED/GREEN as T1; `bc37a4f` (script), `3ac993d` (skill commands) |
| T3 | S5, S8 | `core-block-full-delegation.md`; `session-start.py` picks the block by mode; tests | inline | done | RED `tests/full-delegation-check.sh` 31 failing; GREEN 46/46, 53/53 after the verify corrections; `3ac993d` |
| T4 | S5, S7, S9 | Move organic-only rules out of `SKILL.md`, `delegation.md`, `orca-dispatch.md`, `review.md`, `odd-protocol.md` into `references/mode-organic.md`; write `references/mode-full-delegation.md`; mode gate in `SKILL.md`; closure test | inline | done | closure and organic-preservation checks in `tests/full-delegation-check.sh`; `3ac993d` |
| T5 | S6 | `use` output names the new mode and its reference; `UserPromptSubmit` mode line | inline | done | `scripts/prompt-submit.py`, `hooks/hooks.json`; checks in `tests/full-delegation-check.sh`; `3ac993d` |
| T6 | S3, S10 | `README.md`, `profiles.md` and `assets/profiles.example.json` document the mode | inline | done | `claude plugin validate .` passed; `bc37a4f` (example), `3ac993d` (docs) |

## Log

- L1 (user, 2026-11-23): "quiero que revisemos algo, en losperfiles de gentle-shell tenemos esto [S2 block] con esto me permite que el agente con un determinado perfil pueda trabajar de forma organica (como esta implementado hoy odd-flow) y tambien en modo full delegation, quiero que investigues sobre full delegatio en el repo de gentle-shell /Users/max/Personal/repos/gentle-shell y traigamos ese concepto o algo similar a nuestro plugin"
- L2 (user, 2026-11-23): "dale, arma el feature doc con ese diseño pero como hariamos para cambiar el modo de un perfil?"
- L3 (2026-11-23, evidence): `profile.py` `validate_doc` rejects any key inside a profile that is not a role (`skills/odd-flow/scripts/profile.py:137`), the same constraint that put gentle-shell's flag in a sibling `workflow` map (gentle-shell `odd/tasks/full-delegation-mode.md` L4). The sibling map fits as is.
- L4 (2026-11-23, evidence): the core block reaches the session only through `scripts/session-start.py` on `startup|resume|clear|compact`; a mid-session `--profile` does not re-inject it, so S6 needs its own path.
- L5 (2026-11-23, evidence): organic-only rules live today in `SKILL.md` Hard Rule 1, the writer triggers in `delegation.md`, the inline fallback in `orca-dispatch.md` (Without Orca, commit `ff33fea`) and "fix inline when small" in `delegation.md` Correction bounds.
- L6 (2026-11-23): risk forecast: item 3 (config format and core context consumed by every session); the organic path must stay byte-identical (S8). Verification trigger expected at close.
- L7 (2026-11-23): next step was to confirm S10 with the user.
- L8 (user, 2026-11-23): "si, dale" (S10 accepted; start T1).
- L9 (2026-11-23, decision): `use <profile>` drops a session `--mode` override, so switching profile always applies the new profile's mode (S6); `set-mode <p> organic` removes the profile's `workflow` entry instead of writing the default, and drops an empty `workflow` map.
- L10 (2026-11-23, decision): the mode commands are `profile.py set-mode <p> <mode>` (file, dry run unless `--yes`), `session-mode <mode>` (session binding) and `mode [--json]` (read only, used by both hooks). The `UserPromptSubmit` line is written as facts, as the Claude Code hooks docs advise for `additionalContext` (checked through Context7, `/websites/code_claude`).
- L11 (2026-11-23, evidence): the closure check caught two organic phrases the first pass missed, "Write it inline" in `review.md` and "works inline" in `profiles.md`; both reworded, and the pattern list now covers "it inline".
- L12 (2026-11-23, differential): organic `session-start.py` output, base `HEAD` vs change, with the same profiles file: the only difference is the added line `mode: organic (default); rules: references/mode-organic.md` (S4).
- L13 (2026-11-23, known limit): runtimes that get the core block through `init.py` keep the organic block; in full delegation there, the mode file is the only source of the mode's rules. Recorded in `profiles.md`; not fixed in this feature.
- L14 (2026-11-23): suites: codex-launch 25/25, context 11/11, full-delegation 46/46, init 13/13, mode 35/35, profile 24/24, profile-commands 44/44; `claude plugin validate .` passed. Risk: item 3 (profiles file format, `profile.py` output read by the skill, and the core context of every session). Verification trigger holds; launching `verify`.
- L15 (2026-11-23, verify `ctx_a9f6c82fcd25`): 2 blockers. B1 (S5): `tracking.md:11` and `assets/feature-doc-template.md:16` still offered the organic `inline` route to full delegation, unseen by the closure check. B2 (S10): with `ODD_ORCHESTRATOR_MODE=full-delegation` and an invalid profiles file, both hooks fell back to organic because `cmd_mode` loaded the file before reading the override. Ten advisories; A3 and A4 taken, the rest recorded in the report (`.../21822483-.../scratchpad/verify-full-delegation.md`). Unverified: a live Claude Code run of the hooks and the skill flows.
- L16 (2026-11-23): one correction batch: routes defer to the mode files (each now lists its routes), template uses `<route>`; `env_mode()` resolved before the file in `cmd_mode`; A3 wording "before the first source write or writer launch"; A4 error names `ODD_ORCHESTRATOR_MODE`. RED 6 + 1 failing, GREEN full-delegation 53/53, mode 36/36, other suites unchanged. Recheck limited to B1/B2 sent as `ctx_18548d5d4fdd`.
- L17 (2026-11-23, recheck `ctx_18548d5d4fdd`): B1 met, B2 met, no blockers. R1 (regression of the B2 fix): with the override set, `mode --json` reported `profile: null` on a valid file. Fixed: the profile is still read, and an invalid file only leaves it null. RED 1 failing, GREEN mode 37/37; full-delegation 53/53, codex-launch 25/25, context 11/11, init 13/13, profile 24/24, profile-commands 44/44; `claude plugin validate .` passed. Still unverified: a live Claude Code session running the `UserPromptSubmit` hook and the `--mode`, `--profile-mode`, `--create-profile` flows.
- L18 (2026-11-23): user approved both commits ("si, haz los dos commits"): `1bd878a` (feat: add per-profile orchestrator mode to profile.py; `profile.py`, `tests/mode-check.sh`, `assets/profiles.example.json`) and `f0f79f5` (feat: run full delegation mode from the hooks and skill; hooks, mode files, skill split, docs, `tests/full-delegation-check.sh` and this document). Both were later rebased (L20).
- L19 (user, 2026-11-23): "hay otra sesion de claude code corriendo en este worktree coordina con esa sesion el pase a main". Asked the three peer sessions; none was in this worktree or merging to main. `odd-flow-c8` works on `feature/worker-split-panes` (uncommitted) in the main checkout and also touches `profile.py` and `orca-dispatch.md`.
- L20 (2026-11-23): `main` had moved to `e2cf44b` (fix: harden the orca fallback after review). Rebased onto it, pre-rebase copy kept as branch `backup/organic-full-delegation-prerebase`. Three conflicts, each keeping `main`'s change and making it mode-neutral: `profile.py` `orca_line(mode)` keeps the malformed-handle line and drops "or inline" in full delegation; `orca-dispatch.md` keeps model and effort in the subagent fallback and the report checks, with notice and route deferring to the mode file; `review.md` keeps "a `refute` the parent runs itself never demotes a finding", without "run inline". New hashes: `bc37a4f` (was `1bd878a`) and `3ac993d` (was `f0f79f5`). Suites on `3ac993d`: codex-launch 25/25, context 11/11, full-delegation 53/53, init 13/13, mode 37/37, profile 27/27, profile-commands 44/44; `claude plugin validate .` passed. `main` fast-forwarded `e2cf44b..3ac993d`, not pushed; `odd-flow-c8` told to rebase onto it. The conflict resolution was not re-verified by an independent worker.
- L21 (user, 2026-11-23): "corrige el feature doc". Recorded the rebased hashes per task, final GREEN counts, L18-L20, and removed an extra empty cell in rows T2-T6.
- L22 (next step): push and a live Claude Code check of the `UserPromptSubmit` hook and the `--mode`, `--profile-mode` and `--create-profile` flows stay with the user.
