# Worker split panes

Objective: on a wide parent terminal, open Orca workers as split panes, with the parent on the left and workers stacked on the right. Branch: `feature/worker-split-panes`. Delivery: `ask-on-risk`. Runner: `for t in tests/*.sh; do bash "$t"; done`.
Profile: `claude-gpt`.

## Specs

- S1 (user, verbatim): "es posible decirle a orca que dependiendo del ancho del panel (terminal) lance los workers haciendo split del planel? de modo que la sesion principal quede a la izquierda y las sesiones de worksers que vayamos abriendo queden a la derecha una debajo de otra"
- S2 (user, verbatim): "dale", accepting the parent's proposal (verbatim): "El skill divide siempre la pane más alta de la columna derecha: 2 workers: ½ y ½. 4 workers: ¼ cada uno. 3 workers: ¼, ¼ y ½." and "Se usa split solo si el ancho es de 160 columnas o más. Si no, se abre una tab como hasta ahora."
- S3 (accepted proposal, verbatim): "Para tener alturas exactas, usas tu atajo a mano cuando estés en ese tab." The skill never equalizes panes itself.
- S4 (assumption): split placement covers agents with a known pane command: `codex` (`scripts/codex-worker.sh`, as today) and `claude` (`claude --model <m> --effort <e>`, typed into the Orca terminal's shell, which adds Orca's integration). Any other agent keeps `worker-start --agent` in a tab.
- S5 (assumption): the width is the parent terminal's column count, read from the TTY of the nearest ancestor process that has one. Unknown width means a tab. `ODD_FLOW_SPLIT_MIN_COLS` overrides the 160 threshold.
- S6 (assumption): once the right column exists, the next worker splits into it whatever the parent's width (the parent is already narrowed by the column).
- S7 (assumption): `profile.py resolve` keeps every existing field and value; the pane command arrives through one new field, `split_command`.
- S8 (assumption): launches of one parallel batch serialize the layout read and the split with a file lock keyed by the parent terminal handle.
- S9 (assumption): a split pane is cleaned up like today's terminal launch: `worker-release`, then `terminal close` when the handle is still listed.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S1-S9 | `scripts/pane.py`, `split_command` in `profile.py`, tests, `orca-dispatch.md` | orca:write (context trigger) | done | dispatch `ctx_38c90fdb6221`; RED pane-check 9 failing, codex-launch 2 failing; GREEN pane 9/9, codex-launch 27/27, profile 27/27, profile-commands 44/44, init 13/13, context 11/11 (rerun by parent) |
| T2 | S1, S4 | Live check: one Claude and one Codex worker open as split panes and report | inline | done | claude `ctx_a08f9839a8be` split-below, codex `ctx_2719ff2aca19` split-right; both worker_done; panes 36x92 each, parent 75x92; release + close ok |
| T3 | S1-S9 | Independent verification (Risk item 4) | orca:verify (verification trigger) | done | dispatch `ctx_6dcb8f7e9308`: S2 unmet (blocker), S1, S3-S9 met, 7 advisories |
| T4 | S2, S9 | Correction batch: height-share tallest pane, malformed layout error, orphan-pane hint, doc qualifiers | orca:write (context trigger, 205662 tokens) | done | dispatch `ctx_565ef3afbb6d`; RED pane-check 3 failing (term_r4 picked, traceback on tabs:null, no orphan hint); GREEN pane 12/12; parent reran all 8 suites green |

## Log

- L1 (user, 2026-11-23): "vamos a continuar, hasta ahora los workser se lanzan en tabs nuevas, es posible decirle a orca que dependiendo del ancho del panel (terminal) lance los workers haciendo split del planel? de modo que la sesion principal quede a la izquierda y las sesiones de worksers que vayamos abriendo queden a la derecha una debajo de otra"
- L2 (2026-11-23): probes in this Orca (app 1.4.267). `terminal split --direction vertical` puts the new pane to the right (parent 188 -> 92 cols); `--direction horizontal` puts it below (75 -> 36 rows). `terminal list --include-visual-layouts --json` returns the pane tree (`pane-split` nodes with `direction`, `first`, `second`; `terminal` leaves with `handle`). Splitting the last pane each time gave 37/18/8/8 rows.
- L3 (user, 2026-11-23): "para el tema de alturas iguales, veo que al hacer click derecho existe una opcion equaliza pane sizes que iguala el alto de las terminales de la izquierda, quizas puebas probarlo"
- L4 (2026-11-23): "Equalize pane sizes" is the UI keybinding `terminal.equalizePaneSizes`; no CLI, runtime RPC or plugin API exposes it. A background right-click is refused (`background_unavailable`). The user bound it to Cmd+Shift+E; a background `orca computer hotkey` went to the user's focused tab and triggered Show Explorer (same chord) instead. Automatic equalizing dropped (S3).
- L5 (user, 2026-11-23): "dale"
- L6 (2026-11-23): baseline on `e2cf44b`: codex-launch 25/25, context 11/11, init 13/13, profile 27/27, profile-commands 44/44. An Orca-launched Claude runs as `claude --plugin-dir <orca agent view> --model <m>`; the plain `claude` typed in an Orca terminal gets Orca's environment from the shell.
- L7 (2026-11-23): `context.py`: 150456 tokens, writer context trigger holds; T1 goes to a `write` worker.
- L8 (2026-11-23): writer `ctx_38c90fdb6221` done, files within surface. Parent reran all suites green. `pane.parent_cols()` from the parent returned 188, matching `stty -f /dev/ttys013 size` (75 188).
- L9 (2026-11-23): T2 parallel launch via `pane.py`: explore (codex) got `split-right` of the parent, verify (claude) got `split-below` of the explore pane; the lock ordered them. Both `worker-start --terminal` returned ok.
- L10 (2026-11-23): both smoke workers sent `worker_done` (wc -l 181 and 93 match the parent). Pane sizes read from their TTYs: codex ttys015 36x92, claude ttys016 36x92, parent 75x92. The Claude pane runs `claude --plugin-dir <orca agent view> --model claude-opus-5-5 --effort high`: Orca's shell adds its integration. `worker-release` gave `external_terminal`; `terminal close` closed both; parent back to 188 cols. Risk names item 4 (concurrency): verification trigger holds.
- L11 (2026-11-23): session pearleye-f7 fast-forwarded main e2cf44b..3ac993d (full delegation mode: bc37a4f, 3ac993d). This branch needs a rebase before merge; expected overlap in profile.py (orca_line takes a mode) and orca-dispatch.md (Without Orca is mode-neutral). tests/full-delegation-check.sh rejects organic routing phrases outside mode-organic.md; my added dispatch lines contain none. Rebase after T3, before the commit.
- L12 (2026-11-23): verifier report: blocker S2, a vertical split inside the column misleads the depth-based tallest pane (H(V(a,b),H(c,d)) splits d). Advisories: (1) user splitting the parent horizontally gives a tab or a second column; (2) any pane right of the parent counts as the column; (3) 3 workers come out 1/2,1/4,1/4 top to bottom vs the verbatim 1/4,1/4,1/2; (4) tracebacks on malformed layouts; (5) orphan pane when the split reply has no handle; (6) lost doc qualifiers; (7) lock in TMPDIR never removed. Branch moved to main dae9be4 by fast-forward with the tree stashed and restored; all 8 suites green on the merged tree. T4 fixes the blocker and advisories 4-6; 1-3 and 7 go to the user.
- L13 (2026-11-23): T4 done; blocker rechecked through the verifier's regression test (target `term_r2`), passing in the parent's run. Next: user decisions on the 3-worker order (advisory 3) and the commit.
- L14 (user, 2026-11-23): "creo que esta bie nasi" — accepts the 3-worker order 1/2, 1/4, 1/4 top to bottom (advisory 3); S2 heights unchanged.
