.pragma library

// Pure logic layer for DankWluma: NDJSON parsing, schema normalisation, command
// construction and display formatting for the wluma 5.x CLI.
//
// This file is deliberately Qt-free. Everything that can be wrong lives here, so
// everything that can be wrong is unit-testable (see ../tests/wluma.test.mjs).
// WlumaService.qml holds only process wiring; the views hold only bindings.
//
// Schema contract (`wluma status --json`, identical to each `wluma watch --json` line):
//   {"als":{"type":"webcam","value":31},
//    "idle":{"power_source":"ac","state":"active","enabled":true,"timeout":120,"brightness":30},
//    "outputs":[{"name":"DP-7","type":"ddc","capturer":"...","luma":26,"brightness":1,
//                "dim":null,"temperature":null,"state":"active","paused":false,"idle":false}]}
// `brightness` and `luma` are integer percentages. `dim`/`temperature` are always null on
// niri (gamma control is rejected), so they are intentionally dropped here.

const OUTPUT_ICONS = {
    backlight: "laptop",
    ddc: "monitor",
    keyboard: "keyboard"
};
const FALLBACK_OUTPUT_ICON = "display_settings";

// Display order: internal panel, then external displays, then anything unrecognised,
// then the keyboard backlight last because it is an oddity rather than a screen.
const KIND_RANK = {
    backlight: 0,
    ddc: 1,
    keyboard: 3
};
const UNKNOWN_KIND_RANK = 2;

const DURATION_RE = /^[0-9]+[smhd]$/;

const BACKOFF_BASE_MS = 1000;
const BACKOFF_MAX_MS = 30000;

function _isFiniteNumber(value) {
    return typeof value === "number" && isFinite(value);
}

function _num(value, fallback) {
    return _isFiniteNumber(value) ? value : fallback;
}

function _nullableNum(value) {
    return _isFiniteNumber(value) ? value : null;
}

function _str(value, fallback) {
    return (typeof value === "string" && value.length > 0) ? value : fallback;
}

function _isPlainObject(value) {
    return !!value && typeof value === "object" && !Array.isArray(value);
}

// The daemon rejects unknown or disconnected output names outright, and a name starting
// with "-" would be read as a flag. Refuse both before a process is ever spawned.
function _isSafeOutputName(name) {
    return typeof name === "string" && name.length > 0 && name.charAt(0) !== "-";
}

function _kindRank(kind) {
    return Object.prototype.hasOwnProperty.call(KIND_RANK, kind) ? KIND_RANK[kind] : UNKNOWN_KIND_RANK;
}

function outputIcon(kind) {
    if (typeof kind !== "string")
        return FALLBACK_OUTPUT_ICON;
    return Object.prototype.hasOwnProperty.call(OUTPUT_ICONS, kind) ? OUTPUT_ICONS[kind] : FALLBACK_OUTPUT_ICON;
}

function brightnessIcon(percent) {
    if (!_isFiniteNumber(percent))
        return "brightness_low";
    if (percent >= 67)
        return "brightness_high";
    if (percent >= 34)
        return "brightness_medium";
    return "brightness_low";
}

function _normalizeOutput(raw) {
    if (!_isPlainObject(raw))
        return null;

    const name = _str(raw.name, "");
    if (!name)
        return null;

    const kind = _str(raw.type, "unknown");
    const luma = _nullableNum(raw.luma);

    return {
        name: name,
        kind: kind,
        capturer: typeof raw.capturer === "string" ? raw.capturer : null,
        luma: luma,
        hasLuma: luma !== null,
        brightness: _num(raw.brightness, 0),
        state: _str(raw.state, "unknown"),
        paused: raw.paused === true,
        idle: raw.idle === true,
        isKeyboard: kind === "keyboard",
        icon: outputIcon(kind)
    };
}

// Turns a decoded status payload into the canonical model, or null if the payload is not
// a status object at all. Missing sub-objects degrade to explicit "not available"
// defaults rather than undefined, so bindings never read a half-built model.
function normalizeStatus(raw) {
    if (!_isPlainObject(raw))
        return null;

    const alsRaw = _isPlainObject(raw.als) ? raw.als : null;
    const alsValue = alsRaw ? _nullableNum(alsRaw.value) : null;
    const als = {
        type: alsRaw ? _str(alsRaw.type, "unknown") : "none",
        value: alsValue,
        available: alsRaw !== null && alsValue !== null
    };

    const idleRaw = _isPlainObject(raw.idle) ? raw.idle : null;
    const idleState = idleRaw ? _str(idleRaw.state, "unknown") : "unknown";
    const powerSource = idleRaw ? _str(idleRaw.power_source, "unknown") : "unknown";
    const idle = {
        powerSource: powerSource,
        onBattery: powerSource === "battery",
        state: idleState,
        enabled: idleRaw ? idleRaw.enabled === true : false,
        timeout: idleRaw ? _num(idleRaw.timeout, 0) : 0,
        brightness: idleRaw ? _num(idleRaw.brightness, 0) : 0,
        dimming: idleRaw !== null && idleState !== "active" && idleState !== "unknown"
    };

    const outputs = [];
    if (Array.isArray(raw.outputs)) {
        for (let i = 0; i < raw.outputs.length; i++) {
            const output = _normalizeOutput(raw.outputs[i]);
            if (output)
                outputs.push(output);
        }
    }

    return {
        als: als,
        idle: idle,
        outputs: outputs
    };
}

// Parses exactly one NDJSON line. Total function: every input yields a result object and
// nothing throws, because this runs on the GUI thread for every daemon event.
function parseStatusLine(line) {
    if (typeof line !== "string")
        return { ok: false, reason: "empty" };

    const trimmed = line.trim();
    if (trimmed.length === 0)
        return { ok: false, reason: "empty" };

    let decoded;
    try {
        decoded = JSON.parse(trimmed);
    } catch (error) {
        return { ok: false, reason: "parse" };
    }

    const status = normalizeStatus(decoded);
    if (!status)
        return { ok: false, reason: "shape" };

    return { ok: true, status: status };
}

// options: { showKeyboard: bool, hidden: [name] }
function selectOutputs(status, options) {
    if (!status || !Array.isArray(status.outputs))
        return [];

    const opts = options || {};
    const showKeyboard = opts.showKeyboard === true;
    const hidden = Array.isArray(opts.hidden) ? opts.hidden : [];

    const visible = [];
    for (let i = 0; i < status.outputs.length; i++) {
        const output = status.outputs[i];
        if (output.isKeyboard && !showKeyboard)
            continue;
        if (hidden.indexOf(output.name) !== -1)
            continue;
        visible.push(output);
    }

    visible.sort(function (a, b) {
        const rankA = _kindRank(a.kind);
        const rankB = _kindRank(b.kind);
        if (rankA !== rankB)
            return rankA - rankB;
        if (a.name < b.name)
            return -1;
        if (a.name > b.name)
            return 1;
        return 0;
    });

    return visible;
}

function isKnownOutput(status, name) {
    if (!status || !Array.isArray(status.outputs))
        return false;
    if (typeof name !== "string" || name.length === 0)
        return false;
    for (let i = 0; i < status.outputs.length; i++) {
        if (status.outputs[i].name === name)
            return true;
    }
    return false;
}

function isValidDuration(text) {
    return typeof text === "string" && DURATION_RE.test(text);
}

// `wluma set brightness OUT <abs%>`. Writing through the CLI (never sysfs or DDC) is what
// lets the predictor ingest the change as a training sample.
function setBrightnessArgs(name, percent) {
    if (!_isSafeOutputName(name))
        return null;
    if (!_isFiniteNumber(percent))
        return null;

    let value = Math.round(percent);
    if (value < 0)
        value = 0;
    if (value > 100)
        value = 100;

    return ["set", "brightness", name, value + "%"];
}

// `wluma set brightness OUT <+N%|-N%>`
function stepBrightnessArgs(name, delta) {
    if (!_isSafeOutputName(name))
        return null;
    if (!_isFiniteNumber(delta))
        return null;

    const step = Math.round(delta);
    if (step === 0)
        return null;

    return ["set", "brightness", name, (step > 0 ? "+" : "-") + Math.abs(step) + "%"];
}

function _targetArgs(verb, target) {
    const spec = target || {};
    if (spec.all === true)
        return [verb, "--all"];
    if (_isSafeOutputName(spec.name))
        return [verb, spec.name];
    return null;
}

// `wluma pause [OUTPUT | --all] [--for DURATION]`. An unparseable duration is dropped
// rather than forwarded, so a bad setting degrades to an indefinite pause.
function pauseArgs(target) {
    const base = _targetArgs("pause", target);
    if (!base)
        return null;

    const spec = target || {};
    if (isValidDuration(spec.duration))
        return base.concat(["--for", spec.duration]);

    return base;
}

// `wluma resume [OUTPUT | --all]`
function resumeArgs(target) {
    return _targetArgs("resume", target);
}

function backoffDelay(attempt) {
    if (!_isFiniteNumber(attempt) || attempt < 0)
        return BACKOFF_BASE_MS;

    const delay = BACKOFF_BASE_MS * Math.pow(2, Math.floor(attempt));
    return delay > BACKOFF_MAX_MS ? BACKOFF_MAX_MS : delay;
}

function summaryText(status, outputs) {
    if (!status)
        return "Unavailable";

    const list = Array.isArray(outputs) ? outputs : [];
    if (list.length === 0)
        return "No outputs";

    let allPaused = true;
    for (let i = 0; i < list.length; i++) {
        if (!list[i].paused) {
            allPaused = false;
            break;
        }
    }
    if (allPaused)
        return "Paused";

    const parts = [];
    for (let i = 0; i < list.length; i++)
        parts.push(list[i].name + " " + Math.round(list[i].brightness) + "%");

    return parts.join(" • ");
}
