# ODD Flow hooks probe

This separate trusted-worker plugin probes what Orca can change or observe without replacing the installed ODD Flow plugin. Hooks fail open on errors or a two-second timeout. They do not intercept human typing or Codex's “Hooks need review” menu. Only Claude Code waits for tool-before decisions. Tool-after only observes.

- **Prompt before:** A prompt containing `ODD-HOOK-PROBE-PROMPT` gets an appended instruction to report `probe-ack: ODD-HOOK-PROBE-ACK`. The original dispatch preamble stays first. Use the sentinel only in dispatches from the probe worktree.
- **Tool before:** In the probe worktree, `odd-hook-probe-deny` in a tool input string denies the call. Otherwise, `odd-hook-probe-rewrite` in a string is replaced with `odd-hook-probe-rewritten`.
- **Launch before:** Launches in the probe worktree get `ODD_HOOK_PROBE=1`; the command is unchanged.

Records go to `<os.tmpdir()>/odd-flow-hooks-probe/events.jsonl` and the worker console (`orca plugin logs local.odd-flow-hooks-probe`). Prompts without the sentinel have no text, length, or terminal metadata in the records. Ungated tool and launch events carry only basic metadata. Gated events can include short command and input excerpts, but no environment values. Tool outputs are recorded only as type and JSON length.

**Coordinate with the hub before loading.** Run the offline tests first. Notify the hub when the probe is loaded and unloaded. Unload as soon as live checks end (within about two hours of loading) and remove the temporary records directory after extracting the evidence.

```sh
orca plugin dev load spikes/orca-hooks-probe --json
orca plugin dev unload spikes/orca-hooks-probe --json
```
