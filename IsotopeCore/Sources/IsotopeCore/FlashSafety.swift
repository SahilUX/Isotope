import Foundation

/// Everything the safety gates need to know about a physical device, gathered by
/// the app's `DeviceEnumerator` and evaluated here so the decision itself is
/// pure, table-tested logic with no DiskArbitration in sight (DESIGN §9).
public struct FlashDeviceDescription: Hashable, Sendable {
    /// "disk4" — the whole disk, never a slice.
    public var bsdName: String
    /// What the confirmation dialog calls this stick.
    public var displayName: String
    public var sizeBytes: Int64
    public var isAttached: Bool
    public var isWholeDisk: Bool
    public var isExternal: Bool
    public var isRemovableOrEjectable: Bool
    public var isUSB: Bool
    /// True when this whole disk backs `/` (or the system's data volume).
    /// Determined by resolving the boot volume to its device, never inferred
    /// from "internal" alone.
    public var isBootDisk: Bool

    public init(bsdName: String, displayName: String, sizeBytes: Int64,
                isAttached: Bool = true, isWholeDisk: Bool = true, isExternal: Bool = true,
                isRemovableOrEjectable: Bool = true, isUSB: Bool = true, isBootDisk: Bool = false) {
        self.bsdName = bsdName
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.isAttached = isAttached
        self.isWholeDisk = isWholeDisk
        self.isExternal = isExternal
        self.isRemovableOrEjectable = isRemovableOrEjectable
        self.isUSB = isUSB
        self.isBootDisk = isBootDisk
    }
}

/// Why a device may not be flashed (PRD F31: always the *specific* reason).
public enum FlashGateFailure: Hashable, Sendable {
    case bootDisk(deviceName: String)
    case notAttached(deviceName: String)
    case notWholeDisk(bsdName: String)
    case notExternal(deviceName: String)
    case notRemovable(deviceName: String)
    case notUSB(deviceName: String)
    case tooSmall(deviceName: String, deviceBytes: Int64, requiredBytes: Int64)

    public var reason: String {
        switch self {
        case .bootDisk(let name):
            return "“\(name)” is the disk macOS is running from. Isotope will never write to it."
        case .notAttached(let name):
            return "“\(name)” is not attached any more. Plug the device back in and try again."
        case .notWholeDisk(let bsdName):
            return "\(bsdName) is a partition, not a whole device. Flashing writes the entire device, so only whole devices are eligible."
        case .notExternal(let name):
            return "“\(name)” reports as an internal disk. Isotope only flashes external devices."
        case .notRemovable(let name):
            return "“\(name)” is not removable or ejectable, so Isotope will not flash it."
        case .notUSB(let name):
            return "“\(name)” is not attached over USB. Isotope only flashes USB devices."
        case .tooSmall(let name, let deviceBytes, let requiredBytes):
            let have = ByteCountFormatter.string(fromByteCount: deviceBytes, countStyle: .file)
            let need = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            return "“\(name)” holds \(have), and this image needs \(need). Use a larger device."
        }
    }
}

/// PRD F29/F31. Evaluated at registration (to list eligible devices) and again
/// immediately before the write, because a device can be swapped, unplugged or
/// remounted between the two.
public enum FlashSafetyGate {
    /// Nil = every gate passed. The order is deliberate: the most dangerous
    /// mistake (the boot disk) is reported first, whatever else is also wrong.
    public static func evaluate(device: FlashDeviceDescription,
                                isoSizeBytes: Int64?) -> FlashGateFailure? {
        if device.isBootDisk { return .bootDisk(deviceName: device.displayName) }
        if !device.isAttached { return .notAttached(deviceName: device.displayName) }
        if !device.isWholeDisk { return .notWholeDisk(bsdName: device.bsdName) }
        if !device.isExternal { return .notExternal(deviceName: device.displayName) }
        if !device.isRemovableOrEjectable { return .notRemovable(deviceName: device.displayName) }
        if !device.isUSB { return .notUSB(deviceName: device.displayName) }
        if let isoSizeBytes, isoSizeBytes > 0, device.sizeBytes < isoSizeBytes {
            return .tooSmall(deviceName: device.displayName,
                             deviceBytes: device.sizeBytes, requiredBytes: isoSizeBytes)
        }
        return nil
    }

    /// Eligibility for the registration list: identical gates minus the size
    /// one, which depends on an image that has not been chosen yet.
    public static func isEligibleForRegistration(_ device: FlashDeviceDescription) -> Bool {
        evaluate(device: device, isoSizeBytes: nil) == nil
    }
}
