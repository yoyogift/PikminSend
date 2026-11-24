import AppKit
import ApplicationServices

@MainActor
final class ShiftDoubleTapMonitor {
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private var isShiftPressed = false
    private var hadKeyPressWhileShiftHeld = false
    private var lastShiftDownTime: TimeInterval?
    private var lastTapReleaseTime: TimeInterval?

    private let maxTapHoldDuration: TimeInterval = 0.28
    private let maxDoubleTapInterval: TimeInterval = 0.38

    var onDoubleTap: (() -> Void)?

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    static func promptAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        stop()

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
            return event
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            Task { @MainActor in
                self?.handleKeyDown()
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyDown()
            }
            return event
        }
    }

    func stop() {
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func handleKeyDown() {
        if isShiftPressed {
            hadKeyPressWhileShiftHeld = true
        }
        lastTapReleaseTime = nil
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shiftNowPressed = flags.contains(.shift)
        let otherModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .function]

        // 若同時按著其他修飾鍵，重置狀態避免誤觸
        if !flags.intersection(otherModifiers).isEmpty {
            resetState()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime

        if shiftNowPressed && !isShiftPressed {
            isShiftPressed = true
            hadKeyPressWhileShiftHeld = false
            lastShiftDownTime = now
        } else if !shiftNowPressed && isShiftPressed {
            isShiftPressed = false

            guard !hadKeyPressWhileShiftHeld,
                  let downTime = lastShiftDownTime,
                  (now - downTime) <= maxTapHoldDuration else {
                // 打字大寫或長按 Shift 不算單次輕點
                lastTapReleaseTime = nil
                return
            }

            if let prevRelease = lastTapReleaseTime,
               (now - prevRelease) <= maxDoubleTapInterval {
                lastTapReleaseTime = nil
                onDoubleTap?()
            } else {
                lastTapReleaseTime = now
            }
        }
    }

    private func resetState() {
        isShiftPressed = false
        hadKeyPressWhileShiftHeld = false
        lastShiftDownTime = nil
        lastTapReleaseTime = nil
    }
}
