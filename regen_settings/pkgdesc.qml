import QtQuick 2.15

Item {
    property string pkgName: "Regen Settings"
    property string pkgDescriptionMd: "README.md"
    property string pkgLisp: "regen.lisp"
    property string pkgQml: "ui.qml"
    property bool pkgQmlIsFullscreen: false
    property string pkgOutput: "regen_settings.vescpkg"

    // Motor controllers only (not VESC BMS / VESC Express).
    function isCompatible (fwRxParams) {
        var hwType = fwRxParams.hwTypeStr().toLowerCase();
        return hwType == "vesc";
    }
}
