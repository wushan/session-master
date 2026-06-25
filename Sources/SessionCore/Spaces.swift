import AppKit
import ApplicationServices
import Darwin

/// Best-effort cross-Space (virtual desktop) window moving via the private SkyLight/CGS SPI —
/// the same symbols yabai / AltTab / Hammerspoon use. macOS exposes no public API for Spaces, so
/// a window on another desktop stays hidden when you just `AXRaise` it. We resolve the symbols at
/// runtime with `dlsym` (never hard-linking private symbols) and every entry point degrades to a
/// no-op if a symbol is absent on this macOS version.
enum Spaces {
    typealias CGSConnectionID = Int32
    typealias CGSSpaceID = UInt64

    // _AXUIElementGetWindow(AXUIElementRef, CGWindowID*) -> AXError   (HIServices private SPI)
    private typealias GetWindowFn    = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias ConnFn         = @convention(c) () -> CGSConnectionID
    private typealias CurrentSpaceFn = @convention(c) (CGSConnectionID, CFString) -> CGSSpaceID
    private typealias ActiveSpaceFn  = @convention(c) (CGSConnectionID) -> CGSSpaceID
    private typealias MoveFn         = @convention(c) (CGSConnectionID, CFArray, CGSSpaceID) -> Void
    private typealias SpacesForWinFn = @convention(c) (CGSConnectionID, Int, CFArray) -> Unmanaged<CFArray>?

    /// CGS/SLS symbols come in once AppKit is loaded, but `_AXUIElementGetWindow` (the AX→CGWindowID
    /// bridge) lives in HIServices, which isn't loaded until something asks for it — so dlopen both
    /// private frameworks once before resolving. dlopen finds them in the dyld shared cache even
    /// when the paths don't exist on disk.
    private static let frameworksLoaded: Bool = {
        dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_NOW)
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        return true
    }()

    private static func sym<T>(_ names: [String], as type: T.Type) -> T? {
        _ = frameworksLoaded
        let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
        for n in names {
            if let p = dlsym(RTLD_DEFAULT, n) { return unsafeBitCast(p, to: T.self) }
        }
        return nil
    }

    // CGS… is the legacy prefix; SLS… is the SkyLight prefix kept as an alias. Try both.
    private static let getWindow    = sym(["_AXUIElementGetWindow"], as: GetWindowFn.self)
    private static let conn         = sym(["CGSMainConnectionID", "SLSMainConnectionID", "_CGSDefaultConnection"], as: ConnFn.self)
    private static let currentSpace = sym(["CGSManagedDisplayGetCurrentSpace", "SLSManagedDisplayGetCurrentSpace"], as: CurrentSpaceFn.self)
    private static let activeSpace  = sym(["CGSGetActiveSpace", "SLSGetActiveSpace"], as: ActiveSpaceFn.self)
    private static let moveWindows  = sym(["CGSMoveWindowsToManagedSpace", "SLSMoveWindowsToManagedSpace"], as: MoveFn.self)
    private static let spacesForWin = sym(["CGSCopySpacesForWindows", "SLSCopySpacesForWindows"], as: SpacesForWinFn.self)

    /// The CGWindowID backing an Accessibility window element.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var wid: CGWindowID = 0
        return getWindow(element, &wid) == .success ? wid : nil
    }

    /// The display's UUID string, the key the managed-space SPI wants.
    static func displayUUID(of screen: NSScreen) -> String? {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let cf = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(n.uint32Value))?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, cf) as String?
    }

    private static func currentSpaceID(_ cid: CGSConnectionID, displayUUID: String?) -> CGSSpaceID? {
        if let currentSpace, let u = displayUUID {
            let s = currentSpace(cid, u as CFString)
            if s != 0 { return s }
        }
        if let activeSpace {                       // fallback: the focused Space, any display
            let s = activeSpace(cid)
            if s != 0 { return s }
        }
        return nil
    }

    /// The Spaces a window currently lives on (empty if the SPI is unavailable).
    private static func spaces(of wid: CGWindowID, _ cid: CGSConnectionID) -> [CGSSpaceID] {
        guard let spacesForWin,
              let arr = spacesForWin(cid, 0x7 /* all spaces */, [wid] as CFArray)?.takeRetainedValue()
              else { return [] }
        return (arr as NSArray).compactMap { ($0 as? NSNumber)?.uint64Value }
    }

    /// Pull a window onto the Space currently shown on `displayUUID` (or the focused Space) so a
    /// recalled terminal on another virtual desktop hops to the one you're looking at. Returns
    /// true when the window was confirmed to be on a *different* Space and we moved it.
    @discardableResult
    static func pullToCurrentSpace(_ window: AXUIElement, displayUUID: String?) -> Bool {
        guard let conn, let moveWindows, let wid = windowID(of: window) else { return false }
        let cid = conn()
        guard let target = currentSpaceID(cid, displayUUID: displayUUID) else { return false }
        let was = spaces(of: wid, cid)
        if !was.isEmpty && was.contains(target) { return false }   // already here — nothing to do
        moveWindows(cid, [wid] as CFArray, target)
        return !was.isEmpty                                        // moved, and we know it was elsewhere
    }
}
