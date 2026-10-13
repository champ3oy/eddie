// Posts real mouse events (for debugging the UI): `swift tools/mouse.swift drag x1 y1 x2 y2` / `click x y` / `move x y` / `dblclick x y`.
import CoreGraphics
import Foundation

let a = CommandLine.arguments
func post(_ type: CGEventType, _ p: CGPoint, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
    e.setIntegerValueField(.mouseEventClickState, value: clicks)
    e.post(tap: .cghidEventTap)
}
func pt(_ i: Int) -> CGPoint { CGPoint(x: Double(a[i])!, y: Double(a[i + 1])!) }
switch a[1] {
case "move":
    post(.mouseMoved, pt(2))
case "click":
    post(.mouseMoved, pt(2)); usleep(150_000)
    post(.leftMouseDown, pt(2)); usleep(60_000); post(.leftMouseUp, pt(2))
case "dblclick":
    post(.mouseMoved, pt(2)); usleep(150_000)
    post(.leftMouseDown, pt(2)); post(.leftMouseUp, pt(2)); usleep(80_000)
    post(.leftMouseDown, pt(2), clicks: 2); post(.leftMouseUp, pt(2), clicks: 2)
case "drag":
    let from = pt(2), to = pt(4)
    post(.mouseMoved, from); usleep(400_000)   // let hover show the handle
    post(.leftMouseDown, from); usleep(100_000)
    for i in 1...30 {
        let f = Double(i) / 30
        post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f))
        usleep(16_000)
    }
    usleep(100_000)
    post(.leftMouseUp, to)
default: break
}
