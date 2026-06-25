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


    /// CGWindowIDs of *real* windows of `pid` that sit on a Space that isn't currently shown — i.e.
    /// windows the Accessibility API can't see because they're on another desktop. (Ghostty only
    /// exposes its focused window to AX, so CGWindowList is the only way to find the others.) Junk
    /// layers / tiny shadow windows are filtered out.
    static func hiddenWindowIDs(ofPID pid: pid_t) -> [CGWindowID] {
        guard let conn else { return [] }
        let cid = conn()
        let current = Set(displayLayout(cid).current.values)
        guard let infos = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var out: [CGWindowID] = []
        for w in infos {
            guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let num = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Height"] ?? 0) > 120, (b["Width"] ?? 0) > 200 else { continue }
            guard let sp = spaces(of: num, cid).first, !current.contains(sp) else { continue }
            out.append(num)
        }
        return out
    }

    // The PSN (ProcessSerialNumber, two UInt32s) is passed as an opaque 8-byte void* so the C
    // function types stay representable.
    private typealias GetPSNFn    = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias SetFrontFn  = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    private typealias PostEvtFn   = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    private static let getPSN    = sym(["GetProcessForPID"], as: GetPSNFn.self)
    private static let setFront  = sym(["_SLPSSetFrontProcessWithOptions"], as: SetFrontFn.self)
    private static let postEvent = sym(["SLPSPostEventRecordTo"], as: PostEvtFn.self)

    private typealias DockFn = @convention(c) (CFString, Int32) -> Void
    private static let coreDock = sym(["CoreDockSendNotification"], as: DockFn.self)

    /// Trigger App Exposé for the *front* application (activate the target app first). This fans out
    /// all of that app's windows across every desktop as thumbnails; when the user clicks one, macOS
    /// natively brings it forward — the only reliable way to reach a window on another desktop on
    /// modern macOS, where the private Space/window-move SPI is locked down.
    @discardableResult
    static func appExpose() -> Bool {
        guard let coreDock else { return false }
        coreDock("com.apple.expose.front.awake" as CFString, 0)
        return true
    }

    /// Focus a specific window by its CGWindowID. This switches to the window's Space and makes it
    /// key *without* a generic app-activate — which would otherwise drag the window to the active
    /// Space or revert a Space switch. The synthetic-event sequence is the AltTab/Hammerspoon idiom.
    @discardableResult
    static func focusWindowID(_ wid: CGWindowID, pid: pid_t) -> Bool {
        guard let getPSN, let setFront, let postEvent else { return false }
        let psn = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 4)
        defer { psn.deallocate() }
        psn.initializeMemory(as: UInt8.self, repeating: 0, count: 8)
        guard getPSN(pid, psn) == 0 else { return false }
        _ = setFront(psn, wid, 0x2 /* kCPSUserGenerated */)
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var w = wid
        withUnsafeBytes(of: &w) { for i in 0..<4 { bytes[0x3c + i] = $0[i] } }
        for i in 0..<0x10 { bytes[0x20 + i] = 0xff }
        bytes[0x08] = 0x02
        _ = bytes.withUnsafeMutableBufferPointer { postEvent(psn, $0.baseAddress!) }
        bytes[0x08] = 0x01
        _ = bytes.withUnsafeMutableBufferPointer { postEvent(psn, $0.baseAddress!) }
        return true
    }
}
