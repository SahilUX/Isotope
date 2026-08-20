import DiskArbitration
import Foundation
import IOKit
import IOKit.storage
import IsotopeCore

/// One physical device as the registration list and the flash pipeline see it
/// (DESIGN §9). Built from a DiskArbitration description plus the IOKit USB
/// properties of the media's parent device.
struct FlashDevice: Identifiable, Hashable, Sendable {
    /// Whole disk only ("disk4"); slices never appear in this list.
    var bsdName: String
    /// "SanDisk Cruzer Blade" — vendor + model, falling back to the BSD name.
    var displayName: String
    var sizeBytes: Int64
    var isWholeDisk: Bool
    var isExternal: Bool
    var isRemovableOrEjectable: Bool
    var isUSB: Bool
    /// Resolved from the volume that backs `/`, never inferred from "internal".
    var isBootDisk: Bool
    var hardwareID: HardwareID?
    /// Volume labels currently mounted from this device, for the picker
    /// ("SANDISK · Ubuntu 24.04 amd64").
    var volumeNames: [String]
    /// Volume UUIDs currently mounted from this device; after a flash the first
    /// one is recorded on the drive for display (PRD F27).
    var volumeUUIDs: [String]
    /// PRD F44: where those volumes are mounted, so the content probe has
    /// somewhere to read from. Defaulted and last so the parameter exists only
    /// for the code that needs it.
    var volumeMountPoints: [URL] = []

    var id: String { bsdName }

    /// The raw character device the write goes to. `rdiskN` rather than `diskN`:
    /// unbuffered, and an order of magnitude faster for a full-device write.
    var rawDevicePath: String { DeviceEnumerator.rawDevicePath(bsdName: bsdName) }
    var blockDevicePath: String { "/dev/\(bsdName)" }

    /// What the safety gates evaluate (IsotopeCore, pure).
    func gateDescription(isAttached: Bool = true) -> FlashDeviceDescription {
        FlashDeviceDescription(bsdName: bsdName, displayName: displayName, sizeBytes: sizeBytes,
                               isAttached: isAttached, isWholeDisk: isWholeDisk,
                               isExternal: isExternal, isRemovableOrEjectable: isRemovableOrEjectable,
                               isUSB: isUSB, isBootDisk: isBootDisk)
    }

    var isEligibleForRegistration: Bool {
        FlashSafetyGate.isEligibleForRegistration(gateDescription())
    }

    /// "32 GB · SANDISK" for the device picker.
    var subtitle: String {
        var parts = [ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)]
        if !volumeNames.isEmpty { parts.append(volumeNames.joined(separator: ", ")) }
        parts.append(bsdName)
        return parts.joined(separator: " · ")
    }
}

/// Enumerates external USB whole disks and watches them come and go
/// (DESIGN §9). DiskArbitration is used for the descriptions and the
/// appear/disappear callbacks; IOKit supplies the USB vendor/product/serial that
/// DiskArbitration does not publish.
///
/// The parsing — turning a description dictionary into a `FlashDevice`, deriving
/// a whole-disk name from a device node — is factored into static functions so
/// it is unit-testable without any hardware.
@MainActor
final class DeviceEnumerator {
    private var session: DASession?
    private var onChange: (() -> Void)?

    // MARK: - Lifecycle

    /// `onChange` fires on the main queue whenever a disk appears or disappears;
    /// the caller re-enumerates (the list is short, so a diff is not worth it).
    func start(onChange: @escaping () -> Void) {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { _, context in
            DeviceEnumerator.deliverChange(context)
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { _, context in
            DeviceEnumerator.deliverChange(context)
        }, context)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    /// Unscheduling the session is what stops the callbacks; the registrations
    /// die with the session itself, so there is no `DAUnregisterCallback` dance
    /// (which would need the callback back as a raw pointer).
    func stop() {
        guard let session else { return }
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.session = nil
        onChange = nil
    }

    /// The C callbacks land on the main run loop (that is where the session is
    /// scheduled), so the hop is an assertion rather than a dispatch.
    nonisolated private static func deliverChange(_ context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        let enumerator = Unmanaged<DeviceEnumerator>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { enumerator.onChange?() }
    }

    // MARK: - Enumeration

    /// Every external, removable, USB whole disk currently attached — the
    /// candidate list for registration (PRD F28) and the source of truth the
    /// flash pipeline re-checks against.
    ///
    /// `nonisolated`: enumeration reads the IOKit/DiskArbitration registries and
    /// touches none of this object's state, so the flash pipeline can re-check
    /// its device from inside its actor without hopping to the main actor.
    nonisolated func devices() -> [FlashDevice] {
        allWholeDisks().filter(\.isEligibleForRegistration)
    }

    /// Unfiltered: used by the flash pipeline, which must be able to *see* an
    /// ineligible device in order to refuse it with the specific reason.
    nonisolated func allWholeDisks() -> [FlashDevice] {
        // A fresh session rather than the callback one: this runs off the main
        // actor and a `DASession` is cheap to create.
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        let boot = Self.bootDiskNames(session: session)
        let volumes = Self.mountedVolumesByWholeDisk()
        return Self.wholeDiskBSDNames().compactMap { bsdName in
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
                  let description = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
            return Self.makeDevice(bsdName: bsdName,
                                   description: description,
                                   hardwareID: Self.hardwareID(bsdName: bsdName),
                                   bootDiskNames: boot,
                                   volumes: volumes[bsdName] ?? [])
        }
        .sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
    }

    /// The device a registered flashed drive is currently attached at, matched
    /// by hardware identity (PRD F27) — BSD names are reassigned freely, so the
    /// stored `lastBSDName` is never trusted as identity.
    nonisolated func device(matching drive: ManagedDrive, in devices: [FlashDevice]) -> FlashDevice? {
        Self.device(matching: drive, in: devices)
    }

    nonisolated static func device(matching drive: ManagedDrive, in devices: [FlashDevice]) -> FlashDevice? {
        guard let hardware = drive.hardwareID else { return nil }
        return devices.first { candidate in
            guard let candidateID = candidate.hardwareID else { return false }
            return hardware.matches(candidateID,
                                    sizeBytes: drive.capacityBytes,
                                    candidateSizeBytes: candidate.sizeBytes)
        }
    }

    /// Fresh description of one device, for the flash-time gate re-check.
    nonisolated func description(forBSDName bsdName: String) -> FlashDeviceDescription? {
        allWholeDisks().first { $0.bsdName == bsdName }?.gateDescription()
    }

    // MARK: - Parsing (pure, unit-tested)

    nonisolated static func rawDevicePath(bsdName: String) -> String {
        "/dev/r\(bsdName.hasPrefix("r") ? String(bsdName.dropFirst()) : bsdName)"
    }

    /// "/dev/disk4s1" → "disk4"; "/dev/rdisk4s1s2" → "disk4"; "disk4" → "disk4".
    /// Anything that is not a `disk…` node (a network mount, a synthesised
    /// path) returns nil rather than a guess.
    nonisolated static func wholeDiskName(forDeviceNode node: String) -> String? {
        var name = node
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if name.hasPrefix("r") { name = String(name.dropFirst()) }
        guard name.hasPrefix("disk") else { return nil }
        let digits = name.dropFirst(4).prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return "disk\(digits)"
    }

    /// Vendor and model come back space-padded from DiskArbitration, and either
    /// may be blank on a no-name stick.
    nonisolated static func displayName(vendor: String?, model: String?, bsdName: String) -> String {
        let parts = [vendor, model]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? bsdName : parts.joined(separator: " ")
    }

    /// Builds a `FlashDevice` from a DiskArbitration description dictionary.
    /// Split out from the CoreFoundation plumbing so a test can hand it a
    /// dictionary and assert the result.
    nonisolated static func makeDevice(bsdName: String, description: [String: Any],
                           hardwareID: HardwareID?, bootDiskNames: Set<String>,
                           volumes: [MountedVolume]) -> FlashDevice {
        let vendor = description[kDADiskDescriptionDeviceVendorKey as String] as? String
        let model = description[kDADiskDescriptionDeviceModelKey as String] as? String
        let removable = (description[kDADiskDescriptionMediaRemovableKey as String] as? Bool) ?? false
        let ejectable = (description[kDADiskDescriptionMediaEjectableKey as String] as? Bool) ?? false
        let internalDevice = (description[kDADiskDescriptionDeviceInternalKey as String] as? Bool) ?? true
        let protocolName = (description[kDADiskDescriptionDeviceProtocolKey as String] as? String) ?? ""
        let size = (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0
        let whole = (description[kDADiskDescriptionMediaWholeKey as String] as? Bool) ?? false
        return FlashDevice(bsdName: bsdName,
                           displayName: displayName(vendor: vendor, model: model, bsdName: bsdName),
                           sizeBytes: size,
                           isWholeDisk: whole,
                           isExternal: !internalDevice,
                           isRemovableOrEjectable: removable || ejectable,
                           isUSB: protocolName.caseInsensitiveCompare("USB") == .orderedSame,
                           isBootDisk: bootDiskNames.contains(bsdName),
                           hardwareID: hardwareID,
                           volumeNames: volumes.compactMap(\.name),
                           volumeUUIDs: volumes.compactMap(\.uuid),
                           volumeMountPoints: volumes.compactMap(\.url))
    }

    /// A volume currently mounted from some whole disk.
    struct MountedVolume: Hashable, Sendable {
        var name: String?
        var uuid: String?
        var deviceNode: String
        /// Mount point, for the PRD F44 content probe. Defaulted so the existing
        /// callers and their tests keep reading as before.
        var url: URL?
    }

    /// Groups the mounted volumes by the whole disk backing them, so the picker
    /// can show "32 GB · UBUNTU 24.04".
    nonisolated static func groupByWholeDisk(_ volumes: [MountedVolume]) -> [String: [MountedVolume]] {
        Dictionary(grouping: volumes) { wholeDiskName(forDeviceNode: $0.deviceNode) ?? "" }
            .filter { !$0.key.isEmpty }
    }

    // MARK: - CoreFoundation / IOKit plumbing

    nonisolated private static func mountedVolumesByWholeDisk() -> [String: [MountedVolume]] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeUUIDStringKey],
            options: []) ?? []
        let volumes = urls.compactMap { url -> MountedVolume? in
            guard let node = deviceNode(forVolumeAt: url) else { return nil }
            let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeUUIDStringKey])
            return MountedVolume(name: values?.volumeName, uuid: values?.volumeUUIDString,
                                 deviceNode: node, url: url)
        }
        return groupByWholeDisk(volumes)
    }

    /// `statfs.f_mntfromname`, e.g. "/dev/disk4s1".
    nonisolated static func deviceNode(forVolumeAt url: URL) -> String? {
        var buffer = statfs()
        guard statfs(url.path, &buffer) == 0 else { return nil }
        return withUnsafePointer(to: buffer.f_mntfromname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// The whole disk (or disks) macOS itself is running from — never flashable.
    ///
    /// Resolved through DiskArbitration from the boot volume's path, so a
    /// synthesised APFS volume maps to its container's whole disk; the data
    /// volume is included because it is a separate volume in the same container.
    /// "Internal" is *also* gated on separately: neither check is trusted alone.
    nonisolated static func bootDiskNames(session: DASession) -> Set<String> {
        var names: Set<String> = []
        for path in ["/", "/System/Volumes/Data"] {
            let url = URL(fileURLWithPath: path, isDirectory: true) as CFURL
            if let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url) {
                if let whole = DADiskCopyWholeDisk(disk), let name = DADiskGetBSDName(whole) {
                    names.insert(String(cString: name))
                } else if let name = DADiskGetBSDName(disk),
                          let derived = wholeDiskName(forDeviceNode: String(cString: name)) {
                    names.insert(derived)
                }
            }
            // Belt and braces: the same answer via statfs, in case DA declines.
            if let node = deviceNode(forVolumeAt: URL(fileURLWithPath: path)),
               let derived = wholeDiskName(forDeviceNode: node) {
                names.insert(derived)
            }
        }
        return names
    }

    /// Whole-disk BSD names from the IOKit media registry ("disk0", "disk4", …).
    nonisolated private static func wholeDiskBSDNames() -> [String] {
        guard let matching = IOServiceMatching(kIOMediaClass) as NSMutableDictionary? else { return [] }
        matching[kIOMediaWholeKey] = true
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var names: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let name = IORegistryEntryCreateCFProperty(service, kIOBSDNameKey as CFString,
                                                             kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { continue }
            names.append(name)
        }
        return names
    }

    /// USB vendor/product/serial for the media's parent device (PRD F27).
    /// `kIORegistryIterateParents` walks up the service plane until it finds the
    /// USB device that owns this media, so no assumption about tree depth.
    nonisolated static func hardwareID(bsdName: String) -> HardwareID? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let vendor = parentProperty(service, "idVendor") as? NSNumber,
              let product = parentProperty(service, "idProduct") as? NSNumber else { return nil }
        return HardwareID(vendorID: vendor.intValue,
                          productID: product.intValue,
                          serialNumber: parentProperty(service, "USB Serial Number") as? String,
                          vendorName: parentProperty(service, "USB Vendor Name") as? String,
                          productName: parentProperty(service, "USB Product Name") as? String)
    }

    nonisolated private static func parentProperty(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }
}
