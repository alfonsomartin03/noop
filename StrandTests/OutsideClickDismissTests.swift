import XCTest
import AppKit
import SwiftUI
@testable import NOOP

/// `DismissOnOutsideClick` against a real sheet: a parent window, an attached sheet window hosting the modifier, and
/// mouse events posted to NSApp's queue and dispatched through `nextEvent` (where local monitors run) + `sendEvent`.
final class OutsideClickDismissTests: XCTestCase {
    private final class Target: NSObject {
        var fired = 0
        @objc func hit() { fired += 1 }
    }

    private var parent: NSWindow!
    private var sheet: NSWindow!
    private var closes = 0
    private let target = Target()

    override func setUp() {
        closes = 0
        parent = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 700),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        // A button filling the parent: if a click outside the sheet leaked through, it would fire.
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        button.target = target
        button.action = #selector(Target.hit)
        parent.contentView = button
        parent.makeKeyAndOrderFront(nil)

        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                         styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.contentView = NSHostingView(rootView: Color.clear.frame(width: 400, height: 300)
            .background(DismissOnOutsideClick { [weak self] in self?.closes += 1 }))
        parent.beginSheet(sheet)
        pump(until: { self.sheet.sheetParent === self.parent && self.sheet.isVisible })
        XCTAssertTrue(sheet.sheetParent === parent, "sheet must be attached")
    }

    override func tearDown() {
        if sheet.sheetParent != nil { parent.endSheet(sheet) }
        sheet.orderOut(nil)
        parent.orderOut(nil)
        pump(seconds: 0.1)
    }

    func testClickOnParentOutsideSheetCloses() {
        // Bottom-left corner of the parent's content: the sheet hangs from the top centre, so this is outside it.
        click(in: parent, at: NSPoint(x: 30, y: 30))
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(target.fired, 0, "the click must be consumed, not passed to the view behind")
    }

    func testRightClickOnParentAlsoCloses() {
        click(in: parent, at: NSPoint(x: 30, y: 30), right: true)
        XCTAssertEqual(closes, 1)
    }

    func testClickInsideSheetDoesNotClose() {
        click(in: sheet, at: NSPoint(x: 200, y: 150))
        XCTAssertEqual(closes, 0)
    }

    func testClickAfterSheetEndedIsLeftAlone() {
        parent.endSheet(sheet)
        sheet.orderOut(nil)
        pump(seconds: 0.2)
        click(in: parent, at: NSPoint(x: 30, y: 30))
        XCTAssertEqual(closes, 0)
        XCTAssertEqual(target.fired, 1, "with no sheet the click reaches the window normally")
    }

    // MARK: helpers

    private func click(in window: NSWindow, at point: NSPoint, right: Bool = false) {
        let (down, up): (NSEvent.EventType, NSEvent.EventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        for type in [down, up] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: type == down ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
        }
        pump(seconds: 0.3)
    }

    private func pump(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    private func pump(until done: () -> Bool, timeout: TimeInterval = 3) {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { pump(seconds: 0.05) }
    }
}
