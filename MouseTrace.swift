#!/usr/bin/env swift
import Foundation
import AppKit
import CoreGraphics
import IOKit
import IOKit.hid

// MARK: - Logging & time

let clockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func log(_ s: String) {
    print("\(clockFormatter.string(from: Date()))  \(s)")
    fflush(stdout)
}

let timebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb
}()

func millis(from start: UInt64, to end: UInt64) -> Double {
    guard end >= start else { return 0 }
    return Double(end - start) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
}

// MARK: - Names

func processName(_ pid: pid_t) -> String {
    guard pid > 0 else { return "none" }
    if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName ?? app.bundleIdentifier {
        return "\(name) [pid \(pid)]"
    }
    // proc_pidpath gives the untruncated name (proc_name caps at 16 chars) and works for root daemons.
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
        return "\((String(cString: path) as NSString).lastPathComponent) [pid \(pid)]"
    }
    var name = [CChar](repeating: 0, count: 256)
    if proc_name(pid, &name, UInt32(name.count)) > 0 {
        return "\(String(cString: name)) [pid \(pid)]"
    }
    return "pid \(pid)"
}

func frontmost() -> String {
    guard let app = NSWorkspace.shared.frontmostApplication else { return "unknown" }
    return processName(app.processIdentifier)
}

/// Zero-based button number, matching CGEvent's mouseEventButtonNumber.
func buttonName(_ button: Int) -> String {
    switch button {
    case 0: return "LEFT"
    case 1: return "RIGHT"
    case 2: return "MIDDLE"
    default: return "BTN\(button + 1)"
    }
}

let ioReturnNames: [UInt32: String] = [
    0xE00002BC: "kIOReturnError",
    0xE00002BE: "kIOReturnNoResources",
    0xE00002C0: "kIOReturnNoDevice",
    0xE00002C1: "kIOReturnNotPrivileged",
    0xE00002C2: "kIOReturnBadArgument",
    0xE00002C5: "kIOReturnExclusiveAccess — another process has SEIZED this device; its input bypasses normal delivery",
    0xE00002C7: "kIOReturnUnsupported",
    0xE00002CD: "kIOReturnNotOpen",
    0xE00002E2: "kIOReturnNotPermitted — grant Input Monitoring (to your terminal for make run, to MouseTrace for the watchdog)",
]

func describeIOReturn(_ r: IOReturn) -> String {
    if r == kIOReturnSuccess { return "OK" }
    let code = UInt32(bitPattern: r)
    return String(format: "0x%08X %@", code, ioReturnNames[code] ?? "unrecognized IOReturn")
}

// MARK: - Pipeline layers & click tracking

enum Layer: Int, CaseIterable {
    case hid = 0   // IOKit HID value from the device
    case cgHID     // Quartz tap at the HID location (entry into WindowServer)
    case head      // Quartz session tap, head of chain
    case tail      // Quartz session tap, tail of chain

    var label: String {
        switch self {
        case .hid: return "HID"
        case .cgHID: return "CG-HID"
        case .head: return "CG-HEAD"
        case .tail: return "CG-TAIL"
        }
    }

    var column: String { label.padding(toLength: 9, withPad: " ", startingAt: 0) }

    /// What it means when an event was seen at the previous layer but not at this one.
    var lossMeaning: String {
        switch self {
        case .hid: return ""
        case .cgHID: return "The device reported the button but it never became a Quartz event. WindowServer/IOHIDEventSystem did not receive it: look for a process that SEIZED the device (see DEVICE clients below) or a wedged HID event system."
        case .head: return "Quartz saw it at the HID level but it never reached the session stream. An ACTIVE tap at the HID location dropped it (see taps below), or input was routed to another session."
        case .tail: return "It entered the session stream but was consumed before the tail. An ACTIVE session tap between HEAD and TAIL dropped it (see taps below)."
        }
    }
}

final class Click {
    let id: Int
    let button: Int
    let down: Bool
    let device: DeviceInfo
    var seen: [Layer: UInt64]

    init(id: Int, button: Int, down: Bool, device: DeviceInfo, at t: UInt64) {
        self.id = id
        self.button = button
        self.down = down
        self.device = device
        self.seen = [.hid: t]
    }

    var name: String { "#\(id) \(buttonName(button)) \(down ? "DOWN" : "UP")" }
}

let verdictDelay = 0.5
var pendingClicks: [Click] = []
var nextClickID = 1
var clicksDelivered = 0
var clicksSwallowed = 0
var motion: [Layer: Int] = [:]
var ourTaps: [Layer: CFMachPort] = [:]

// MARK: - HID devices

final class DeviceInfo {
    let index: Int
    let label: String
    var openResult: IOReturn = kIOReturnSuccess
    var buttonsDown: [Int: UInt64] = [:]
    var lastUp: [Int: UInt64] = [:]

    init(index: Int, label: String) {
        self.index = index
        self.label = label
    }
}

var devices: [UnsafeMutableRawPointer: DeviceInfo] = [:]
var nextDeviceIndex = 1

func deviceKey(_ d: IOHIDDevice) -> UnsafeMutableRawPointer {
    Unmanaged.passUnretained(d).toOpaque()
}

func deviceName(_ d: IOHIDDevice) -> String {
    let product = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "unnamed device"
    let maker = IOHIDDeviceGetProperty(d, kIOHIDManufacturerKey as CFString) as? String
    return maker.map { "\($0) \(product)" } ?? product
}

func deviceLabel(_ d: IOHIDDevice) -> String {
    func prop(_ key: String) -> Any? { IOHIDDeviceGetProperty(d, key as CFString) }
    let transport = prop(kIOHIDTransportKey) as? String ?? "?"
    let vid = prop(kIOHIDVendorIDKey) as? Int ?? 0
    let pid = prop(kIOHIDProductIDKey) as? Int ?? 0
    let loc = prop(kIOHIDLocationIDKey) as? Int ?? 0
    let page = prop(kIOHIDPrimaryUsagePageKey) as? Int ?? 0
    let usage = prop(kIOHIDPrimaryUsageKey) as? Int ?? 0
    var entryID: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(d), &entryID)
    return String(format: "%@ [%@ %04x:%04x loc 0x%x usage %d:%d regID 0x%llx]", deviceName(d), transport, vid, pid, loc, page, usage, entryID)
}

func deviceInfo(for d: IOHIDDevice) -> DeviceInfo {
    if let info = devices[deviceKey(d)] { return info }
    let info = DeviceInfo(index: nextDeviceIndex, label: deviceLabel(d))
    nextDeviceIndex += 1
    devices[deviceKey(d)] = info
    return info
}

/// Every user client in the device's IOService subtree, labelled with the process that opened it.
/// A process that seized the device shows up here.
func userClients(of d: IOHIDDevice) -> [String] {
    let service = IOHIDDeviceGetService(d)
    guard service != MACH_PORT_NULL else { return [] }
    var iter: io_iterator_t = 0
    guard IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iter) }
    var clients: [String] = []
    while true {
        let entry = IOIteratorNext(iter)
        guard entry != 0 else { break }
        defer { IOObjectRelease(entry) }
        guard let creator = IORegistryEntryCreateCFProperty(entry, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { continue }
        var cls = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &cls)
        clients.append("\(creator) via \(String(cString: cls))")
    }
    return clients
}

/// Zero-based buttons the device last reported as pressed, read from its element state rather than from
/// events we saw, so a press that began before MouseTrace started (and never released) is still caught.
func heldButtons(of d: IOHIDDevice) -> [Int] {
    let match = [kIOHIDElementUsagePageKey: kHIDPage_Button] as CFDictionary
    guard let elements = IOHIDDeviceCopyMatchingElements(d, match, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { return [] }
    let out = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
    defer { out.deallocate() }
    let held = elements.compactMap { e -> Int? in
        let usage = Int(IOHIDElementGetUsage(e))
        guard usage >= 1, IOHIDDeviceGetValue(d, e, out) == kIOReturnSuccess,
              IOHIDValueGetIntegerValue(out.pointee.takeUnretainedValue()) != 0 else { return nil }
        return usage - 1
    }
    return Set(held).sorted()
}

func logDevice(_ d: IOHIDDevice, _ info: DeviceInfo) {
    log("DEVICE    dev\(info.index) \(info.label)")
    log("            open: \(describeIOReturn(info.openResult))")
    let held = heldButtons(of: d)
    if !held.isEmpty {
        log("            ⚠ HOLDING \(held.map(buttonName).joined(separator: ",")): device last reported these pressed and never released")
    }
    for c in userClients(of: d) { log("            client: \(c)") }
}

func currentDevices() -> [(IOHIDDevice, DeviceInfo)] {
    let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
    return set.map { ($0, deviceInfo(for: $0)) }.sorted { $0.1.index < $1.1.index }
}

/// macOS merges button state across all devices: while any device holds a button, presses of that
/// button on other devices produce no Quartz events at all.
func systemButtonHeld(_ button: Int) -> Bool {
    guard let b = CGMouseButton(rawValue: UInt32(button)) else { return false }
    return CGEventSource.buttonState(.hidSystemState, button: b)
}

func systemButtonSummary() -> String {
    let down = (0..<3).filter(systemButtonHeld).map(buttonName)
    let since = { (t: CGEventType) in CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: t) }
    return String(format: "system buttons held: %@  |  last LEFT down %.1fs ago, up %.1fs ago, drag %.1fs ago, plain move %.1fs ago",
                  down.isEmpty ? "none" : down.joined(separator: ","),
                  since(.leftMouseDown), since(.leftMouseUp), since(.leftMouseDragged), since(.mouseMoved))
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
// One matching dict only: passing several (e.g. Mouse + Pointer) makes IOHIDManager create a separate
// IOHIDDevice per dict for the same service, so every click would be delivered and logged twice.
let mouseMatch: [String: Any] = [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse]
IOHIDManagerSetDeviceMatching(manager, mouseMatch as CFDictionary)

// MARK: - Watch mode: stuck-button watchdog

let stuckThreshold: TimeInterval = 10

func downEventType(_ button: Int) -> CGEventType {
    switch button {
    case 0: return .leftMouseDown
    case 1: return .rightMouseDown
    default: return .otherMouseDown
    }
}

/// Posts a macOS notification. Text goes in via argv so no AppleScript escaping is needed.
func notify(_ message: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title \"MouseTrace\" sound name \"Basso\"", "-e", "end run", message]
    do { try p.run() } catch { log("notification failed: \(error)") }
}

/// Polls the system-wide button state; when a button has been held past the threshold, names the device
/// holding it and posts one notification per stuck episode.
func runWatchdog() -> Never {
    // Stuck detection needs no permission; naming the holding device needs Input Monitoring.
    func hidGranted() -> Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    var hidOpen = false
    func openHIDIfGranted() {
        guard !hidOpen, hidGranted() else { return }
        hidOpen = true
        log("watchdog: Input Monitoring granted, device names available. HID open: \(describeIOReturn(IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))))")
    }
    if !hidGranted() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        log("watchdog: Input Monitoring not granted; stuck buttons are still detected, but not which device holds them. Enable MouseTrace in System Settings > Privacy & Security > Input Monitoring (picked up automatically).")
    }
    openHIDIfGranted()
    log("watchdog: alerting when a button is held ≥ \(Int(stuckThreshold))s")

    var alerted: Set<Int> = []
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        openHIDIfGranted()
        for button in 0..<3 {
            guard systemButtonHeld(button) else {
                if alerted.remove(button) != nil { log("\(buttonName(button)) released") }
                continue
            }
            let held = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: downEventType(button))
            guard held >= stuckThreshold, !alerted.contains(button) else { continue }
            alerted.insert(button)
            let holders = currentDevices().filter { heldButtons(of: $0.0).contains(button) }
            let who = holders.isEmpty
                ? (hidOpen
                    ? "no device reports it; stuck in the HID event system"
                    : "unknown device; grant MouseTrace Input Monitoring to see which")
                : holders.map { deviceName($0.0) }.joined(separator: ", ")
            log(String(format: "⚠ %@ held %.0fs by %@", buttonName(button), held, who))
            for (d, info) in holders { logDevice(d, info) }
            notify(String(format: "%@ button stuck down for %.0fs: %@. Clicks on other mice will be ignored until it's released.",
                          buttonName(button), held, who))
        }
    }
    RunLoop.main.run()
    exit(0)
}

switch CommandLine.arguments.dropFirst().first {
case nil: break
case "--watch": runWatchdog()
default:
    fputs("usage: MouseTrace            trace every click through the input pipeline\n       MouseTrace --watch    notify when a mouse button is stuck down\n", stderr)
    exit(64)
}

let deviceMatched: IOHIDDeviceCallback = { _, _, _, device in
    let info = deviceInfo(for: device)
    // Probe open per device so a seized device is identified individually.
    info.openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    logDevice(device, info)
}

let deviceRemoved: IOHIDDeviceCallback = { _, _, _, device in
    guard let info = devices.removeValue(forKey: deviceKey(device)) else { return }
    log("DEVICE-   dev\(info.index) \(info.label) removed")
}

let hidValue: IOHIDValueCallback = { _, _, _, value in
    let now = mach_absolute_time()
    let element = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let v = IOHIDValueGetIntegerValue(value)

    if page == UInt32(kHIDPage_GenericDesktop), usage == UInt32(kHIDUsage_GD_X) || usage == UInt32(kHIDUsage_GD_Y) {
        if v != 0 { motion[.hid, default: 0] += 1 }
        return
    }
    guard page == UInt32(kHIDPage_Button), usage >= 1 else { return }

    let info = deviceInfo(for: IOHIDElementGetDevice(element))
    let button = Int(usage) - 1
    let down = v != 0
    var notes: [String] = []

    if down {
        if info.buttonsDown[button] != nil { notes.append("⚠ DOWN while already down (lost UP or switch chatter)") }
        if let up = info.lastUp[button], millis(from: up, to: now) < 30 {
            notes.append(String(format: "⚠ only %.1fms since last UP (switch bounce?)", millis(from: up, to: now)))
        }
        info.buttonsDown[button] = now
    } else {
        if let d = info.buttonsDown[button] {
            let held = millis(from: d, to: now)
            notes.append(String(format: "held %.1fms", held))
            if held < 20 { notes.append("⚠ very short press (switch bounce?)") }
        } else {
            notes.append("⚠ UP without DOWN")
        }
        info.buttonsDown[button] = nil
        info.lastUp[button] = now
    }

    let click = Click(id: nextClickID, button: button, down: down, device: info, at: now)
    nextClickID += 1
    pendingClicks.append(click)
    DispatchQueue.main.asyncAfter(deadline: .now() + verdictDelay) { finalize(click) }

    log("\(Layer.hid.column) \(click.name)  dev\(info.index) \(info.label)  \(notes.joined(separator: "  "))")
}

IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatched, nil)
IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemoved, nil)
IOHIDManagerRegisterInputValueCallback(manager, hidValue, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
let hidResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
log("HID manager open: \(describeIOReturn(hidResult))\(hidResult == kIOReturnSuccess ? "" : "  (at least one device failed; per-device results follow)")")

// MARK: - Event tap inventory (every tap on the system, not just ours)

func bit(_ t: CGEventType) -> CGEventMask { CGEventMask(1) << t.rawValue }

let buttonEventMask =
    bit(.leftMouseDown) | bit(.leftMouseUp) |
    bit(.rightMouseDown) | bit(.rightMouseUp) |
    bit(.otherMouseDown) | bit(.otherMouseUp)

let motionEventMask = bit(.mouseMoved) | bit(.leftMouseDragged) | bit(.rightMouseDragged) | bit(.otherMouseDragged)

func systemEventTaps() -> [CGEventTapInformation] {
    var count: UInt32 = 0
    guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
    var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
    guard CGGetEventTapList(count, &list, &count) == .success else { return [] }
    return Array(list.prefix(Int(count)))
}

func tapsMouseButtons(_ t: CGEventTapInformation) -> Bool {
    t.eventsOfInterest & buttonEventMask != 0
}

func describeMask(_ mask: CGEventMask) -> String {
    if mask == ~CGEventMask(0) { return "ALL events" }
    let named: [(CGEventType, String)] = [
        (.leftMouseDown, "Ldown"), (.leftMouseUp, "Lup"),
        (.rightMouseDown, "Rdown"), (.rightMouseUp, "Rup"),
        (.otherMouseDown, "Odown"), (.otherMouseUp, "Oup"),
    ]
    let parts = named.filter { mask & bit($0.0) != 0 }.map(\.1)
    return parts.joined(separator: ",") + String(format: " (mask 0x%llx)", mask)
}

func describeTap(_ t: CGEventTapInformation) -> String {
    let location: String
    switch t.tapPoint {
    case .cghidEventTap: location = "HID"
    case .cgSessionEventTap: location = "session"
    case .cgAnnotatedSessionEventTap: location = "annotated-session"
    @unknown default: location = "location \(t.tapPoint.rawValue)"
    }
    let mode = t.options == .listenOnly ? "listen-only" : "⚠ ACTIVE (can modify/DROP events)"
    let mine = t.tappingProcess == getpid() ? " (this MouseTrace)" : ""
    let target = t.processBeingTapped == 0 ? "all processes" : processName(t.processBeingTapped)
    return String(format: "tap %u by %@%@ at %@ → %@  %@  %@  %@  latency min %.0fµs avg %.0fµs max %.0fµs",
                  t.eventTapID, processName(t.tappingProcess), mine, location, target, mode,
                  t.enabled ? "enabled" : "DISABLED", describeMask(t.eventsOfInterest),
                  t.minUsecLatency, t.avgUsecLatency, t.maxUsecLatency)
}

func logMouseTaps() {
    let taps = systemEventTaps().filter(tapsMouseButtons)
    log("TAPS      \(taps.count) event tap(s) on the system receive mouse button events:")
    for t in taps { log("            \(describeTap(t))") }
}

var knownTaps: [UInt32: CGEventTapInformation] = [:]

/// Reports taps that appear, disappear, or toggle — e.g. an app installing a filter right when clicks start vanishing.
func diffTaps() {
    let current = Dictionary(systemEventTaps().filter(tapsMouseButtons).map { ($0.eventTapID, $0) }, uniquingKeysWith: { a, _ in a })
    for (id, t) in current {
        if let old = knownTaps[id] {
            if old.enabled != t.enabled { log("TAP~      \(describeTap(t))") }
        } else {
            log("TAP+      \(describeTap(t))")
        }
    }
    for (id, t) in knownTaps where current[id] == nil {
        log("TAP-      \(describeTap(t))")
    }
    knownTaps = current
}

// MARK: - What is under the cursor

func windowStack(at p: CGPoint, limit: Int = 3) -> [String] {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [String] = []
    for w in windows {
        guard let boundsDict = w[kCGWindowBounds as String],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary),
              bounds.contains(p) else { continue }
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let ownerPID = w[kCGWindowOwnerPID as String] as? Int ?? 0
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
        let title = w[kCGWindowName as String] as? String ?? ""
        let invisible = alpha < 0.05 ? "  ⚠ INVISIBLE overlay" : ""
        out.append(String(format: "%@ [pid %d] layer %d alpha %.2f %@ %.0fx%.0f%@",
                          owner, ownerPID, layer, alpha, title.isEmpty ? "" : "\"\(title)\"",
                          bounds.width, bounds.height, invisible))
        if out.count == limit { break }
    }
    return out
}

func cursorLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

// MARK: - Diagnostics dump

var lastDiagnostics: UInt64 = 0

func dumpDiagnostics(for origin: DeviceInfo, _ reason: String) {
    let now = mach_absolute_time()
    if lastDiagnostics != 0, millis(from: lastDiagnostics, to: now) < 2000 { return }
    lastDiagnostics = now

    log("======== DIAGNOSTICS: \(reason) ========")
    log("frontmost: \(frontmost())")
    let cursor = cursorLocation()
    log(String(format: "windows under cursor (%.0f, %.0f), front to back:", cursor.x, cursor.y))
    for w in windowStack(at: cursor) { log("            \(w)") }
    log("motion seen since start: " + Layer.allCases.map { "\($0.label) \(motion[$0, default: 0])" }.joined(separator: "  "))
    log("our taps: " + Layer.allCases.dropFirst().map { layer in
        guard let tap = ourTaps[layer] else { return "\(layer.label) not installed" }
        return "\(layer.label) \(CGEvent.tapIsEnabled(tap: tap) ? "enabled" : "DISABLED")"
    }.joined(separator: "  "))
    log(systemButtonSummary())
    logMouseTaps()
    // The originating device, plus any device that is seized or holding a button.
    for (d, info) in currentDevices()
    where info === origin || info.openResult != kIOReturnSuccess || !heldButtons(of: d).isEmpty {
        logDevice(d, info)
    }
    log("======== END DIAGNOSTICS ========")
}

// MARK: - Verdicts

func finalize(_ click: Click) {
    pendingClicks.removeAll { $0 === click }
    let expected = Layer.allCases.filter { $0 == .hid || ourTaps[$0] != nil }
    guard let firstMissing = expected.first(where: { click.seen[$0] == nil }) else {
        clicksDelivered += 1
        return
    }
    clicksSwallowed += 1
    let lastSeen = expected[..<expected.firstIndex(of: firstMissing)!].last!
    let seen = expected.filter { click.seen[$0] != nil }.map(\.label).joined(separator: ",")
    let missing = expected.filter { click.seen[$0] == nil }.map(\.label).joined(separator: ",")
    log("✗✗✗ \(click.name) from dev\(click.device.index) SWALLOWED between \(lastSeen.label) and \(firstMissing.label)  (seen: \(seen)  missing: \(missing))")
    log("    \(firstMissing.lossMeaning)")
    if firstMissing == .cgHID, systemButtonHeld(click.button) {
        let holders = currentDevices()
            .filter { $0.1 !== click.device && heldButtons(of: $0.0).contains(click.button) }
            .map { "dev\($0.1.index) \($0.1.label)" }
        log("    ⚠ CAUSE: macOS already considers \(buttonName(click.button)) held"
            + (holders.isEmpty ? " (no device reports holding it: stuck in the HID event system itself)."
                               : " by \(holders.joined(separator: "; ")). Presses on other devices are absorbed into that stuck press."))
        if !holders.isEmpty { log("    FIX: press and release \(buttonName(click.button)) on that device, or power-cycle it.") }
    }
    dumpDiagnostics(for: click.device, "\(click.name) lost between \(lastSeen.label) and \(firstMissing.label)")
}

// MARK: - Quartz event taps

func handleCGButton(_ layer: Layer, _ type: CGEventType, _ event: CGEvent) {
    let now = mach_absolute_time()
    let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
    let click = pendingClicks.last { $0.button == button && $0.down == down && $0.seen[layer] == nil }
    click?.seen[layer] = now

    let p = event.location
    let target = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
    let source = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
    let sourceState = event.getIntegerValueField(.eventSourceStateID)
    let userData = event.getIntegerValueField(.eventSourceUserData)
    let clickState = event.getIntegerValueField(.mouseEventClickState)

    var parts = ["\(layer.column) \(buttonName(button)) \(down ? "DOWN" : "UP")"]
    if let click {
        parts.append(String(format: "#%d +%.1fms", click.id, millis(from: click.seen[.hid]!, to: now)))
    } else {
        parts.append("(no pending HID event: trackpad/unmatched device, synthetic, or arrived >\(Int(verdictDelay * 1000))ms late)")
    }
    parts.append(String(format: "x=%.1f y=%.1f clickState=%lld", p.x, p.y, clickState))
    if target > 0 { parts.append("target=\(processName(target))") }
    if source > 0 { parts.append("source=\(processName(source))") }
    if sourceState != Int64(CGEventSourceStateID.hidSystemState.rawValue) {
        parts.append("⚠ posted by software (sourceState=\(sourceState))")
    }
    if userData != 0 { parts.append(String(format: "userData=0x%llx", userData)) }
    if layer == .head && down {
        parts.append("front=\(frontmost())")
        if let top = windowStack(at: p, limit: 1).first { parts.append("window=\(top)") }
    }
    log(parts.joined(separator: "  "))
}

let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    let layer = Layer(rawValue: Int(bitPattern: userInfo))!
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        log("\(layer.column) ⚠ TAP DISABLED by \(type == .tapDisabledByTimeout ? "timeout" : "user input"), re-enabling")
        if let tap = ourTaps[layer] { CGEvent.tapEnable(tap: tap, enable: true) }
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
        motion[layer, default: 0] += 1
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
        handleCGButton(layer, type, event)
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

func installTap(_ layer: Layer, _ location: CGEventTapLocation, _ place: CGEventTapPlacement) {
    guard let tap = CGEvent.tapCreate(
        tap: location,
        place: place,
        options: .listenOnly,
        eventsOfInterest: buttonEventMask | motionEventMask,
        callback: tapCallback,
        userInfo: UnsafeMutableRawPointer(bitPattern: layer.rawValue)
    ) else {
        log("\(layer.column) could not create tap (grant Terminal Accessibility + Input Monitoring, then restart Terminal)")
        return
    }
    ourTaps[layer] = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("\(layer.column) tap installed")
}

// Layer.hid is 0, so userInfo for real taps is never a null pointer.
installTap(.cgHID, .cghidEventTap, .headInsertEventTap)
installTap(.head, .cgSessionEventTap, .headInsertEventTap)
installTap(.tail, .cgSessionEventTap, .tailAppendEventTap)

guard ourTaps[.head] != nil || ourTaps[.cgHID] != nil else {
    fputs("No Quartz taps could be created. Grant Terminal Accessibility/Input Monitoring, then rerun.\n", stderr)
    exit(2)
}

// MARK: - Watchdogs

var lastStatus = ""

/// Proves the taps are alive: if HID motion climbs but CG motion doesn't, the Quartz side is dead or blind.
Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
    let status = "moves " + Layer.allCases.map { "\($0.label) \(motion[$0, default: 0])" }.joined(separator: "  ")
        + "  |  clicks delivered \(clicksDelivered)  swallowed \(clicksSwallowed)"
    guard status != lastStatus else { return }
    lastStatus = status
    log("STATUS    \(status)")
}

Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    diffTaps()
    for (layer, tap) in ourTaps where !CGEvent.tapIsEnabled(tap: tap) {
        log("\(layer.column) ⚠ found our tap disabled without notification, re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

log("MouseTrace running. Ctrl-C to stop.")
log("Every HID button event gets an id (#n). Each Quartz layer that sees it logs +latency.")
log("If any layer misses it within \(Int(verdictDelay * 1000))ms you get a ✗✗✗ SWALLOWED verdict plus a diagnostics dump.")
log("All taps here are listen-only; this program never modifies or drops events.")
log(systemButtonSummary())
logMouseTaps()
knownTaps = Dictionary(systemEventTaps().filter(tapsMouseButtons).map { ($0.eventTapID, $0) }, uniquingKeysWith: { a, _ in a })

RunLoop.main.run()
