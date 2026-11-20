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
}
