import QtQuick
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.corck.filesearch"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf002"
    tooltipText: "File search (F3 / SUPER + CTRL + F)"
    onPressed: function (button) {
      if (!root.bar)
        return
      root.bar.run("omarchy-shell shell toggle io.github.corck.filesearch '{}'")
    }
  }
}
