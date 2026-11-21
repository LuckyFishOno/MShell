import XCTest
import SwiftUI
import AppKit
@testable import App

@MainActor final class SessionTreeInteractionTests: XCTestCase {
    func testSingleClickSelectsBeforeDoubleClickDeadlineAndDoubleClickStillActivates() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        var selections = 0, activations = 0
        let view = NSHostingView(rootView: Text("Saved folder").frame(width: 240, height: 70).contentShape(Rectangle())
            .modifier(SessionTreeRowInteraction(select: { selections += 1 }, activate: { activations += 1 })))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 70), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let point = NSPoint(x: 120, y: 35)
        func click(_ count: Int) {
            let timestamp = ProcessInfo.processInfo.systemUptime
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: count * 2, clickCount: count, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: timestamp + 0.001, windowNumber: window.windowNumber, context: nil, eventNumber: count * 2 + 1, clickCount: count, pressure: 0)!
            NSApp.sendEvent(down); NSApp.sendEvent(up)
        }
        NSApp.finishLaunching()
        func startWhenReady(_ remaining: Int) {
            guard NSApp.isActive, window.isKeyWindow else {
                guard remaining > 0 else {
                    XCTFail("The owned test window did not become active.")
                    NSApp.stop(nil)
                    NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
                    return
                }
                NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { startWhenReady(remaining - 1) }
                return
            }
            window.makeFirstResponder(view); view.layoutSubtreeIfNeeded()
            click(1)
            DispatchQueue.main.asyncAfter(deadline: .now() + min(0.1, NSEvent.doubleClickInterval / 3)) {
                XCTAssertGreaterThan(selections, 0, "Single selection must not wait for the double-click deadline.")
                XCTAssertEqual(activations, 0)
                click(2)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    XCTAssertEqual(activations, 1, "Double click must retain folder/session activation.")
                    NSApp.stop(nil)
                    let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!
                    NSApp.postEvent(event, atStart: true)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { startWhenReady(40) }
        NSApp.run()
    }

    func testDraggingAFolderRowMovesItWithoutTogglingIt() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        var toggles = 0, drags: [CGPoint] = [], drops: [CGPoint] = []
        let view = NSHostingView(rootView: VStack(spacing: 0) {
            Text("Folder").frame(width: 240, height: 30).contentShape(Rectangle())
                .modifier(SessionTreeRowInteraction(isFolder: true, select: {}, toggle: { toggles += 1 }, activate: {},
                                                    drag: { drags.append($0) }, drop: { drops.append($0) }))
            Color.clear.frame(width: 240, height: 90)
        }.coordinateSpace(name: SessionTreeView.space))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func send(_ type: NSEvent.EventType, _ y: CGFloat, _ number: Int) {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            NSApp.sendEvent(event)
        }
        func stop() {
            NSApp.stop(nil)
            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
        }
        NSApp.finishLaunching()
        func startWhenReady(_ remaining: Int) {
            guard NSApp.isActive, window.isKeyWindow else {
                guard remaining > 0 else { XCTFail("The owned test window did not become active."); stop(); return }
                NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { startWhenReady(remaining - 1) }
                return
            }
            window.makeFirstResponder(view); view.layoutSubtreeIfNeeded()
            // Window coordinates grow upward: the row is the top 30 points, and the drag ends 60 points lower.
            send(.leftMouseDown, 105, 1)
            for (step, y) in stride(from: 100, through: 45, by: -5).enumerated() { send(.leftMouseDragged, CGFloat(y), step + 2) }
            send(.leftMouseUp, 45, 40)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                XCTAssertFalse(drags.isEmpty, "Moving a pressed row must report the drag.")
                XCTAssertEqual(drops.count, 1)
                if let last = drops.last { XCTAssertEqual(last.y, 75, accuracy: 2, "The drop is reported in the tree's coordinate space.") }
                XCTAssertEqual(toggles, 0, "Dragging a folder must not open or close it.")
                send(.leftMouseDown, 105, 50); send(.leftMouseUp, 105, 51)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    XCTAssertEqual(toggles, 1, "A plain click still toggles the folder.")
                    XCTAssertEqual(drops.count, 1, "A click is not a drag.")
                    stop()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { startWhenReady(40) }
        NSApp.run()
    }
}
