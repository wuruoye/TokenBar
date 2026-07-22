import AppKit

/// Avoids peeking at AppKit's event queue on menu-tracking passes where no keyboard event
/// can be pending. Core Graphics counters are cheap to read and keep mouse movement from
/// turning the shortcut monitor into a hot path.
@MainActor
final class MenuTrackingShortcutPeekGate {
    private let eventTypes: [CGEventType]
    private let counterProvider: (CGEventType) -> UInt32
    private var lastCounters: [UInt32]?
    private var heldKeyCodes: Set<UInt16> = []
    private var emptyPeekBudget = 0

    init(
        eventTypes: [CGEventType],
        counterProvider: @escaping (CGEventType) -> UInt32 = { type in
            CGEventSource.counterForEventType(.combinedSessionState, eventType: type)
        })
    {
        self.eventTypes = eventTypes
        self.counterProvider = counterProvider
    }

    func shouldPeek() -> Bool {
        let counters = self.eventTypes.map(self.counterProvider)
        let countersChanged = self.lastCounters.map { counters != $0 } ?? true
        self.lastCounters = counters
        if countersChanged {
            // WindowServer can advance a counter one pass before AppKit queues its NSEvent.
            self.emptyPeekBudget = max(self.emptyPeekBudget, 2)
        }
        // Core Graphics does not advance the counter for key-repeat events.
        if !self.heldKeyCodes.isEmpty {
            return true
        }
        return self.emptyPeekBudget > 0
    }

    func observe(_ event: NSEvent) {
        self.emptyPeekBudget = max(self.emptyPeekBudget, 1)
        switch event.type {
        case .keyDown:
            self.heldKeyCodes.insert(event.keyCode)
        case .keyUp:
            self.heldKeyCodes.remove(event.keyCode)
        default:
            break
        }
    }

    func observeQueueEmpty(afterFindingEvent: Bool) {
        if afterFindingEvent {
            self.emptyPeekBudget = max(self.emptyPeekBudget - 1, 1)
        } else if self.emptyPeekBudget > 0 {
            self.emptyPeekBudget -= 1
        }
    }
}

/// `NSMenu` consumes keyboard events in its nested tracking loop, before normal local event
/// monitors or `performKeyEquivalent(with:)` can see them. This observer peeks only while a
/// menu tracking session is active and removes events only when the callback handles them.
@MainActor
final class MenuTrackingShortcutMonitor {
    private static let peekMode = RunLoop.Mode("com.wuruoye.tokenbar.menu-shortcut-peek")

    private let callback: @MainActor (NSEvent) -> Bool
    private let observer: CFRunLoopObserver
    private let trackingState = MenuTrackingState()
    private var isActive = false

    init(
        events: NSEvent.EventTypeMask,
        peekGate: MenuTrackingShortcutPeekGate = MenuTrackingShortcutPeekGate(
            eventTypes: [.keyDown, .keyUp]),
        callback: @escaping @MainActor (NSEvent) -> Bool)
    {
        self.callback = callback
        let trackingState = self.trackingState

        self.observer = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.beforeSources.rawValue,
            true,
            0)
        { [events, peekGate, callback, trackingState] _, _ in
            MainActor.assumeIsolated {
                guard trackingState.isActive, peekGate.shouldPeek() else { return }
                var foundEvent = false
                var blockedByUnhandledEvent = false
                while let event = NSApp.nextEvent(
                    matching: events,
                    until: .distantPast,
                    inMode: Self.peekMode,
                    dequeue: false)
                {
                    foundEvent = true
                    peekGate.observe(event)
                    guard callback(event) else {
                        blockedByUnhandledEvent = true
                        break
                    }
                    _ = NSApp.nextEvent(
                        matching: events,
                        until: .distantPast,
                        inMode: Self.peekMode,
                        dequeue: true)
                }
                if !blockedByUnhandledEvent {
                    peekGate.observeQueueEmpty(afterFindingEvent: foundEvent)
                }
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            self.stop()
        }
    }

    func start() {
        guard !self.isActive else { return }
        CFRunLoopAddObserver(
            RunLoop.main.getCFRunLoop(),
            self.observer,
            CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        self.isActive = true

        // Arm only once AppKit's nested menu loop is alive and pumping events.
        let trackingState = self.trackingState
        RunLoop.main.perform(inModes: [.eventTracking]) {
            MainActor.assumeIsolated {
                trackingState.isActive = true
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    func stop() {
        self.trackingState.isActive = false
        guard self.isActive else { return }
        CFRunLoopRemoveObserver(
            RunLoop.main.getCFRunLoop(),
            self.observer,
            CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        self.isActive = false
    }
}

@MainActor
private final class MenuTrackingState {
    var isActive = false
}
