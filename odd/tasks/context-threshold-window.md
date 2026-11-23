# Context threshold from the model window

Objective: derive the writer context trigger threshold from the model's context window instead of a fixed 150k. Branch: `feature/role-prompts` (shared with this session's backlog; own commit). Delivery: `ask-on-risk`. Runner: `bash tests/run.sh`.
Profile: `claude-gpt`.

## Specs

- S1 (user, verbatim, backlog item 3 from the previous session): "calcular el umbral de contexto a partir de la ventana del modelo, en vez de usar un valor fijo"
- S2 (user choice, 2026-11-23, verbatim option): "150k + override (Recommended)", described as: "Fórmula min(150k, 15%·ventana). Ventana desconocida → 150k como hoy (igual que gentle-shell). Variable opcional ODD_FLOW_CONTEXT_WINDOW para declarar la ventana a mano. Sin adivinar modelos."
- S3 (evidence, explorer E3): gentle-shell `lib/context-backstop.ts:38-42` computes `min(cap, max(1, floor(fraction * contextWindow)))` with cap 150,000 and fraction 0.15; an unknown window keeps the cap. odd-flow `skills/odd-flow/scripts/context.py` already reads Codex `info.model_context_window` (`:72-79`); Claude Code transcripts carry only the model id (`claude-opus-5-5`), no window.
- S4 (assumption): threshold = `min(150000, max(1, floor(0.15 * window)))` when a window is known, else 150000. No model-id table.
- S5 (assumption): `ODD_FLOW_CONTEXT_WINDOW`, when set to a positive integer, is the window and wins over the runtime-reported one. Empty or unset: ignored. Any other value: ignored, with one warning line on stderr naming the variable; exit stays 0 (a measurement never blocks work).
- S6 (assumption): the JSON output keeps every field (`tokens`, `window`, `threshold`, `holds`, `source`, `reason`); `window` is the window used and `threshold` the computed value; one optional field `window_source` is added: `"runtime"`, `"ODD_FLOW_CONTEXT_WINDOW"` or `null`. The text line keeps its shape and prints the computed threshold. With no known window every output is unchanged from today.
- S7 (assumption): gentle-shell's "re-arm after compaction" needs no code here: `context.py` is stateless, so a lower token count after compaction already stops the trigger. `references/mode-organic.md` states the formula, the unknown-window fallback and the override, replacing "whatever the model's window"; the test that pins that sentence follows the new wording; the module docstring says the same.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S1-S7 | `context.py` threshold from window and override, tests in `tests/context-check.sh`, `mode-organic.md` and its pinned sentence in `tests/full-delegation-check.sh` | orca:write (full delegation, parallel with pane-width-race T1: disjoint surfaces) | done | dispatch `ctx_2ed91abef800`; 4 files within surface (+71/-9); writer RED 6 fails, GREEN context-check 17/17, full-delegation 53/53, run.sh 9/9, Claude text line byte-identical to base; parent reran context-check: passed=17 failed=0 and read the diff |

## Log

- L1 (user, 2026-11-23): "continuemos con el backlog de odd-flow"
- L2 (2026-11-23): backlog item 3 of Engram #8307. Explorer E3 dispatches `ctx_29c80e05a5dc`, `ctx_3da6d7511ed2`. The user picked the unknown-window policy in S2.
- L3 (2026-11-23): consequence to report: a Codex parent with a 258,400-token window gets a threshold of 38,760, so in organic mode it delegates much earlier than today; Claude parents keep 150k unless `ODD_FLOW_CONTEXT_WINDOW` is set. Risk: none of items 1-5 (an added optional field and env var); covered by `tests/context-check.sh`, so no independent verify unless the diff shows otherwise.
