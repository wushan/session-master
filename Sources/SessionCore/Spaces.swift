import AppKit
import ApplicationServices
import Darwin

/// Best-effort virtual-desktop (Space) control via the private SkyLight/CGS SPI — the same symbols
/// yabai / AltTab / Hammerspoon use. macOS exposes no public API for Spaces, so a terminal sitting
/// on another desktop stays hidden when you just `AXRaise` it. We resolve the symbols at runtime
/// with `dlsym` (never hard-linking private symbols) and every entry point degrades to a no-op if a
/// symbol is missing on this macOS version.
enum Spaces {
    typealias CGSConnectionID = Int32
    typealias CGSSpaceID = UInt64

    // _AXUIElementGetWindow(AXUIElementRef, CGWindowID*) -> AXError   (HIServices private SPI)
    private typealias GetWindowFn     = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias ConnFn          = @convention(c) () -> CGSConnectionID
    private typealias SetSpaceFn      = @convention(c) (CGSConnectionID, CFString, CGSSpaceID) -> Void
    private typealias SpacesForWinFn  = @convention(c) (CGSConnectionID, Int, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyDisplaysFn  = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?

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
    private static let getWindow     = sym(["_AXUIElementGetWindow"], as: GetWindowFn.self)
    private static let conn          = sym(["CGSMainConnectionID", "SLSMainConnectionID", "_CGSDefaultConnection"], as: ConnFn.self)
    private static let setSpace      = sym(["CGSManagedDisplaySetCurrentSpace", "SLSManagedDisplaySetCurrentSpace"], as: SetSpaceFn.self)
    private static let spacesForWin  = sym(["CGSCopySpacesForWindows", "SLSCopySpacesForWindows"], as: SpacesForWinFn.self)
    private static let copyDisplays  = sym(["CGSCopyManagedDisplaySpaces", "SLSCopyManagedDisplaySpaces"], as: CopyDisplaysFn.self)

    /// The CGWindowID backing an Accessibility window element.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var wid: CGWindowID = 0
        return getWindow(element, &wid) == .success ? wid : nil
    }

    private static func spaceID(_ d: [String: Any]) -> CGSSpaceID? {
        (d["id64"] as? NSNumber)?.uint64Value ?? (d["ManagedSpaceID"] as? NSNumber)?.uint64Value
    }

    /// The Spaces a window currently lives on (empty if the SPI is unavailable).
    private static func spaces(of wid: CGWindowID, _ cid: CGSConnectionID) -> [CGSSpaceID] {
        guard let spacesForWin,
              let arr = spacesForWin(cid, 0x7 /* all spaces */, [wid] as CFArray)?.takeRetainedValue()
              else { return [] }
        return (arr as NSArray).compactMap { ($0 as? NSNumber)?.uint64Value }
    }

    /// Maps every Space → the display UUID that owns it, plus each display's current Space.
    private static func displayLayout(_ cid: CGSConnectionID)
        -> (owner: [CGSSpaceID: String], current: [String: CGSSpaceID]) {
        var owner: [CGSSpaceID: String] = [:]
        var current: [String: CGSSpaceID] = [:]
        guard let copyDisplays,
              let arr = copyDisplays(cid)?.takeRetainedValue() as? [[String: Any]] else { return (owner, current) }
        for disp in arr {
            guard let uuid = disp["Display Identifier"] as? String else { continue }
            for sp in (disp["Spaces"] as? [[String: Any]]) ?? [] {
                if let id = spaceID(sp) { owner[id] = uuid }
            }
            if let cur = disp["Current Space"] as? [String: Any], let id = spaceID(cur) { current[uuid] = id }
        }
        return (owner, current)
    }

    /// Switch the display that owns the window's Space to that Space, so a recalled terminal on
    /// another virtual desktop comes into view. Returns true when it actually changed desktops.
    @discardableResult
    static func switchToWindowSpace(_ window: AXUIElement) -> Bool {
        guard let conn, let setSpace, let wid = windowID(of: window) else { return false }
        let cid = conn()
        let onSpaces = spaces(of: wid, cid)
        guard !onSpaces.isEmpty else { return false }
        let layout = displayLayout(cid)
        // Prefer a Space that isn't already showing; ignore windows pinned to all Spaces.
        guard let target = onSpaces.first(where: { sp in
            guard let disp = layout.owner[sp] else { return false }
            return layout.current[disp] != sp
        }), let disp = layout.owner[target] else { return false }
        setSpace(cid, disp as CFString, target)
        return true
    }
}
