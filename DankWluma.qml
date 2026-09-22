import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// DankWluma — surfaces and controls the wluma adaptive-brightness daemon.
//
// Three surfaces share one data layer (WlumaService, registered as a plugin-local
// singleton in qmldir) and one body component (WlumaPanel):
//   * Control Center tile + detail view
//   * DankBar pill + popout
//   * Settings page (DankWlumaSettings.qml)
PluginComponent {
    id: root

    readonly property var settings: root.pluginData || ({})
    readonly property int debounceMs: {
        const value = Number(root.settings.debounceMs);
        return (isFinite(value) && value >= 50 && value <= 2000) ? Math.round(value) : 300;
    }
    readonly property string defaultPauseDuration: typeof root.settings.defaultPauseDuration === "string" ? root.settings.defaultPauseDuration : ""

    // The singleton has no plugin id of its own, so the widget feeds it the settings.
    Binding {
        target: WlumaService
        property: "showKeyboard"
        value: root.settings.showKeyboard === true
    }

    Binding {
        target: WlumaService
        property: "hiddenOutputs"
        value: Array.isArray(root.settings.hiddenOutputs) ? root.settings.hiddenOutputs : []
    }

    // ------------------------------------------------------------- control center
    ccWidgetIcon: WlumaService.statusIcon
    ccWidgetPrimaryText: "Wluma"
    ccWidgetSecondaryText: WlumaService.summary
    ccWidgetIsActive: WlumaService.available && !WlumaService.allPaused
    ccWidgetIsToggle: true

    // CompoundPill splits the tile: clicking the icon square toggles adaptation, clicking
    // the body expands the detail view.
    onCcWidgetToggled: {
        if (!WlumaService.available)
            return;
        if (WlumaService.allPaused)
            WlumaService.resumeAll();
        else
            WlumaService.pauseAll(root.defaultPauseDuration);
    }

    ccDetailHeight: {
        const rows = WlumaService.available ? WlumaService.outputs.length : 0;
        return 150 + rows * 66;
    }

    ccDetailContent: Component {
        WlumaPanel {
            width: parent ? parent.width : 0
            debounceMs: root.debounceMs
            defaultPauseDuration: root.defaultPauseDuration
        }
    }

    // ------------------------------------------------------------- bar pill
    horizontalBarPill: Component {
        Row {
            spacing: (root.barConfig?.noBackground ?? false) ? 1 : 2

            DankIcon {
                name: WlumaService.statusIcon
                size: Theme.barIconSize(root.barThickness, -4)
                color: {
                    if (!WlumaService.available)
                        return Theme.surfaceVariantText;
                    if (WlumaService.allPaused)
                        return Theme.surfaceVariantText;
                    return Theme.widgetIconColor;
                }
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: WlumaService.available ? (WlumaService.primaryBrightness + "%") : "N/A"
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale)
                color: (WlumaService.available && !WlumaService.allPaused) ? Theme.widgetTextColor : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 1

            DankIcon {
                name: WlumaService.statusIcon
                size: Theme.barIconSize(root.barThickness)
                color: {
                    if (!WlumaService.available)
                        return Theme.surfaceVariantText;
                    if (WlumaService.allPaused)
                        return Theme.surfaceVariantText;
                    return Theme.widgetIconColor;
                }
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: WlumaService.available ? String(WlumaService.primaryBrightness) : "--"
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale)
                color: (WlumaService.available && !WlumaService.allPaused) ? Theme.widgetTextColor : Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // ------------------------------------------------------------- popout
    popoutWidth: 420
    popoutHeight: {
        const rows = WlumaService.available ? WlumaService.outputs.length : 0;
        return 200 + rows * 66;
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: "Wluma"
            // The chips below already carry ALS / power / idle, so the subtitle shows the
            // brightness summary instead of repeating them.
            detailsText: WlumaService.summary
            showCloseButton: true

            WlumaPanel {
                width: parent.width
                debounceMs: root.debounceMs
                defaultPauseDuration: root.defaultPauseDuration
            }
        }
    }
}
