import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root

    pluginId: "dankWluma"

    // Output visibility is read back through WlumaService, which the widget keeps in sync
    // with the persisted settings, so this page never needs its own cached copy.
    function isVisible(name) {
        const hidden = WlumaService.hiddenOutputs || [];
        return hidden.indexOf(name) === -1;
    }

    function setVisible(name, visible) {
        const hidden = (WlumaService.hiddenOutputs || []).filter(entry => entry !== name);
        if (!visible)
            hidden.push(name);
        root.saveValue("hiddenOutputs", hidden);
    }

    StyledText {
        text: "Wluma"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    Row {
        spacing: Theme.spacingS

        DankIcon {
            name: WlumaService.available ? "check_circle" : "error"
            size: Theme.iconSize
            color: WlumaService.available ? Theme.success : Theme.error
            anchors.verticalCenter: parent.verticalCenter
        }

        StyledText {
            text: WlumaService.available ? "Daemon running" : WlumaService.unavailableReason
            font.pixelSize: Theme.fontSizeSmall
            color: WlumaService.available ? Theme.success : Theme.error
            anchors.verticalCenter: parent.verticalCenter
        }

        Item {
            width: Theme.spacingM
            height: 1
        }

        DankButton {
            text: "Refresh"
            iconName: "refresh"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: WlumaService.refresh()
        }

        DankButton {
            text: WlumaService.restarting ? "Restarting..." : "Restart daemon"
            iconName: "restart_alt"
            enabled: !WlumaService.restarting
            anchors.verticalCenter: parent.verticalCenter
            onClicked: WlumaService.restartDaemon()
        }
    }

    StyledRect {
        width: parent.width
        height: 1
        color: Theme.surfaceVariant
    }

    ToggleSetting {
        settingKey: "showKeyboard"
        label: "Show keyboard backlight"
        description: "wluma also manages asus::kbd_backlight. Off by default because it is not a screen."
        defaultValue: false
    }

    SelectionSetting {
        settingKey: "defaultPauseDuration"
        label: "Default pause duration"
        description: "Used by the Control Center tile and the Pause button. The 30m / 1h / 2h buttons always override it."
        defaultValue: ""
        options: [
            {
                label: "Until resumed",
                value: ""
            },
            {
                label: "30 minutes",
                value: "30m"
            },
            {
                label: "1 hour",
                value: "1h"
            },
            {
                label: "2 hours",
                value: "2h"
            }
        ]
    }

    SliderSetting {
        settingKey: "debounceMs"
        label: "Brightness write delay"
        description: "How long to wait after a slider move before telling wluma. Lower is snappier; higher sends the daemon fewer training samples while you drag."
        defaultValue: 300
        minimum: 50
        maximum: 1000
        unit: "ms"
        leftIcon: "bolt"
        rightIcon: "hourglass_bottom"
    }

    StyledRect {
        width: parent.width
        height: 1
        color: Theme.surfaceVariant
    }

    Column {
        width: parent.width
        spacing: Theme.spacingXS

        StyledText {
            text: "Visible outputs"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            text: "Outputs currently reported by the daemon. Hiding one only removes it from this widget; wluma keeps managing it."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        StyledText {
            width: parent.width
            visible: WlumaService.allOutputs.length === 0
            text: "No outputs reported yet."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        Repeater {
            model: WlumaService.allOutputs

            delegate: DankToggle {
                required property var modelData

                width: parent.width
                text: modelData.name
                description: modelData.kind + (modelData.capturer ? " via " + modelData.capturer : "")
                checked: root.isVisible(modelData.name)
                onToggled: isChecked => root.setVisible(modelData.name, isChecked)
            }
        }
    }
}
