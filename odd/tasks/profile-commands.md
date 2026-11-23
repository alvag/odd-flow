# Profile commands and guided profile creation

Objective: manage profiles from the skill with four commands and a guided creation flow, while the script stays the only writer. Branch: `feature/profile-commands`. Delivery: `ask-on-risk`. Runner: `bash tests/profile-commands-check.sh && bash tests/profile-check.sh && bash tests/codex-launch-check.sh && bash tests/init-check.sh`.
Profile: `claude-gpt`.

## Specs

- S1 (user, verbatim): "dale, impleméntalo así", accepting the parent's proposal quoted in S2-S6.
- S2 (accepted proposal, verbatim): "`--profile <p>` | Vincula el perfil a esta sesión (`profile.py use`)"
- S3 (accepted proposal, verbatim): "`--profile-default <p>` | Escribe `default` en el archivo, después de mostrar el diff"
- S4 (accepted proposal, verbatim): "`--profiles` | Lista los perfiles, marca el activo y su origen, y te pregunta si quieres elegir uno para la sesión, como default o ninguno"
- S5 (accepted proposal, verbatim): "`--create-profile <p>` | El wizard del punto 1": "El script (`profile.py`): un comando `discover` que devuelve en JSON lo que pueda encontrar y marca qué está verificado, y un comando `save` que valida el perfil, muestra el diff y escribe de forma atómica." and "La skill: arma el wizard. Pregunta rol por rol con las opciones descubiertas y sugiere valores por rol (explore barato, verify y review fuertes). Solo escribe después de que confirmes el diff, igual que la Hard Rule 8 para `init`."
- S6 (accepted proposal, verbatim): "Los comandos de hoy (`/odd-flow <perfil>` y `/odd-flow profiles`) los quitaría."
- S7 (accepted proposal, verbatim): "como skill de plugin, hoy se invoca como `/odd-flow:odd-flow`, no `/odd-flow`. No sé si Claude Code acepta la forma corta cuando el nombre no choca con otro. Lo pruebo antes de documentarlo."
- S8 (assumption): `save` and `default` are dry runs that print the diff unless `--yes` is given; `save` refuses to overwrite an existing profile unless `--replace`. Keys the script does not know are kept.
- S9 (assumption): `discover` reports Orca agents from `orca agent installed --json`, Codex models and efforts from `$CODEX_HOME/models_cache.json` (verified), and a built-in Claude list marked unverified; other agents report no models.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S3, S5, S8, S9 | `profile.py` `discover`, `save`, `default`, with tests | inline | done | RED 20 failing, GREEN `tests/profile-commands-check.sh` 27/27; profile 20/20, codex-launch 25/25, init 13/13 |
| T2 | S2-S6 | Skill commands, wizard flow and Hard Rule 8 in `SKILL.md` and `profiles.md` | inline | done | no old command form left in `skills/` |
| T3 | S7 | Check whether `/odd-flow` short form works; document the real invocation | inline | done | headless: `/odd-flow:odd-flow --profiles` injected the skill; `/odd-flow --profiles` did not |

## Log

- L1 (user, 2026-11-23): "dale, impleméntalo así"
- L2 (2026-11-23): the first `default` dry run reformatted the whole hand-written file, hiding the real change; `format_doc` now writes one line per role, so on a compact file the diff holds only the change (pinned by a test).
- L3 (2026-11-23): `claude -p` with Haiku and no tools: `/odd-flow --profiles` reached the model as plain text (no skill body in the stream); `/odd-flow:odd-flow --profiles` loaded the skill. Interactive sessions not checked.
- L4 (2026-11-23): Risk line names item 1 (writes the user profiles file) and item 3 (removes `/odd-flow <profile>` and `/odd-flow profiles`, as S6 asks): verification trigger holds.
- L5 (2026-11-23): verify `ctx_f63f33f108fe`: 2 blockers (discover traceback on an unexpected Codex cache shape; S5 "rol por rol" lost to a single table). One correction batch fixed both plus advisories (non-ASCII kept, mode and symlink kept, fsync, odd-flow errors instead of tracebacks, no rewrite when already default, doc claims scoped to the headless check). Recheck `ctx_a1d484ba0515`: both blockers met. Suites: profile-commands 44/44, profile 20/20, codex-launch 25/25, init 13/13, context 11/11.
- L6 (2026-11-23): T1-T3 committed in `b0ed754` (feat: add profile commands and guided profile creation); the context measurement that came up during this feature is `0adeab9`.
