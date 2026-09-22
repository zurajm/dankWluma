// Unit tests for services/wluma.js — the pure, Qt-free logic layer of DankWluma.
//
// wluma.js is a QML `.pragma library`, so it has no ES exports. We load it the way
// QML does (as a script) and lift its declarations out of a function scope. This runs
// the real shipped file: no mock, no copy, no re-implementation.

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const LIB = join(dirname(fileURLToPath(import.meta.url)), "..", "services", "wluma.js");

const API = [
  "parseStatusLine",
  "normalizeStatus",
  "selectOutputs",
  "isKnownOutput",
  "setBrightnessArgs",
  "stepBrightnessArgs",
  "pauseArgs",
  "resumeArgs",
  "isValidDuration",
  "backoffDelay",
  "summaryText",
  "brightnessIcon",
  "outputIcon",
];

function loadLib() {
  const src = readFileSync(LIB, "utf8").replace(/^[ \t]*\.pragma[ \t]+library[ \t]*$/m, "");
  return new Function(`${src}\n;return {${API.join(",")}};`)();
}

const W = loadLib();

// Verbatim capture from `wluma status --json` on this machine, 2026-09-21.
const LIVE_LINE =
  '{"als":{"type":"webcam","value":31},"idle":{"power_source":"ac","state":"active","enabled":true,"timeout":120,"brightness":30},"outputs":[{"name":"DP-7","type":"ddc","capturer":"xdg-desktop-portal-screencast","luma":26,"brightness":1,"dim":null,"temperature":null,"state":"active","paused":false,"idle":false},{"name":"asus::kbd_backlight","type":"keyboard","capturer":null,"luma":null,"brightness":0,"dim":null,"temperature":null,"state":"active","paused":false,"idle":false},{"name":"eDP-1","type":"backlight","capturer":"xdg-desktop-portal-screencast","luma":50,"brightness":5,"dim":null,"temperature":null,"state":"active","paused":false,"idle":false}]}';

describe("parseStatusLine", () => {
  test("parses the verbatim live status line", () => {
    const r = W.parseStatusLine(LIVE_LINE);
    expect(r.ok).toBe(true);
    expect(r.status.als).toEqual({ type: "webcam", value: 31, available: true });
    expect(r.status.idle).toEqual({
      powerSource: "ac",
      onBattery: false,
      state: "active",
      enabled: true,
      timeout: 120,
      brightness: 30,
      dimming: false,
    });
    expect(r.status.outputs).toHaveLength(3);
  });

  test("normalizes each output, preserving nulls as nulls", () => {
    const { status } = W.parseStatusLine(LIVE_LINE);
    const byName = Object.fromEntries(status.outputs.map((o) => [o.name, o]));

    expect(byName["DP-7"]).toEqual({
      name: "DP-7",
      kind: "ddc",
      capturer: "xdg-desktop-portal-screencast",
      luma: 26,
      hasLuma: true,
      brightness: 1,
      state: "active",
      paused: false,
      idle: false,
      isKeyboard: false,
      icon: "monitor",
    });

    // The keyboard entry is the schema's odd one out: luma and capturer are null.
    expect(byName["asus::kbd_backlight"]).toEqual({
      name: "asus::kbd_backlight",
      kind: "keyboard",
      capturer: null,
      luma: null,
      hasLuma: false,
      brightness: 0,
      state: "active",
      paused: false,
      idle: false,
      isKeyboard: true,
      icon: "keyboard",
    });

    expect(byName["eDP-1"].icon).toBe("laptop");
    expect(byName["eDP-1"].brightness).toBe(5);
  });

  test("battery power source flips onBattery", () => {
    const line = LIVE_LINE.replace('"power_source":"ac"', '"power_source":"battery"');
    expect(W.parseStatusLine(line).status.idle.onBattery).toBe(true);
  });

  test("a non-active idle state means the daemon is dimming", () => {
    const line = LIVE_LINE.replace('"state":"active","enabled"', '"state":"idle","enabled"');
    expect(W.parseStatusLine(line).status.idle.dimming).toBe(true);
  });

  test("paused and idle flags survive parsing", () => {
    const line = LIVE_LINE.replace('"paused":false,"idle":false', '"paused":true,"idle":true');
    const dp7 = W.parseStatusLine(line).status.outputs.find((o) => o.name === "DP-7");
    expect(dp7.paused).toBe(true);
    expect(dp7.idle).toBe(true);
  });

  test("rejects an empty or whitespace-only line without throwing", () => {
    expect(W.parseStatusLine("")).toEqual({ ok: false, reason: "empty" });
    expect(W.parseStatusLine("   \t ")).toEqual({ ok: false, reason: "empty" });
    expect(W.parseStatusLine(null)).toEqual({ ok: false, reason: "empty" });
  });

  test("rejects a truncated JSON line without throwing", () => {
    const r = W.parseStatusLine('{"als":{"type":"web');
    expect(r.ok).toBe(false);
    expect(r.reason).toBe("parse");
  });

  test("rejects valid JSON of the wrong shape", () => {
    expect(W.parseStatusLine("null").reason).toBe("shape");
    expect(W.parseStatusLine("[]").reason).toBe("shape");
    expect(W.parseStatusLine('"a string"').reason).toBe("shape");
    expect(W.parseStatusLine("42").reason).toBe("shape");
  });

  test("never throws on hostile input", () => {
    const hostile = [
      undefined,
      "{",
      "}",
      "[{}",
      '{"outputs":null}',
      '{"outputs":[null]}',
      '{"outputs":[{}]}',
      '{"outputs":"nope"}',
      '{"als":[]}',
      '{"idle":7}',
      "\u0000",
      "{}".repeat(500),
    ];
    for (const input of hostile) {
      expect(() => W.parseStatusLine(input)).not.toThrow();
    }
  });

  test("drops output entries with no usable name but keeps the rest", () => {
    const line =
      '{"outputs":[{"type":"ddc","brightness":5},{"name":"eDP-1","type":"backlight","brightness":7,"luma":50,"paused":false,"idle":false,"state":"active","capturer":null,"dim":null,"temperature":null}]}';
    const r = W.parseStatusLine(line);
    expect(r.ok).toBe(true);
    expect(r.status.outputs.map((o) => o.name)).toEqual(["eDP-1"]);
  });

  test("an unknown output type still parses, with a fallback icon", () => {
    const line =
      '{"outputs":[{"name":"HDMI-A-1","type":"quantum-crystal","brightness":42,"luma":null,"paused":false,"idle":false,"state":"active","capturer":null,"dim":null,"temperature":null}]}';
    const out = W.parseStatusLine(line).status.outputs[0];
    expect(out.kind).toBe("quantum-crystal");
    expect(out.icon).toBe("display_settings");
    expect(out.isKeyboard).toBe(false);
  });

  test("a status with no als and no idle block yields safe defaults", () => {
    const r = W.parseStatusLine('{"outputs":[]}');
    expect(r.ok).toBe(true);
    expect(r.status.als.available).toBe(false);
    expect(r.status.idle.enabled).toBe(false);
    expect(r.status.outputs).toEqual([]);
  });
});

describe("selectOutputs", () => {
  const status = W.parseStatusLine(LIVE_LINE).status;

  test("hides the keyboard backlight by default and sorts panel before external", () => {
    expect(W.selectOutputs(status, {}).map((o) => o.name)).toEqual(["eDP-1", "DP-7"]);
  });

  test("includes the keyboard backlight last when asked", () => {
    const names = W.selectOutputs(status, { showKeyboard: true }).map((o) => o.name);
    expect(names).toEqual(["eDP-1", "DP-7", "asus::kbd_backlight"]);
  });

  test("honours an explicit hidden list", () => {
    const names = W.selectOutputs(status, { hidden: ["DP-7"] }).map((o) => o.name);
    expect(names).toEqual(["eDP-1"]);
  });

  test("returns an empty list for a null status instead of throwing", () => {
    expect(W.selectOutputs(null, {})).toEqual([]);
    expect(W.selectOutputs(undefined, undefined)).toEqual([]);
  });
});

describe("isKnownOutput", () => {
  const status = W.parseStatusLine(LIVE_LINE).status;

  test("recognises a live output", () => {
    expect(W.isKnownOutput(status, "DP-7")).toBe(true);
  });

  test("rejects an output that is not in the snapshot", () => {
    // The daemon hard-errors on unknown names, so the UI must never send one.
    expect(W.isKnownOutput(status, "HDMI-A-1")).toBe(false);
    expect(W.isKnownOutput(status, "")).toBe(false);
    expect(W.isKnownOutput(null, "DP-7")).toBe(false);
  });
});

describe("command builders", () => {
  test("absolute brightness", () => {
    expect(W.setBrightnessArgs("DP-7", 55)).toEqual(["set", "brightness", "DP-7", "55%"]);
  });

  test("absolute brightness clamps and rounds", () => {
    expect(W.setBrightnessArgs("DP-7", 140)).toEqual(["set", "brightness", "DP-7", "100%"]);
    expect(W.setBrightnessArgs("DP-7", -12)).toEqual(["set", "brightness", "DP-7", "0%"]);
    expect(W.setBrightnessArgs("DP-7", 54.6)).toEqual(["set", "brightness", "DP-7", "55%"]);
  });

  test("relative steps carry an explicit sign", () => {
    expect(W.stepBrightnessArgs("eDP-1", 5)).toEqual(["set", "brightness", "eDP-1", "+5%"]);
    expect(W.stepBrightnessArgs("eDP-1", -5)).toEqual(["set", "brightness", "eDP-1", "-5%"]);
  });

  test("bad arguments produce no command at all", () => {
    expect(W.setBrightnessArgs("", 50)).toBeNull();
    expect(W.setBrightnessArgs(null, 50)).toBeNull();
    expect(W.setBrightnessArgs("DP-7", NaN)).toBeNull();
    expect(W.setBrightnessArgs("DP-7", "loud")).toBeNull();
    expect(W.stepBrightnessArgs("DP-7", 0)).toBeNull();
    expect(W.stepBrightnessArgs("", 5)).toBeNull();
  });

  test("an output name that looks like a flag is refused", () => {
    expect(W.setBrightnessArgs("--all", 50)).toBeNull();
    expect(W.stepBrightnessArgs("-x", 5)).toBeNull();
  });

  test("pause and resume, global and per output", () => {
    expect(W.pauseArgs({ all: true })).toEqual(["pause", "--all"]);
    expect(W.pauseArgs({ all: true, duration: "2h" })).toEqual(["pause", "--all", "--for", "2h"]);
    expect(W.pauseArgs({ name: "DP-7" })).toEqual(["pause", "DP-7"]);
    expect(W.resumeArgs({ all: true })).toEqual(["resume", "--all"]);
    expect(W.resumeArgs({ name: "eDP-1" })).toEqual(["resume", "eDP-1"]);
  });

  test("a bad pause duration is dropped rather than passed to the daemon", () => {
    expect(W.pauseArgs({ all: true, duration: "forever" })).toEqual(["pause", "--all"]);
    expect(W.pauseArgs({ all: true, duration: "" })).toEqual(["pause", "--all"]);
    expect(W.pauseArgs({})).toBeNull();
    expect(W.resumeArgs({})).toBeNull();
  });

  test("duration validation matches what wluma accepts", () => {
    expect(W.isValidDuration("30m")).toBe(true);
    expect(W.isValidDuration("2h")).toBe(true);
    expect(W.isValidDuration("45s")).toBe(true);
    expect(W.isValidDuration("1d")).toBe(true);
    expect(W.isValidDuration("2 h")).toBe(false);
    expect(W.isValidDuration("h")).toBe(false);
    expect(W.isValidDuration("-1h")).toBe(false);
    expect(W.isValidDuration("")).toBe(false);
    expect(W.isValidDuration(null)).toBe(false);
  });
});

describe("reconnect backoff", () => {
  test("doubles from one second and caps at thirty", () => {
    expect([0, 1, 2, 3, 4, 5, 6, 99].map(W.backoffDelay)).toEqual([
      1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000,
    ]);
  });

  test("a nonsense attempt count still yields the base delay", () => {
    expect(W.backoffDelay(-3)).toBe(1000);
    expect(W.backoffDelay(NaN)).toBe(1000);
  });
});

describe("display helpers", () => {
  const status = W.parseStatusLine(LIVE_LINE).status;

  test("summary lists the visible outputs in display order", () => {
    expect(W.summaryText(status, W.selectOutputs(status, {}))).toBe("eDP-1 5% • DP-7 1%");
  });

  test("summary reports the paused state instead of values", () => {
    const paused = W.parseStatusLine(LIVE_LINE.replaceAll('"paused":false', '"paused":true')).status;
    expect(W.summaryText(paused, W.selectOutputs(paused, {}))).toBe("Paused");
  });

  test("summary degrades gracefully with nothing to show", () => {
    expect(W.summaryText(null, [])).toBe("Unavailable");
    expect(W.summaryText(status, [])).toBe("No outputs");
  });

  test("brightness icon tracks the level", () => {
    expect(W.brightnessIcon(90)).toBe("brightness_high");
    expect(W.brightnessIcon(50)).toBe("brightness_medium");
    expect(W.brightnessIcon(5)).toBe("brightness_low");
    expect(W.brightnessIcon(null)).toBe("brightness_low");
  });

  test("output icon maps the daemon's type vocabulary", () => {
    expect(W.outputIcon("backlight")).toBe("laptop");
    expect(W.outputIcon("ddc")).toBe("monitor");
    expect(W.outputIcon("keyboard")).toBe("keyboard");
    expect(W.outputIcon("something-new")).toBe("display_settings");
  });
});
