import Foundation

/// The USB identity of a physical device (PRD F27).
///
/// Flashing destroys and recreates the volume, so a flashed drive cannot be
/// tracked by volume UUID the way a Ventoy drive is. What survives a flash is
/// the hardware: the USB vendor/product IDs and, on well-behaved sticks, a
/// serial number.
///
/// Not every stick reports a serial. Without one, vendor+product alone
/// identifies a *model*, not a unit — two identical sticks are indistinguishable
/// — so capacity is used as a tie-breaker and the identity is flagged **weak**
/// in the UI rather than being silently trusted.
public struct HardwareID: Codable, Hashable, Sendable {
    public var vendorID: Int
    public var productID: Int
    /// Nil or empty on sticks that publish no serial → weak identity.
    public var serialNumber: String?
    /// Vendor/product strings, purely for display ("SanDisk Cruzer Blade").
    public var vendorName: String?
    public var productName: String?

    public init(vendorID: Int, productID: Int, serialNumber: String? = nil,
                vendorName: String? = nil, productName: String? = nil) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = HardwareID.normalized(serialNumber)
        self.vendorName = vendorName
        self.productName = productName
    }

    private static func normalized(_ serial: String?) -> String? {
        guard let trimmed = serial?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// False when the device reports no serial: vendor+product identify the
    /// model only, so two identical sticks would look like the same drive.
    public var isStrongIdentity: Bool { serialNumber != nil }

    /// "0x0781:0x5583 · serial 4C530001..." — shown in the flashed drive's
    /// device section so the user can tell which stick a registration means.
    public var displayText: String {
        let ids = String(format: "0x%04x:0x%04x", vendorID, productID)
        guard let serialNumber else { return ids }
        return "\(ids) · serial \(serialNumber)"
    }

    /// Does `candidate` describe the same physical stick as this registration?
    ///
    /// With serials on both sides the answer is exact. Without, vendor+product
    /// must agree and — when both capacities are known — match, which is the
    /// documented weak heuristic (DESIGN §9).
    public func matches(_ candidate: HardwareID,
                        sizeBytes: Int64? = nil,
                        candidateSizeBytes: Int64? = nil) -> Bool {
        guard vendorID == candidate.vendorID, productID == candidate.productID else { return false }
        if let mine = serialNumber, let theirs = candidate.serialNumber {
            return mine.caseInsensitiveCompare(theirs) == .orderedSame
        }
        // One side has no serial: fall back to the model+capacity heuristic.
        if let sizeBytes, let candidateSizeBytes { return sizeBytes == candidateSizeBytes }
        return true
    }
}
