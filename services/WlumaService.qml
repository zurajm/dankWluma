pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "wluma.js" as Wluma

// Data layer for DankWluma.
//
// wluma exposes no D-Bus API, so the CLI is the whole integration surface:
//   * `wluma status --json` primes state (one shot)
//   * `wluma watch  --json` streams the complete status object, one JSON line per change
//   * `wluma set|pause|resume` mutates
//
// Writes always go through the CLI and never touch sysfs or DDC directly, because wluma
// ingests every external brightness change as a training sample for its predictor. Going
// around it would teach it the wrong thing.
//
// All parsing and argument building lives in wluma.js, which is pure and unit-tested.
// This file is process lifecycle only.
Singleton {
    id: root

    // ------------------------------------------------------------------ settings
    // Pushed in by the widget from its pluginData; the singleton has no plugin id.
    property bool showKeyboard: false
    property var hiddenOutputs: []

    // ------------------------------------------------------------------ state
    // "installed" and "connected" are different failures needing different copy:
    // a missing binary is terminal, a dead daemon is retried.
    property bool probed: false
    property bool installed: true
    property bool connected: false
    property bool restarting: false
    property var snapshot: null
    property string lastError: ""
    property int reconnectAttempt: 0

    property int _parseFailures: 0
    property var _queue: []
    property bool _busy: false

    readonly property bool available: root.installed && root.connected && root.snapshot !== null

    readonly property var outputs: Wluma.selectOutputs(root.snapshot, {
        showKeyboard: root.showKeyboard,
        hidden: root.hiddenOutputs
    })

    // Unfiltered, for the settings page: you cannot un-hide an output that filtering
    // has already removed from `outputs`.
    readonly property var allOutputs: root.snapshot ? root.snapshot.outputs : []

    readonly property var als: root.snapshot ? root.snapshot.als : null
    readonly property var idleInfo: root.snapshot ? root.snapshot.idle : null

    readonly property string unavailableReason: {
        if (!root.probed)
            return "Connecting...";
        if (!root.installed)
            return "wluma not installed";
        return "Daemon not running";
    }

    readonly property string summary: root.available ? Wluma.summaryText(root.snapshot, root.outputs) : root.unavailableReason

    readonly property bool allPaused: {
        const list = root.outputs;
        if (!list || list.length === 0)
            return false;
        for (let i = 0; i < list.length; i++) {
            if (!list[i].paused)
                return false;
        }
        return true;
    }

    readonly property bool anyPaused: {
        const list = root.outputs;
        if (!list)
            return false;
        for (let i = 0; i < list.length; i++) {
            if (list[i].paused)
                return true;
        }
        return false;
    }

    readonly property bool anyIdle: {
        const list = root.outputs;
        if (!list)
            return false;
        for (let i = 0; i < list.length; i++) {
            if (list[i].idle)
                return true;
        }
        return false;
    }

    readonly property int primaryBrightness: {
        const list = root.outputs;
        if (!list || list.length === 0)
            return 0;
        return Math.round(list[0].brightness);
    }

    readonly property string statusIcon: root.available ? Wluma.brightnessIcon(root.primaryBrightness) : "wb_twilight"

    // ------------------------------------------------------------------ commands
    function setBrightness(name, percent) {
        if (!_dispatch(Wluma.setBrightnessArgs(name, percent), name))
            return false;
        // Apply locally at once so a drag is not visibly undone before the daemon's next
        // event arrives; the following stream line reconciles to the real value.
        _applyOptimisticBrightness(name, percent);
        return true;
    }

    function stepBrightness(name, delta) {
        return _dispatch(Wluma.stepBrightnessArgs(name, delta), name);
    }

    function pauseAll(duration) {
        return _dispatch(Wluma.pauseArgs({
            all: true,
            duration: duration
        }), null);
    }

    function resumeAll() {
        return _dispatch(Wluma.resumeArgs({
            all: true
        }), null);
    }

    function pauseOutput(name, duration) {
        return _dispatch(Wluma.pauseArgs({
            name: name,
            duration: duration
        }), name);
    }

    function resumeOutput(name) {
        return _dispatch(Wluma.resumeArgs({
            name: name
        }), name);
    }

    function refresh() {
        if (!root.installed)
            return;
        statusProc.running = true;
    }

    // The documented reset for the rare frozen-capture failure mode (luma pinned for
    // minutes under niri + portal capture).
    function restartDaemon() {
        if (root.restarting)
            return;
        root.restarting = true;
        restartProc.running = true;
    }

    function _dispatch(args, outputName) {
        if (!args) {
            root.lastError = "Refused an invalid command";
            return false;
        }
        // The daemon hard-errors on an unknown or disconnected output name, so never send
        // one: an output that vanished between render and click is simply dropped.
        if (outputName && !Wluma.isKnownOutput(root.snapshot, outputName)) {
            root.lastError = "Output not available: " + outputName;
            return false;
        }
        _enqueue(args);
        return true;
    }

    // Single-flight queue. A slider drag must never fork a process per frame, so absolute
    // brightness writes for the same output collapse to the newest pending value.
    function _enqueue(args) {
        const queue = root._queue.slice();

        if (_isAbsoluteBrightness(args)) {
            for (let i = 0; i < queue.length; i++) {
                if (_isAbsoluteBrightness(queue[i]) && queue[i][2] === args[2]) {
                    queue[i] = args;
                    root._queue = queue;
                    _pump();
                    return;
                }
            }
        }

        queue.push(args);
        root._queue = queue;
        _pump();
    }

    function _isAbsoluteBrightness(args) {
        if (!args || args.length !== 4)
            return false;
        if (args[0] !== "set" || args[1] !== "brightness")
            return false;
        const value = args[3];
        return value.charAt(0) !== "+" && value.charAt(0) !== "-";
    }

    function _pump() {
        if (root._busy || root._queue.length === 0)
            return;

        const queue = root._queue.slice();
        const next = queue.shift();
        root._queue = queue;
        root._busy = true;

        commandProc.command = ["wluma"].concat(next);
        commandProc.running = true;
    }

    function _applyOptimisticBrightness(name, percent) {
        if (!root.snapshot)
            return;

        let value = Math.round(percent);
        if (value < 0)
            value = 0;
        if (value > 100)
            value = 100;

        const current = root.snapshot.outputs;
        const next = [];
        let changed = false;
        for (let i = 0; i < current.length; i++) {
            const output = current[i];
            if (output.name === name && output.brightness !== value) {
                next.push(Object.assign({}, output, {
                    brightness: value
                }));
                changed = true;
            } else {
                next.push(output);
            }
        }

        if (changed) {
            root.snapshot = {
                als: root.snapshot.als,
                idle: root.snapshot.idle,
                outputs: next
            };
        }
    }

    // ------------------------------------------------------------------ lifecycle
    function _connect() {
        if (!root.installed)
            return;
        reconnectTimer.stop();
        // `watch` only emits on change, so without this prime the widget would stay blank
        // until the ambient light happened to move.
        statusProc.running = true;
        watchProc.running = true;
    }

    function _ingest(line) {
        const result = Wluma.parseStatusLine(line);
        if (!result.ok) {
            if (result.reason !== "empty") {
                root._parseFailures = root._parseFailures + 1;
                if (root._parseFailures <= 3)
                    console.warn("[DankWluma] discarded an unparseable line (" + result.reason + ")");
            }
            return;
        }

        root._parseFailures = 0;
        root.snapshot = result.status;
        root.connected = true;
        root.reconnectAttempt = 0;
        root.lastError = "";
    }

    function _handleDown(reason) {
        if (!root.installed)
            return;

        root.connected = false;
        // Drop the snapshot rather than leaving it on screen: after a daemon restart the
        // widget must show fresh values or nothing, never stale ones.
        root.snapshot = null;
        watchProc.running = false;

        if (reconnectTimer.running)
            return;

        reconnectTimer.interval = Wluma.backoffDelay(root.reconnectAttempt);
        root.reconnectAttempt = root.reconnectAttempt + 1;
        reconnectTimer.start();
    }

    Timer {
        id: reconnectTimer
        repeat: false
        onTriggered: root._connect()
    }

    // `wluma watch` does NOT exit when the daemon goes away: verified on this machine, the
    // client process outlives `systemctl --user stop wluma`. Process exit therefore cannot
    // detect an outage, and without this probe the widget would keep showing the last
    // values while the daemon is dead. A periodic `status` doubles as a resync guard
    // against a missed stream event; its non-zero exit routes into _handleDown below.
    Timer {
        id: livenessTimer
        interval: 10000
        repeat: true
        running: root.installed
        onTriggered: {
            if (statusProc.running || reconnectTimer.running)
                return;
            statusProc.running = true;
        }
    }

    // Distinguishes "wluma is not installed" (terminal) from "the daemon is down"
    // (retried), so the UI can say which. Mirrors how DMS probes its own optional tools.
    Process {
        id: probeProc
        command: ["sh", "-c", "command -v wluma"]
        running: true
        onExited: exitCode => {
            root.probed = true;
            root.installed = exitCode === 0;
            if (root.installed)
                root._connect();
            else
                root.lastError = "wluma is not on PATH";
        }
    }

    Process {
        id: statusProc
        command: ["wluma", "status", "--json"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: root._ingest(text)
        }

        stderr: StdioCollector {
            onStreamFinished: {
                const message = text.trim();
                if (message.length > 0)
                    root.lastError = message;
            }
        }

        onExited: exitCode => {
            if (exitCode !== 0)
                root._handleDown("status exited " + exitCode);
        }
    }

    Process {
        id: watchProc
        command: ["wluma", "watch", "--json"]
        running: false

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => root._ingest(line)
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                const message = line.trim();
                if (message.length > 0)
                    root.lastError = message;
            }
        }

        onExited: (exitCode, exitStatus) => root._handleDown("watch exited " + exitCode)
    }

    Process {
        id: commandProc
        running: false

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                const message = line.trim();
                if (message.length > 0) {
                    root.lastError = message;
                    console.warn("[DankWluma] " + message);
                }
            }
        }

        onExited: exitCode => {
            root._busy = false;
            if (exitCode !== 0)
                console.warn("[DankWluma] command failed (" + exitCode + "): " + commandProc.command.join(" "));
            root._pump();
        }
    }

    Process {
        id: restartProc
        command: ["systemctl", "--user", "restart", "wluma"]
        running: false

        onExited: exitCode => {
            root.restarting = false;
            if (exitCode !== 0) {
                root.lastError = "Daemon restart failed (" + exitCode + ")";
                return;
            }
            // The stream dies with the old process; reconnect promptly rather than waiting
            // out a backoff the user did not cause.
            root.reconnectAttempt = 0;
            reconnectTimer.interval = 1000;
            reconnectTimer.restart();
        }
    }
}
