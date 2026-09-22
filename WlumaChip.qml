import QtQuick
import qs.Common
import qs.Widgets

// A compact status pill. DMS ships no StatusChip widget, so plugins bring their own
// (DankClight does the same); this keeps the shape consistent with the rest of the shell.
StyledRect {
    id: chip

    property string icon: ""
    property string text: ""
    property bool active: true
    property bool warning: false

    width: chipRow.implicitWidth + Theme.spacingS * 2
    height: 24
    radius: 12
    color: {
        if (warning)
            return Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.2);
        if (active)
            return Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.2);
        return Theme.surfaceContainerHigh;
    }

    readonly property color contentColor: {
        if (warning)
            return Theme.warning;
        if (active)
            return Theme.primary;
        return Theme.surfaceVariantText;
    }

    Row {
        id: chipRow
        anchors.centerIn: parent
        spacing: 4

        DankIcon {
            name: chip.icon
            size: 14
            color: chip.contentColor
            anchors.verticalCenter: parent.verticalCenter
        }

        StyledText {
            text: chip.text
            font.pixelSize: 10
            font.weight: Font.Medium
            color: chip.contentColor
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
