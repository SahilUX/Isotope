import Foundation
import IsotopeCore

/// PRD F43 addendum — reading the build out of the Windows media that is
/// actually on a drive.
///
/// Every other source names its version in the filename, so a scan already
/// knows what it found. Windows does not: `Win11_25H2_English_x64.iso` is the
/// name Microsoft gives every 25H2 image, refreshed media included. The build is
/// inside the file, and getting it means mounting a multi-gigabyte image — far
/// too slow to do inside a scan, and pointless to repeat.
///
/// So it runs after the scan, off the main actor, once per (assignment, file):
/// a file that has already been asked is not asked again, and a file that
/// declines to answer is not asked again either, until the file itself changes.
extension AppStore {
    /// Inspect any Windows media on this drive whose build is not yet known.
    /// Cheap and safe to call after every scan — almost every call finds
    /// nothing to do.
    func refreshWindowsBuilds(driveID: UUID) {
        guard let drive = drive(id: driveID), isConnected(drive) else { return }
        let pending = drive.assignments.compactMap { assignment -> (UUID, String)? in
            guard let installed = assignment.installed, installed.build == nil,
                  entry(id: assignment.entryID)?.kind == .windows,
                  !windowsBuildAttempts.contains(Self.attemptKey(assignment.id, installed.fileName))
            else { return nil }
            return (assignment.id, installed.fileName)
        }
        guard !pending.isEmpty else { return }

        let probe = driveProbe
        let bookmark = drive.bookmark
        let folder = drive.isoFolder
        for (assignmentID, fileName) in pending {
            windowsBuildAttempts.insert(Self.attemptKey(assignmentID, fileName))
            Task { [weak self] in
                // `windowsBuild` mounts the image: blocking, seconds long, and
                // nothing the UI should wait behind.
                let build = await Task.detached(priority: .utility) {
                    probe.windowsBuild(bookmark, folder, fileName)
                }.value
                guard let build else { return }
                await MainActor.run {
                    self?.recordWindowsBuild(build, forAssignment: assignmentID,
                                             on: driveID, fileName: fileName)
                }
            }
        }
    }

    /// Records a build against the assignment — but only while the file it was
    /// read from is still the one installed. A scan, an update or an unplug can
    /// all land between the mount and the answer, and stamping a build onto a
    /// file it did not come from is exactly the kind of quiet lie this app is
    /// built to avoid.
    func recordWindowsBuild(_ build: String, forAssignment assignmentID: UUID,
                            on driveID: UUID, fileName: String) {
        guard var drive = drive(id: driveID),
              let index = drive.assignments.firstIndex(where: { $0.id == assignmentID }),
              var installed = drive.assignments[index].installed,
              installed.fileName == fileName, installed.build != build
        else { return }
        installed.build = build
        drive.assignments[index].installed = installed
        updateDrive(drive)
    }

    /// Forget what was tried for one drive, so the next scan asks again. Used
    /// when the drive's contents have changed under us.
    func forgetWindowsBuildAttempts(on driveID: UUID) {
        guard let drive = drive(id: driveID) else { return }
        let ids = Set(drive.assignments.map(\.id))
        windowsBuildAttempts = windowsBuildAttempts.filter { key in
            !ids.contains { key.hasPrefix($0.uuidString) }
        }
    }

    static func attemptKey(_ assignmentID: UUID, _ fileName: String) -> String {
        "\(assignmentID.uuidString)\u{0}\(fileName)"
    }
}
