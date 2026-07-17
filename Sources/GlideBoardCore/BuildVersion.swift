/// Increment this number with every code change before building GlideBoard.
/// It is shown in the macOS status bar so a running app can be matched to its build.
enum BuildVersion {
    static let code = 35

    static var statusBarTitle: String { "v\(code)" }
}
