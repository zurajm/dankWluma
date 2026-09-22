import QtQuick
import qs.Common
import qs.Widgets

// One wluma output: name, live badges, screen-content luma, and the brightness control.
//
// The slider follows the daemon. wluma keeps predicting while you use it, so the value
// tracks whatever the daemon last reported except while you are actively dragging or a
// debounced write is still pending.
Column {
    id: row

    required property var output
    property int debounceMs: 300

    signal setRequested(string name, int value)
    signal stepRequested(string name, int delta)

    readonly property bool editing: slider.isDragging || debounceTimer.running

    spacing: 2

    function syncFromDaemon() {
        if (row.editing)
            return;
        slider.value = Math.round(row.output.brightness);
    }

    onOutputChanged: syncFromDaemon()
    Component.onCompleted: slider.value = Math.round(row.output.brightness)

    Item {
        width: parent.width
        height: 24

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            DankIcon {
                name: row.output.icon
                size: 16
                color: row.output.paused ? Theme.surfaceVariantText : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: row.output.name
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: row.output.paused ? Theme.surfaceVariantText : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            WlumaChip {
                visible: row.output.paused
                icon: "pause"
                text: "Paused"
                active: false
                warning: true
                anchors.verticalCenter: parent.verticalCenter
            }

            WlumaChip {
                visible: row.output.idle
                icon: "nightlight"
                text: "Dimmed"
                active: false
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: row.output.hasLuma
                text: "luma " + row.output.luma + "%"
                font.pixelSize: 10
                color: Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    Item {
        width: parent.width
        height: 32

        DankActionButton {
            id: downButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            iconName: "remove"
            iconSize: 16
            buttonSize: 26
            tooltipText: "Dim 5% and teach wluma"
            onClicked: row.stepRequested(row.output.name, -5)
        }

        DankSlider {
            id: slider
            anchors.left: downButton.right
            anchors.right: upButton.left
            anchors.leftMargin: Theme.spacingXS
            anchors.rightMargin: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter
            minimum: 0
            maximum: 100
            unit: "%"
            wheelEnabled: false

            onSliderValueChanged: newValue => {
                debounceTimer.restart();
            }

            // Releasing commits immediately: waiting out the debounce after the drag has
            // visibly ended feels broken.
            onSliderDragFinished: finalValue => {
                debounceTimer.stop();
                row.setRequested(row.output.name, finalValue);
            }
        }

        DankActionButton {
            id: upButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconName: "add"
            iconSize: 16
            buttonSize: 26
            tooltipText: "Brighten 5% and teach wluma"
            onClicked: row.stepRequested(row.output.name, 5)
        }
    }

    // Coalesces a drag or a wheel of keyboard repeats into one daemon write.
    Timer {
        id: debounceTimer
        interval: row.debounceMs
        repeat: false
        onTriggered: row.setRequested(row.output.name, slider.value)
    }
}
