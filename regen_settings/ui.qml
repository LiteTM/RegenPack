import "qrc:/mobile"

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.3

import Vedder.vesc.commands 1.0
import Vedder.vesc.utility 1.0

// Regen Settings - AppUI page.
// Layout and widgets follow the VESC Tool configuration pages
// (ParamEditSeparator / ParamEditDouble / ParamEditBool look).
Item {
    id: root
    anchors.fill: parent

    property Commands mCommands: VescIf.commands()

    property bool confLoaded: false
    property bool dirty: false
    property bool loading: false
    property real hwMax: 150.0
    property bool savePending: false

    // Live data
    property int rtStatus: -1
    property real rtSpeed: 0.0
    property real rtThrottle: 0.0
    property real rtBrake: 0.0
    property real rtMotor: 0.0

    readonly property var statusNames: [
        "Disabled", "Waiting", "Arming", "Regen Active",
        "No ADC App", "Throttle Out of Range", "Motor Fault"
    ]

    // Card background: lightBackground at 40 % opacity, as in VESC Tool
    readonly property color cLightBg: Utility.getAppHexColor("lightBackground")
    readonly property color cardColor: Qt.rgba(cLightBg.r, cLightBg.g, cLightBg.b, 0.4)

    function statusColor(s) {
        if (s === 3) return Utility.getAppHexColor("lightAccent")
        if (s === 2) return Utility.getAppHexColor("orange")
        if (s >= 4) return Utility.getAppHexColor("red")
        return Utility.getAppHexColor("lightText")
    }

    // ---------------------------------------------------------------------
    //  VESC Tool style section header (ParamEditSeparator)
    // ---------------------------------------------------------------------
    component Separator: Item {
        property string sepName: ""
        Layout.fillWidth: true
        Layout.preferredHeight: 25
        height: 25

        Rectangle {
            anchors.fill: parent
            color: Utility.getAppHexColor("darkAccent")
            radius: 5

            Text {
                anchors.centerIn: parent
                color: Utility.getAppHexColor("lightText")
                text: sepName
                font.bold: true
                font.pointSize: 12
            }
        }
    }

    // ---------------------------------------------------------------------
    //  VESC Tool style double parameter card (ParamEditDouble)
    // ---------------------------------------------------------------------
    component ParamDouble: Item {
        id: pd
        property string name: ""
        property string help: ""
        property alias value: box.realValue
        property alias from: box.realFrom
        property alias to: box.realTo
        property alias stepSize: box.realStepSize
        property alias decimals: box.decimals
        property alias suffix: box.suffix
        property real defaultValue: 0.0

        Layout.fillWidth: true
        Layout.preferredHeight: 140
        height: 140

        Rectangle {
            anchors.fill: parent
            color: root.cardColor
            radius: 10
            border.color: Utility.getAppHexColor("disabledText")
            border.width: 3

            ColumnLayout {
                anchors.fill: parent
                anchors.topMargin: 10
                anchors.margins: 5

                Text {
                    color: Utility.getAppHexColor("lightText")
                    text: pd.name
                    horizontalAlignment: Text.AlignHCenter
                    Layout.fillWidth: true
                    font.pointSize: 12
                }

                DoubleSpinBox {
                    id: box
                    Layout.fillWidth: true
                    Layout.leftMargin: 5
                    Layout.rightMargin: 5
                    onRealValueChanged: if (!root.loading) root.dirty = true
                }

                RowLayout {
                    Layout.fillWidth: true

                    Button {
                        focusPolicy: Qt.NoFocus
                        Layout.fillWidth: true
                        Layout.preferredWidth: 500
                        flat: true
                        text: "Default"
                        onClicked: box.realValue = pd.defaultValue
                    }

                    Button {
                        focusPolicy: Qt.NoFocus
                        Layout.fillWidth: true
                        Layout.preferredWidth: 500
                        flat: true
                        text: "Help"
                        onClicked: VescIf.emitMessageDialog(pd.name, pd.help, true, true)
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------------
    //  VESC Tool style bool parameter card (ParamEditBool)
    // ---------------------------------------------------------------------
    component ParamBool: Item {
        id: pb
        property string name: ""
        property string help: ""
        property alias checked: sw.checked
        property bool defaultValue: true

        Layout.fillWidth: true
        Layout.preferredHeight: 140
        height: 140

        Rectangle {
            anchors.fill: parent
            color: root.cardColor
            radius: 10
            border.color: Utility.getAppHexColor("disabledText")
            border.width: 3

            ColumnLayout {
                anchors.fill: parent
                anchors.topMargin: 10
                anchors.margins: 5

                Text {
                    color: Utility.getAppHexColor("lightText")
                    text: pb.name
                    horizontalAlignment: Text.AlignHCenter
                    Layout.fillWidth: true
                    font.pointSize: 12
                }

                Switch {
                    id: sw
                    focusPolicy: Qt.NoFocus
                    Layout.fillWidth: true
                    onCheckedChanged: if (!root.loading) root.dirty = true
                }

                RowLayout {
                    Layout.fillWidth: true

                    Button {
                        focusPolicy: Qt.NoFocus
                        Layout.fillWidth: true
                        Layout.preferredWidth: 500
                        flat: true
                        text: "Default"
                        onClicked: sw.checked = pb.defaultValue
                    }

                    Button {
                        focusPolicy: Qt.NoFocus
                        Layout.fillWidth: true
                        Layout.preferredWidth: 500
                        flat: true
                        text: "Help"
                        onClicked: VescIf.emitMessageDialog(pb.name, pb.help, true, true)
                    }
                }
            }
        }
    }

    // Live value cell for the status card
    component LiveValue: ColumnLayout {
        property string label: ""
        property string value: ""
        Layout.fillWidth: true
        Layout.preferredWidth: 500
        spacing: 0

        Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            color: Utility.getAppHexColor("disabledText")
            font.pointSize: 9
            text: label
        }
        Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            color: Utility.getAppHexColor("lightText")
            font.pointSize: 13
            font.bold: true
            text: value
        }
    }

    // ---------------------------------------------------------------------
    //  Communication
    // ---------------------------------------------------------------------
    function sendCmd(c) {
        var buffer = new ArrayBuffer(1)
        var dv = new DataView(buffer)
        dv.setUint8(0, c)
        mCommands.sendCustomAppData(buffer)
    }

    function writeConfig() {
        var buffer = new ArrayBuffer(26)
        var dv = new DataView(buffer)
        dv.setUint8(0, 2)
        dv.setUint8(1, pEnabled.checked ? 1 : 0)
        dv.setFloat32(2,  pCurrent.value)
        dv.setFloat32(6,  pMinSpeed.value)
        dv.setFloat32(10, pRelTh.value)
        dv.setFloat32(14, pRelDelay.value)
        dv.setFloat32(18, pHyst.value)
        dv.setFloat32(22, pRamp.value)
        mCommands.sendCustomAppData(buffer)
    }

    function applyConf(t) {
        loading = true
        pEnabled.checked  = Number(t[1]) === 1
        hwMax             = Math.max(1.0, Math.min(150.0, Number(t[8])))
        pCurrent.value    = Number(t[2])
        pMinSpeed.value   = Number(t[3])
        pRelTh.value      = Number(t[4])
        pRelDelay.value   = Number(t[5])
        pHyst.value       = Number(t[6])
        pRamp.value       = Number(t[7])
        savePending       = Number(t[9]) === 1
        loading = false
        dirty = false
        confLoaded = true
    }

    Connections {
        target: mCommands

        function onCustomAppDataReceived(data) {
            var str = data.toString()
            var t = str.split(" ")

            if (t[0] === "conf" && t.length >= 10) {
                applyConf(t)
            } else if (t[0] === "rt" && t.length >= 6) {
                rtStatus   = Number(t[1])
                rtSpeed    = Number(t[2])
                rtThrottle = Number(t[3])
                rtBrake    = Number(t[4])
                rtMotor    = Number(t[5])
            } else if (t[0] === "msg") {
                if (str.indexOf("saved") >= 0) savePending = false
                VescIf.emitStatusMessage(str.substring(4), true)
            }
        }
    }

    Component.onCompleted: sendCmd(1)

    // Ask for the configuration until the script answers
    Timer {
        interval: 1000
        running: !confLoaded
        repeat: true
        onTriggered: sendCmd(1)
    }

    // Poll live data (only while this page exists, no idle traffic)
    Timer {
        interval: 200
        running: confLoaded
        repeat: true
        onTriggered: sendCmd(4)
    }

    // ---------------------------------------------------------------------
    //  Page
    // ---------------------------------------------------------------------
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 5

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true

            ColumnLayout {
                width: parent.width
                spacing: 5

                // ---------------- Live status ----------------
                Separator { sepName: "Regen Status" }

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 110
                    height: 110

                    Rectangle {
                        anchors.fill: parent
                        color: root.cardColor
                        radius: 10
                        border.color: rtStatus === 3 ? Utility.getAppHexColor("lightAccent")
                                                     : Utility.getAppHexColor("disabledText")
                        border.width: 3

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 10

                            Text {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                font.pointSize: 14
                                font.bold: true
                                color: confLoaded ? statusColor(rtStatus) : Utility.getAppHexColor("disabledText")
                                text: !confLoaded ? "Connecting to script..."
                                                  : (rtStatus >= 0 && rtStatus < statusNames.length
                                                     ? statusNames[rtStatus] : "...")
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                LiveValue { label: "Speed";    value: rtSpeed.toFixed(1) + " km/h" }
                                LiveValue { label: "Throttle"; value: rtThrottle.toFixed(0) + " %" }
                                LiveValue { label: "Regen";    value: rtBrake.toFixed(1) + " A" }
                                LiveValue { label: "Motor";    value: rtMotor.toFixed(1) + " A" }
                            }
                        }
                    }
                }

                // ---------------- Main settings ----------------
                Separator { sepName: "Regen Settings" }

                ParamBool {
                    id: pEnabled
                    name: "Enable Throttle-Release Regen"
                    defaultValue: true
                    help: "<b>Enable Throttle-Release Regen</b><br><br>" +
                          "Master switch. When disabled the script never touches the motor " +
                          "and the ADC app has full control."
                }

                ParamDouble {
                    id: pCurrent
                    name: "Regen Current"
                    suffix: " A"
                    decimals: 1
                    from: 0.0
                    to: hwMax
                    stepSize: 0.5
                    defaultValue: 10.0
                    value: 10.0
                    help: "<b>Regen Current</b><br><br>" +
                          "Motor brake current applied while the throttle is released.<br><br>" +
                          "Limited to the <i>Motor Current Min</i> of the motor configuration " +
                          "(currently " + hwMax.toFixed(1) + " A). Battery regen current is " +
                          "still limited by <i>Battery Current Min</i>.<br><br>" +
                          "Start low (5 - 10 A) and increase gradually."
                }

                ParamDouble {
                    id: pMinSpeed
                    name: "Minimum Regen Speed"
                    suffix: " km/h"
                    decimals: 1
                    from: 1.0
                    to: 60.0
                    stepSize: 0.5
                    defaultValue: 8.0
                    value: 8.0
                    help: "<b>Minimum Regen Speed</b><br><br>" +
                          "Regen stops as soon as the speed falls below this value.<br><br>" +
                          "To start, the speed must be above <i>Minimum Regen Speed + Speed " +
                          "Hysteresis</i>.<br><br>Requires correct wheel diameter, motor poles " +
                          "and gear ratio in the motor configuration."
                }

                // ---------------- Anti-jitter ----------------
                Separator { sepName: "Throttle Release & Anti-Jitter" }

                ParamDouble {
                    id: pRelTh
                    name: "Throttle Release Threshold"
                    suffix: " %"
                    decimals: 1
                    from: 1.0
                    to: 20.0
                    stepSize: 0.5
                    defaultValue: 5.0
                    value: 5.0
                    help: "<b>Throttle Release Threshold</b><br><br>" +
                          "The throttle counts as fully released below this level.<br><br>" +
                          "Regen stops immediately when the throttle goes 3 % above this " +
                          "threshold. The 3 % band prevents sensor noise from toggling regen."
                }

                ParamDouble {
                    id: pRelDelay
                    name: "Release Delay"
                    suffix: " ms"
                    decimals: 0
                    from: 50
                    to: 2000
                    stepSize: 10
                    defaultValue: 300
                    value: 300
                    help: "<b>Release Delay</b><br><br>" +
                          "How long the throttle must stay continuously released before regen " +
                          "can start. Any throttle input restarts the timer.<br><br>" +
                          "Prevents braking during quick throttle lifts or gear-shift style " +
                          "on/off throttle use."
                }

                ParamDouble {
                    id: pHyst
                    name: "Speed Hysteresis"
                    suffix: " km/h"
                    decimals: 1
                    from: 0.5
                    to: 10.0
                    stepSize: 0.5
                    defaultValue: 1.5
                    value: 1.5
                    help: "<b>Speed Hysteresis</b><br><br>" +
                          "Regen starts above <i>Minimum Regen Speed + Hysteresis</i> and stops " +
                          "below <i>Minimum Regen Speed</i>. Prevents rapid on/off switching " +
                          "around the speed limit."
                }

                ParamDouble {
                    id: pRamp
                    name: "Regen Ramp-In Time"
                    suffix: " ms"
                    decimals: 0
                    from: 0
                    to: 2000
                    stepSize: 50
                    defaultValue: 400
                    value: 400
                    help: "<b>Regen Ramp-In Time</b><br><br>" +
                          "Time to ramp the brake current from 0 to the full Regen Current. " +
                          "Gives smooth, jerk-free engagement.<br><br>" +
                          "Release is always instant."
                }
            }
        }

        // ---------------- Bottom bar ----------------
        Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            visible: dirty || savePending
            color: Utility.getAppHexColor("orange")
            font.pointSize: 10
            text: dirty ? "Changes not written yet"
                        : "Written - will be saved to flash when the vehicle stops"
        }

        RowLayout {
            Layout.fillWidth: true

            Button {
                Layout.fillWidth: true
                Layout.preferredWidth: 500
                text: "Read"
                onClicked: sendCmd(1)
            }

            Button {
                Layout.fillWidth: true
                Layout.preferredWidth: 500
                text: "Defaults"
                onClicked: sendCmd(3)
            }

            Button {
                Layout.fillWidth: true
                Layout.preferredWidth: 500
                text: "Write"
                highlighted: dirty
                enabled: confLoaded
                onClicked: writeConfig()
            }
        }
    }
}
