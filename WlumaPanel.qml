import QtQuick
import qs.Common
import qs.Widgets

// The shared body for both surfaces: the Control Center detail view and the bar popout.
// Defined once so the two can never drift apart.
Column {
    id: panel

    property int debounceMs: 300
    property string defaultPauseDuration: ""

    spacing: Theme.spacingS

    // ------------------------------------------------------------- unavailable
    Column {
        width: parent.width
        spacing: Theme.spacingXS
        visible: !WlumaService.available

        Row {
            spacing: Theme.spacingS

            DankIcon {
                name: WlumaService.installed ? "cloud_off" : "error"
                size: Theme.iconSize
                color: Theme.error
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: WlumaService.unavailableReason
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.error
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        StyledText {
            width: parent.width
            visible: WlumaService.lastError.length > 0
            text: WlumaService.lastError
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        StyledText {
            width: parent.width
            visible: WlumaService.installed
            text: "Reconnecting automatically."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        Row {
            spacing: Theme.spacingS
            visible: WlumaService.installed

            DankButton {
                text: "Retry now"
                iconName: "refresh"
                onClicked: WlumaService.refresh()
            }

            DankButton {
                text: WlumaService.restarting ? "Restarting..." : "Restart daemon"
                iconName: "restart_alt"
                enabled: !WlumaService.restarting
                onClicked: WlumaService.restartDaemon()
            }
        }
    }

    // ------------------------------------------------------------- status chips
    Flow {
        width: parent.width
        spacing: Theme.spacingXS
        visible: WlumaService.available

        WlumaChip {
            visible: WlumaService.als !== null && WlumaService.als.available
            icon: "sensors"
            text: "ALS " + (WlumaService.als ? WlumaService.als.value : 0)
            active: true
        }

        WlumaChip {
            visible: WlumaService.idleInfo !== null
            icon: (WlumaService.idleInfo && WlumaService.idleInfo.onBattery) ? "battery_std" : "power"
            text: (WlumaService.idleInfo && WlumaService.idleInfo.onBattery) ? "Battery" : "AC"
            active: !(WlumaService.idleInfo && WlumaService.idleInfo.onBattery)
        }

        WlumaChip {
            visible: WlumaService.idleInfo !== null && WlumaService.idleInfo.enabled
            icon: "bedtime"
            text: {
                if (!WlumaService.idleInfo)
                    return "";
                const info = WlumaService.idleInfo;
                if (info.dimming || WlumaService.anyIdle)
                    return "Idle dim active";
                return "Idle " + info.timeout + "s to " + info.brightness + "%";
            }
            active: false
            warning: WlumaService.anyIdle || (WlumaService.idleInfo ? WlumaService.idleInfo.dimming : false)
        }

        WlumaChip {
            visible: WlumaService.allPaused
            icon: "pause"
            text: "Adaptation paused"
            active: false
            warning: true
        }
    }

    // ------------------------------------------------------------- outputs
    Column {
        width: parent.width
        spacing: Theme.spacingS
        visible: WlumaService.available

        Repeater {
            model: WlumaService.outputs

            delegate: OutputRow {
                required property var modelData

                width: parent.width
                output: modelData
                debounceMs: panel.debounceMs
                onSetRequested: (name, value) => WlumaService.setBrightness(name, value)
                onStepRequested: (name, delta) => WlumaService.stepBrightness(name, delta)
            }
        }

        StyledText {
            width: parent.width
            visible: WlumaService.outputs.length === 0
            text: "No outputs are being managed."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }

    // Setting brightness is also how you train the predictor — say so, rather than
    // letting it look like the value will be overwritten arbitrarily.
    StyledText {
        width: parent.width
        visible: WlumaService.available && WlumaService.outputs.length > 0
        text: "Adjusting brightness teaches wluma your preference for the current screen content and ambient light."
        font.pixelSize: 10
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    // ------------------------------------------------------------- actions
    Row {
        width: parent.width
        spacing: Theme.spacingS
        visible: WlumaService.available

        DankButton {
            text: WlumaService.allPaused ? "Resume" : "Pause"
            iconName: WlumaService.allPaused ? "play_arrow" : "pause"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: {
                if (WlumaService.allPaused)
                    WlumaService.resumeAll();
                else
                    WlumaService.pauseAll(panel.defaultPauseDuration);
            }
        }

        Row {
            spacing: 2
            visible: !WlumaService.allPaused
            anchors.verticalCenter: parent.verticalCenter

            StyledText {
                text: "for"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
                rightPadding: 4
            }

            Repeater {
                model: ["30m", "1h", "2h"]

                delegate: DankButton {
                    required property string modelData

                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData
                    buttonHeight: 30
                    horizontalPadding: Theme.spacingS
                    onClicked: WlumaService.pauseAll(modelData)
                }
            }
        }

        Item {
            width: 1
            height: 1
        }

        DankActionButton {
            iconName: "refresh"
            buttonSize: 30
            tooltipText: "Refresh from the daemon"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: WlumaService.refresh()
        }

        DankActionButton {
            iconName: "restart_alt"
            buttonSize: 30
            enabled: !WlumaService.restarting
            tooltipText: "Restart the wluma daemon (resets a frozen capture)"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: WlumaService.restartDaemon()
        }
    }
}
