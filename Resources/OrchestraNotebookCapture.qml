import QtQuick 2.0
import MuseScore 3.0
import FileIO 3.0

MuseScore {
    menuPath: "Plugins.配器手记：从选区新建笔记"
    description: "把当前 MuseScore 选区发送到配器手记，并建立可回跳的谱例笔记。"
    version: "0.2"
    requiresScore: true

    FileIO {
        id: selectionFile
        source: homePath() + "/Documents/MuseScore4/OrchestraNotebook/selection.json"
        onError: function(msg) { console.log("Orchestra Notebook bridge:", msg) }
    }

    function measureNumberForTick(targetTick) {
        var measure = curScore.firstMeasure
        var number = 1
        var result = 1
        while (measure) {
            if (measure.firstSegment && measure.firstSegment.tick <= targetTick)
                result = number
            else if (measure.firstSegment && measure.firstSegment.tick > targetTick)
                break
            measure = measure.nextMeasure
            number += 1
        }
        return result
    }

    onRun: {
        if (!curScore) {
            Qt.quit()
            return
        }

        var selection = curScore.selection
        var startTick = 0
        var endTick = curScore.lastSegment ? curScore.lastSegment.tick + 1 : 1
        var startStaff = 0
        var endStaff = curScore.nstaves

        if (selection && selection.isRange && selection.startSegment) {
            startTick = selection.startSegment.tick
            endTick = selection.endSegment ? selection.endSegment.tick : endTick
            startStaff = selection.startStaff
            endStaff = selection.endStaff
        } else if (selection && selection.elements && selection.elements.length > 0) {
            var element = selection.elements[0]
            if (element.segment) startTick = element.segment.tick
            else if (element.parent && element.parent.segment) startTick = element.parent.segment.tick
            endTick = startTick + division * 4
            if (element.staffIdx !== undefined && element.staffIdx >= 0) {
                startStaff = element.staffIdx
                endStaff = startStaff + 1
            }
        }

        var startMeasure = measureNumberForTick(startTick)
        var endMeasure = measureNumberForTick(Math.max(startTick, endTick - 1))
        var payload = {
            version: 1,
            scorePath: curScore.filePath,
            scoreTitle: curScore.scoreName,
            startTick: startTick,
            endTick: endTick,
            startMeasure: startMeasure,
            endMeasure: endMeasure,
            startStaff: startStaff,
            endStaff: endStaff,
            staffCount: curScore.nstaves,
            timestamp: Date.now()
        }
        selectionFile.write(JSON.stringify(payload))
        Qt.quit()
    }
}
