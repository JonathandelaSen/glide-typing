import AppKit
import ApplicationServices
import CoreGraphics

// Checkpoint 0 spike for docs/plans/05-workspace-profiles.md.
// Probes the private CGS/SkyLight symbols, enumerates displays/Spaces,
// creates a disposable panel, moves it to another Space, verifies, and
// moves it back. Prints an evidence report to stdout. Read-only for
// everything except the spike's own panel.

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

typealias MainConnectionFn = @convention(c) () -> CGSConnectionID
typealias CopySpacesFn = @convention(c) (CGSConnectionID, Int32) -> Unmanaged<CFArray>?
typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
typealias GetCurrentSpaceFn = @convention(c) (CGSConnectionID, CFString) -> CGSSpaceID
typealias MoveWindowsFn = @convention(c) (CGSConnectionID, CFArray, CGSSpaceID) -> Void
typealias GetWindowWorkspaceFn = @convention(c) (CGSConnectionID, UInt32, UnsafeMutablePointer<Int32>) -> Int32
typealias CopySpacesForWindowsFn = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
typealias SetCurrentSpaceFn = @convention(c) (CGSConnectionID, CFString, CGSSpaceID) -> Void
typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

let candidatePaths = [
    "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
    "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/ApplicationServices",
]

var handles: [UnsafeMutableRawPointer] = []
for path in candidatePaths {
    if let h = dlopen(path, RTLD_NOW) { handles.append(h) }
}

func resolve(_ name: String) -> UnsafeMutableRawPointer? {
    for h in handles {
        if let s = dlsym(h, name) { return s }
    }
    // RTLD_DEFAULT as a last resort (CoreGraphics re-exports some CGS).
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
}

let probeNames = [
    "CGSMainConnectionID",
    "CGSCopySpaces",
    "CGSGetWindowWorkspace",
    "CGSMoveWindowsToManagedSpace",
    "CGSManagedDisplayGetCurrentSpace",
    "CGSCopyManagedDisplaySpaces",
    "CGSCopySpacesForWindows",
    "CGSManagedDisplaySetCurrentSpace",
    "CGSAddWindowsToSpaces",
    "CGSRemoveWindowsFromSpaces",
    "_AXUIElementGetWindow",
]

print("== symbol probe (SkyLight loaded: \(handles.count) handles)")
var syms: [String: UnsafeMutableRawPointer] = [:]
for name in probeNames {
    let p = resolve(name)
    if let p { syms[name] = p }
    print("   \(p != nil ? "FOUND  " : "missing") \(name)")
}

// Missing-symbol degradation proof: a bogus symbol resolves to nil and the
// adapter path reports a disabled capability instead of crashing.
let bogus = resolve("CGSDefinitelyNotARealSymbolNuma")
print("   bogus symbol resolves nil: \(bogus == nil ? "yes (capability would disable cleanly)" : "NO?!")")

guard let mainConnPtr = syms["CGSMainConnectionID"] else {
    print("RESULT: no CGSMainConnectionID — capability disabled, exiting cleanly")
    exit(0)
}
let mainConnection = unsafeBitCast(mainConnPtr, to: MainConnectionFn.self)
let cid = mainConnection()
print("\n== connection: \(cid)")

// Display identity.
let displayID = CGMainDisplayID()
var displayUUIDString: CFString = "Main" as CFString
if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
   let s = CFUUIDCreateString(nil, uuid) {
    displayUUIDString = s
}
print("main display id=\(displayID) uuid=\(displayUUIDString)")
print("screensHaveSeparateSpaces=\(NSScreen.screensHaveSeparateSpaces)")

// Ordered spaces per display.
var orderedUserSpaces: [CGSSpaceID] = []
if let ptr = syms["CGSCopyManagedDisplaySpaces"] {
    let fn = unsafeBitCast(ptr, to: CopyManagedDisplaySpacesFn.self)
    if let arr = fn(cid)?.takeRetainedValue() as? [[String: Any]] {
        print("\n== CGSCopyManagedDisplaySpaces: \(arr.count) display(s)")
        for display in arr {
            let ident = display["Display Identifier"] as? String ?? "?"
            let current = (display["Current Space"] as? [String: Any])?["id64"] as? UInt64 ?? 0
            print("   display \(ident) currentSpace=\(current)")
            if let spaces = display["Spaces"] as? [[String: Any]] {
                for (i, s) in spaces.enumerated() {
                    let sid = s["id64"] as? UInt64 ?? 0
                    let type = s["type"] as? Int ?? -1
                    print("      [\(i)] id64=\(sid) type=\(type) uuid=\(s["uuid"] as? String ?? "?")")
                    if type == 0 { orderedUserSpaces.append(sid) }
                }
            }
        }
    } else {
        print("CGSCopyManagedDisplaySpaces returned nil/unparseable")
    }
}

if let ptr = syms["CGSCopySpaces"] {
    let fn = unsafeBitCast(ptr, to: CopySpacesFn.self)
    let all = fn(cid, 7)?.takeRetainedValue() as? [UInt64]
    print("\n== CGSCopySpaces(mask 7): \(all.map(String.init(describing:)) ?? "nil")")
}

var currentSpace: CGSSpaceID = 0
if let ptr = syms["CGSManagedDisplayGetCurrentSpace"] {
    let fn = unsafeBitCast(ptr, to: GetCurrentSpaceFn.self)
    currentSpace = fn(cid, displayUUIDString)
    print("\n== CGSManagedDisplayGetCurrentSpace: \(currentSpace)")
}

guard orderedUserSpaces.count >= 2 else {
    print("RESULT: fewer than 2 user spaces (\(orderedUserSpaces)); cannot test moves")
    exit(0)
}

// Disposable panel owned by this process.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let panel = NSPanel(contentRect: NSRect(x: 60, y: 60, width: 80, height: 50),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
panel.level = .floating
panel.alphaValue = 0.02
panel.isReleasedWhenClosed = false
panel.orderFrontRegardless()
RunLoop.current.run(until: Date().addingTimeInterval(0.5))
let wid = UInt32(panel.windowNumber)
print("\n== disposable panel: CGWindowID=\(wid)")

func spacesForWindow(_ wid: UInt32) -> [CGSSpaceID] {
    guard let ptr = syms["CGSCopySpacesForWindows"] else { return [] }
    let fn = unsafeBitCast(ptr, to: CopySpacesForWindowsFn.self)
    let windows = [NSNumber(value: wid)] as CFArray
    return (fn(cid, 7, windows)?.takeRetainedValue() as? [UInt64]) ?? []
}

func workspaceForWindow(_ wid: UInt32) -> Int32? {
    guard let ptr = syms["CGSGetWindowWorkspace"] else { return nil }
    let fn = unsafeBitCast(ptr, to: GetWindowWorkspaceFn.self)
    var ws: Int32 = -1
    let err = fn(cid, wid, &ws)
    return err == 0 ? ws : nil
}

let originalSpaces = spacesForWindow(wid)
print("   CGSCopySpacesForWindows: \(originalSpaces)")
print("   CGSGetWindowWorkspace: \(String(describing: workspaceForWindow(wid)))")

let origin = originalSpaces.first ?? currentSpace
guard let target = orderedUserSpaces.first(where: { $0 != origin }) else {
    print("RESULT: no distinct target space"); exit(0)
}

if let ptr = syms["CGSMoveWindowsToManagedSpace"] {
    let fn = unsafeBitCast(ptr, to: MoveWindowsFn.self)
    let windows = [NSNumber(value: wid)] as CFArray
    print("\n== moving window \(wid): space \(origin) -> \(target)")
    fn(cid, windows, target)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let after = spacesForWindow(wid)
    print("   after move: \(after)  (moved: \(after == [target] ? "YES" : "NO"))")

    fn(cid, windows, origin)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let back = spacesForWindow(wid)
    print("   after return: \(back)  (returned: \(back == [origin] ? "YES" : "NO"))")
} else {
    print("\n== CGSMoveWindowsToManagedSpace missing — move capability disabled")
}

// AX <-> CG window mapping on our own window (no TCC needed for own process).
print("\n== AX mapping (AXIsProcessTrusted=\(AXIsProcessTrusted()))")
if let ptr = syms["_AXUIElementGetWindow"] {
    let fn = unsafeBitCast(ptr, to: AXGetWindowFn.self)
    let axApp = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
    if err == .success, let axWindows = value as? [AXUIElement], let first = axWindows.first {
        var mapped: UInt32 = 0
        let werr = fn(first, &mapped)
        print("   _AXUIElementGetWindow err=\(werr.rawValue) mapped=\(mapped) matches=\(mapped == wid)")
    } else {
        print("   AX windows enumeration err=\(err.rawValue) (panel may be skipped by AX)")
    }
}

// Space switching probe: switch to an adjacent space and back, verifying.
if let ptr = syms["CGSManagedDisplaySetCurrentSpace"],
   let getPtr = syms["CGSManagedDisplayGetCurrentSpace"] {
    let setFn = unsafeBitCast(ptr, to: SetCurrentSpaceFn.self)
    let getFn = unsafeBitCast(getPtr, to: GetCurrentSpaceFn.self)
    let before = getFn(cid, displayUUIDString)
    let switchTarget = orderedUserSpaces.first(where: { $0 != before }) ?? before
    print("\n== CGSManagedDisplaySetCurrentSpace probe: \(before) -> \(switchTarget)")
    setFn(cid, displayUUIDString, switchTarget)
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    let mid = getFn(cid, displayUUIDString)
    print("   after set: current=\(mid) (switched: \(mid == switchTarget ? "YES" : "NO"))")
    if mid != before {
        setFn(cid, displayUUIDString, before)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let end = getFn(cid, displayUUIDString)
        print("   after return: current=\(end) (returned: \(end == before ? "YES" : "NO"))")
    }
}

panel.close()
print("\nRESULT: spike complete")
exit(0)
