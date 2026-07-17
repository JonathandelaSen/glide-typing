import AppKit

/// Fingerprints the connected displays and compares a saved signature with
/// the current one. Comparison and mapping are pure so checks can cover the
/// compatibility rules without real displays.
enum DisplayConfigurationResolver {
    @MainActor
    static func currentSignature(spaceManager: SpaceManaging) -> DisplayConfigurationSignature {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
        let displays = screens.map { screen -> DisplaySignature in
            let displayID = (screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) } ?? 0
            let uuid = displayUUID(for: displayID)
            return DisplaySignature(
                uuid: uuid,
                localizedName: screen.localizedName,
                vendorNumber: CGDisplayVendorNumber(displayID),
                modelNumber: CGDisplayModelNumber(displayID),
                serialNumber: CGDisplaySerialNumber(displayID),
                frame: WorkspaceGeometry.cgRect(fromAppKit: screen.frame,
                                                primaryHeight: primaryHeight),
                visibleFrame: WorkspaceGeometry.cgRect(fromAppKit: screen.visibleFrame,
                                                       primaryHeight: primaryHeight),
                rotationDegrees: Int(CGDisplayRotation(displayID)),
                isPrimary: screen.frame.origin == .zero,
                userSpaceCount: spaceManager.orderedUserSpaceIDs(displayUUID: uuid).count)
        }
        return DisplayConfigurationSignature(
            displays: displays,
            screensHaveSeparateSpaces: NSScreen.screensHaveSeparateSpaces)
    }

    static func displayUUID(for displayID: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) else {
            return "display-\(displayID)"
        }
        return string as String
    }

    private static func ordered(_ displays: [DisplaySignature]) -> [DisplaySignature] {
        displays.sorted {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            if $0.frame.origin.x != $1.frame.origin.x {
                return $0.frame.origin.x < $1.frame.origin.x
            }
            return $0.uuid < $1.uuid
        }
    }

    /// Mismatch reasons, empty when the saved profile matches the current
    /// hardware exactly. A same-count-different-hardware setup never matches.
    static func mismatchReasons(saved: DisplayConfigurationSignature,
                                current: DisplayConfigurationSignature) -> [String] {
        if saved.displays.count != current.displays.count {
            return ["Captured with \(saved.displays.count) display(s), "
                    + "\(current.displays.count) connected now"]
        }
        var reasons: [String] = []
        if saved.screensHaveSeparateSpaces != current.screensHaveSeparateSpaces {
            reasons.append("The 'Displays have separate Spaces' setting changed")
        }
        for (savedDisplay, currentDisplay) in zip(ordered(saved.displays),
                                                  ordered(current.displays)) {
            let name = savedDisplay.localizedName
            if savedDisplay.vendorNumber != currentDisplay.vendorNumber
                || savedDisplay.modelNumber != currentDisplay.modelNumber
                || savedDisplay.serialNumber != currentDisplay.serialNumber {
                reasons.append("\(name): different physical display")
            }
            if savedDisplay.frame.size != currentDisplay.frame.size {
                reasons.append("\(name): resolution changed from "
                    + "\(Int(savedDisplay.frame.width))×\(Int(savedDisplay.frame.height)) to "
                    + "\(Int(currentDisplay.frame.width))×\(Int(currentDisplay.frame.height))")
            }
            if savedDisplay.rotationDegrees != currentDisplay.rotationDegrees {
                reasons.append("\(name): rotation changed")
            }
            if savedDisplay.frame.origin != currentDisplay.frame.origin {
                reasons.append("\(name): display arrangement changed")
            }
            if savedDisplay.isPrimary != currentDisplay.isPrimary {
                reasons.append("\(name): primary display changed")
            }
        }
        return reasons
    }

    /// Saved display UUID → current display UUID, pairing by the same stable
    /// order used for comparison. Only meaningful when mismatchReasons is
    /// empty or limited to Space-count drift.
    static func displayUUIDMapping(saved: DisplayConfigurationSignature,
                                   current: DisplayConfigurationSignature) -> [String: String] {
        guard saved.displays.count == current.displays.count else { return [:] }
        var mapping: [String: String] = [:]
        for (savedDisplay, currentDisplay) in zip(ordered(saved.displays),
                                                  ordered(current.displays)) {
            mapping[savedDisplay.uuid] = currentDisplay.uuid
        }
        return mapping
    }

    /// Prerequisites Numa checks but never changes silently.
    static func prerequisiteIssues(automaticSpaceReorderingEnabled: Bool,
                                   displayCount: Int,
                                   screensHaveSeparateSpaces: Bool) -> [String] {
        var issues: [String] = []
        if automaticSpaceReorderingEnabled {
            issues.append("System Settings › Desktop & Dock › \"Automatically rearrange "
                + "Spaces based on most recent use\" must be off")
        }
        if displayCount > 1 && !screensHaveSeparateSpaces {
            issues.append("Multi-display profiles need \"Displays have separate Spaces\" "
                + "enabled in System Settings › Desktop & Dock")
        }
        return issues
    }

    @MainActor
    static func currentPrerequisiteIssues() -> [String] {
        let mru = CFPreferencesCopyAppValue("mru-spaces" as CFString,
                                            "com.apple.dock" as CFString)
        let reorderingEnabled = (mru as? Bool) ?? true
        return prerequisiteIssues(
            automaticSpaceReorderingEnabled: reorderingEnabled,
            displayCount: NSScreen.screens.count,
            screensHaveSeparateSpaces: NSScreen.screensHaveSeparateSpaces)
    }
}
