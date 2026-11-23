# Codex worker launch path

Objective: let Codex Orca workers report to the parent without changing the user's global Codex config. Branch: `feature/codex-worker-launch`. Delivery: `ask-on-risk`. Runner: `bash tests/codex-launch-check.sh && bash tests/profile-check.sh && bash tests/init-check.sh`.
Profile: `claude-gpt`.

## Specs

- S1 (user, verbatim): "dale, impleméntalo así", accepting the parent's proposal quoted in S2-S4.
- S2 (accepted proposal, verbatim): "Ruta de Codex en odd-flow: cuando `profile.py resolve` dé `agent: codex`, `orca-dispatch.md` usa esta ruta. Un script del plugin arma el comando en vez de que el modelo lo escriba a mano. Lleva tests y su paso de cleanup de la terminal."
- S3 (accepted proposal, verbatim): "Heredoc: `commit.md` pasa a usar `git commit -F <archivo>`."
- S4 (accepted proposal, verbatim): "`NOTES.md`: registrar los hallazgos de esta prueba."
- S5 (accepted proposal, verbatim): "aceptando que las workers de Codex queden con red saliente abierta". Codex workers get `-c sandbox_workspace_write.network_access=true`, nothing wider.
- S6 (assumption): the launcher reproduces the argv Orca itself uses for Codex workers (observed with `ps` on 2026-11-23), adds only the sandbox override, and never touches `~/.codex/config.toml`.
- S7 (assumption): `profile.py resolve` keeps its existing fields and flags unchanged for every agent; the Codex path is announced through new fields only.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S2, S5-S7 | Launcher script, `resolve` launch fields, tests | inline | done | RED 16 failing, GREEN `tests/codex-launch-check.sh` 22/22; profile 20/20, init 13/13 |
| T2 | S2 | `orca-dispatch.md` Codex path and terminal cleanup | inline | done | end-to-end T4 `ctx_5da92908705a` succeeded; release + close verified |
| T3 | S3 | `commit.md` uses `git commit -F` | inline | done | no heredoc left in `skills/` |
| T4 | S4 | `NOTES.md` findings | inline | done | Open items updated |

## Log

- L1 (user, 2026-11-23): "dale, impleméntalo así"
- L2 (2026-11-23): smoke test evidence: Codex worker via `worker-start --agent codex` fails `orca orchestration send` with `runtime_access_denied` (EPERM); the same worker launched with `-c sandbox_workspace_write.network_access=true` through `orca terminal create` plus `worker-start --task --terminal` reported `worker_done` (dispatch `ctx_a4aa3f292faf`, outcome `succeeded`).
- L3 (2026-11-23): `worker-release` on that dispatch returned `state=retained reason=external_terminal processAction=none`; the terminal was already gone (`ps -p 34015` empty, not in `orca terminal list`). Who closed it is unverified.
- L4 (2026-11-23): end-to-end with the documented path: `resolve explore` gave `launch: terminal`; `task-create` without `--run` joined the existing Run; worker `ctx_5da92908705a` sent `worker_done` (395 lines, matches `wc -l`). `worker-release` returned `reason=external_terminal`; the terminal was still listed and `terminal close` removed it (`ptyKilled: true`).
- L5 (2026-11-23): Risk line names item 2 (sandbox): verification trigger holds; next a `verify` worker, then the commit.
- L6 (2026-11-23): verify worker `ctx_a332fecf6613` (claude-opus-5-5, high): S1-S7 met, no blockers. Fixed three advisories: the launcher refuses empty and option-like arguments (it took `"" high` as `-m high`); `orca-dispatch.md` passes `terminal_command` through a variable so the parent shell never re-expands it, and keeps the `taskId` on a failed start; `NOTES.md` records the bypassed Orca shell function and the unpinned sandbox mode. Suites: codex-launch 25/25, profile 20/20, init 13/13; `claude plugin validate .` passed.
- L7 (2026-11-23): T1-T4 committed in `3dd52f1` (feat: launch codex workers through an orca terminal).
