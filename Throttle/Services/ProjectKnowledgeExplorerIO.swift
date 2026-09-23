import Darwin
import Foundation

extension ProjectKnowledgeExplorer {
    struct DirectoryEntry {
        let path: String
        let isDirectory: Bool
    }

    /// Every component is opened relative to a pinned directory descriptor.
    /// Path checks alone do not protect against a concurrent symlink swap.
    func openRelative(_ path: String, directory: Bool) throws -> Int32 {
        guard !path.hasPrefix("/"), !path.hasPrefix("~"),
              path.rangeOfCharacter(from: .controlCharacters) == nil,
              !path.split(separator: "/").contains("..") else {
            throw ProjectKnowledgeError.invalidRequest
        }
        guard !Self.isSensitivePath(path) else { throw ProjectKnowledgeError.sensitivePathRefused }
        let components = path.split(separator: "/").filter { $0 != "." }.map(String.init)
        guard directory || !components.isEmpty else { throw ProjectKnowledgeError.invalidRequest }
        var pinned = stat()
        var current = stat()
        guard rootDescriptor >= 0, fstat(rootDescriptor, &pinned) == 0,
              lstat(root.path, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
              current.st_dev == pinned.st_dev, current.st_ino == pinned.st_ino else {
            throw ProjectKnowledgeError.unsafeFile
        }
        var descriptor = openat(rootDescriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProjectKnowledgeError.notDirectory }
        do {
            for (index, component) in components.enumerated() {
                let needsDirectory = directory || index < components.count - 1
                let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (needsDirectory ? O_DIRECTORY : 0)
                let next = openat(descriptor, component, flags)
                if next < 0 {
                    var info = stat()
                    if fstatat(descriptor, component, &info, AT_SYMLINK_NOFOLLOW) == 0,
                       info.st_mode & S_IFMT == S_IFLNK {
                        throw ProjectKnowledgeError.symlinkRefused
                    }
                    throw ProjectKnowledgeError.unsafeFile
                }
                Darwin.close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func readFile(
        _ relativePath: String,
        maximumBytes: Int = ProjectKnowledgeExplorer.maximumFileBytes
    ) throws -> ProjectKnowledgeFile {
        guard maximumBytes > 0 else { throw ProjectKnowledgeError.fileTooLarge }
        let limit = min(maximumBytes, Self.maximumFileBytes)
        let descriptor = try openRelative(relativePath, directory: false)
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw ProjectKnowledgeError.notRegularFile
        }
        // A second hard link may expose content owned outside the project.
        guard before.st_nlink == 1 else { throw ProjectKnowledgeError.unsafeFile }
        guard before.st_size <= limit else { throw ProjectKnowledgeError.fileTooLarge }
        let data = try boundedRead(descriptor, limit: limit)
        guard data.count <= limit else { throw ProjectKnowledgeError.fileTooLarge }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              data.count == after.st_size else { throw ProjectKnowledgeError.unsafeFile }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw ProjectKnowledgeError.binaryOrNonUTF8
        }
        return ProjectKnowledgeFile(url: root.appendingPathComponent(relativePath), data: data, text: text)
    }

    private func boundedRead(_ descriptor: Int32, limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= limit {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min($0.count, limit + 1 - data.count))
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ProjectKnowledgeError.unsafeFile
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    /// Budget counts all encountered names, including excluded/hidden entries.
    /// Sorting happens only after the bounded scan, not over a whole directory.
    func directoryEntries(_ path: String, remaining: inout Int) throws
        -> (values: [DirectoryEntry], truncated: Bool) {
        let descriptor = try openRelative(path, directory: true)
        guard let stream = fdopendir(descriptor) else {
            Darwin.close(descriptor)
            throw ProjectKnowledgeError.notDirectory
        }
        defer { closedir(stream) }
        var values: [DirectoryEntry] = []
        while remaining > 0 {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw ProjectKnowledgeError.unsafeFile }
                return (values.sorted { $0.path < $1.path }, false)
            }
            remaining -= 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard !name.hasPrefix("."), name.rangeOfCharacter(from: .controlCharacters) == nil else { continue }
            let relativePath = path.isEmpty || path == "." ? name : path + "/" + name
            guard !Self.isSensitivePath(relativePath) else { continue }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            guard type == S_IFDIR || (type == S_IFREG && info.st_nlink == 1) else { continue }
            values.append(DirectoryEntry(path: relativePath, isDirectory: type == S_IFDIR))
        }
        return (values.sorted { $0.path < $1.path }, true)
    }
}
