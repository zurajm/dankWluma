# AGENTS.md

Guidance for coding agents working in this repository. Humans: read `README.md` instead.

## What this is

`dankWluma` is a [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)
(DMS) plugin that surfaces and controls the
[wluma](https://github.com/maximbaz/wluma) adaptive-brightness daemon. It ships three
surfaces from one `PluginComponent`: a Control-Center tile with expandable detail, a
DankBar pill with popout, and a settings page. Developed against dms-shell 1.6.2 /
quickshell 0.3.1 / niri.

## Hard invariants — never violate these

1. **Every mutation goes through the `wluma` CLI.** Never write `/sys/class/backlight/*`
   or DDC/i2c directly. wluma ingests every external brightness change as a training
   sample for its predictor; a direct write changes hardware without teaching it, which
   is precisely the failure this plugin exists to prevent.
2. **Never touch `~/.local/state/wluma/`** — especially the
   `xdg-desktop-portal-screencast-*.token` files. Deleting them breaks the user's capture
   permissions.
3. **No UI for `wluma set dim` or `wluma set temperature`.** Both are no-ops on niri
   (gamma control is rejected by the compositor); UI for them would be a silent lie.
4. **No stale values, ever.** On any disconnect the snapshot is dropped and the UI shows
   an unavailable state. A reconnect must prime fresh state before anything renders.
5. **Never send an output name that is not in the latest snapshot.** The daemon
   hard-errors on unknown names. `_dispatch()` enforces this; keep it that way.
6. **Keep `services/wluma.js` Qt-free and total.** All parsing, normalisation, filtering
   and argument construction live there; every function handles malformed input without
   throwing, because `parseStatusLine` runs on the GUI thread for every daemon event.
   It is the test seam — logic added anywhere else is untestable by construction.

## Architecture

```
plugin.json              manifest (permissions: process, settings_read, settings_write)
qmldir                   registers WlumaService as a plugin-local singleton
DankWluma.qml            PluginComponent: control-center tile, bar pills, popout
DankWlumaSettings.qml    settings page (PluginSettings; auto-store *Setting blocks)
WlumaPanel.qml           panel body shared by the CC detail view and the popout
OutputRow.qml            one output: badges, luma, slider, ±5% buttons
WlumaChip.qml            status pill, adapted from DankClight's StatusChip.qml
services/WlumaService.qml  process lifecycle only: prime, stream, queue, backoff
services/wluma.js        pure logic (parsing / normalisation / args) — unit-tested
tests/wluma.test.mjs     bun test suite; loads the real wluma.js by stripping its pragma
```

Data flow: `wluma status --json` primes state once at startup and after every reconnect
(`watch` emits only on change, so without the prime the widget starts blank);
`wluma watch --json` then streams the complete status object as one JSON line per event
through `Process { stdout: SplitParser }`; each line replaces the snapshot wholesale.
Mutations queue through a single-flight `Process` that coalesces absolute brightness
writes per output, so a slider drag cannot fork a process storm.

The liveness probe (10s `wluma status --json`) is load-bearing, not defensive:
**`wluma watch` does not exit when the daemon dies** — the client process outlives
`systemctl --user stop wluma` — so process exit cannot detect an outage. Do not remove
the probe, and do not "simplify" the supervision into relying on `onExited`.

## Working in this repo

```sh
bun test                                   # the only test command; must stay green
dms ipc call plugins reload dankWluma      # reloads widget components
systemctl --user restart dms               # needed for: edited QML, ANY singleton change
```

Gotchas verified the hard way on this machine (dms-shell 1.6.2):

- `plugins reload` is unreliable for edited QML and **never** re-instantiates a
  `pragma Singleton` registered via the plugin's `qmldir` — not even across a
  disable/enable cycle. If a change "did not take effect", restart the shell before
  doubting your code.
- A brand-new plugin directory must be registered with
  `dms ipc call plugin-scan scan` before `plugins enable <id>` accepts it.
- Control-Center widget ids are prefixed (`plugin_dankWluma` in
  `SettingsData.controlCenterWidgets`); DankBar `rightWidgets` uses the bare id.
- `dms ipc call settings set` refuses arrays and objects; write list-valued settings by
  atomic direct edit of `~/.config/DankMaterialShell/settings.json` (file-watched,
  hot-reloads; take a backup first).
- QML `console.log` is filtered out of the journal. Use `console.warn`.
- The shell's QML source (authoritative API + author docs in `PLUGINS/`) is extracted
  per boot to `/run/user/1000/danklinux-shell/<hash>/` — the hash changes across
  reboots; find it via `pgrep -ax qs`.
- `wluma` subcommands have no `--help`; a bad usage just prints the global help or an
  error mentioning the offending output name.

## Verifying changes on the real surface

Unit tests are necessary, never sufficient. The deliverable renders in the user's live
shell, so after behavior changes:

1. `bun test` green.
2. Restart or reload as needed, then check
   `journalctl --user -u dms -f` — zero QML errors attributable to the plugin.
3. Screenshot the real render (`grim -o <output>`, crop with `magick`) and compare
   values against `wluma status --json` from the same minute.
4. For brightness/pause changes, prove the hardware path: `ddcutil getvcp 10` for the
   DDC display, `/sys/class/backlight/intel_backlight/brightness` for the panel — and
   restore the pre-test values afterwards.

## Conventions

- Conventional Commits (`feat|fix|docs(wluma): ...`), one atomic commit per verified
  increment, no WIP on `main`.
- Match the existing code style: QML follows the DMS plugin idioms (see DankClight),
  JS in `wluma.js` is ES2017-safe (Qt's engine), tests are given/when/then-flavoured
  bun tests.
