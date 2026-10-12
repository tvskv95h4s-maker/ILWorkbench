import Darwin
import Foundation

enum HelperError: LocalizedError {
    case helperNotFound
    case dotnetNotFound
    case launchFailed(String)
    case processDied
    case rpc(String)
    case notOpen

    var errorDescription: String? {
        switch self {
        case .helperNotFound:
            return "找不到 ILWorkbench.Helper（先运行 Scripts/build-helper.sh，或设置环境变量 ILWORKBENCH_HELPER）"
        case .dotnetNotFound:
            return "找不到 dotnet 运行时，请安装 .NET 7 SDK/运行时"
        case .launchFailed(let message):
            return "助手进程启动失败：\(message)"
        case .processDied:
            return "与助手进程的连接已断开"
        case .rpc(let message):
            return "助手返回错误：\(message)"
        case .notOpen:
            return "尚未打开程序集"
        }
    }
}

/// Locates the bundled .NET helper, falling back to the development build output.
enum HelperLocator {
    static func locate() throws -> (URL, [String]) {
        let fileManager = FileManager.default

        if let resources = Bundle.main.resourceURL {
            let helperRoot = resources.appendingPathComponent("helper", isDirectory: true)
            // Self-contained payloads are shipped per architecture; prefer the native one.
            for name in bundledDirectoryNames() {
                let directory = helperRoot.appendingPathComponent(name, isDirectory: true)
                if let found = try? command(inDirectory: directory, fileManager: fileManager) {
                    return found
                }
            }
            // Legacy/flat layout (framework dependent build).
            if let found = try? command(inDirectory: helperRoot, fileManager: fileManager) {
                return found
            }
        }

        // Development override: point ILWORKBENCH_HELPER at a helper binary or the built .dll.
        if let override = ProcessInfo.processInfo.environment["ILWORKBENCH_HELPER"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if fileManager.fileExists(atPath: url.path) { return try command(forFile: url) }
        }

        // Last resort for running the binary outside a bundle: look relative to the working directory.
        for candidate in relativeCandidates() where fileManager.fileExists(atPath: candidate.path) {
            return try command(forFile: candidate)
        }

        throw HelperError.helperNotFound
    }

    /// Bundled payload directories, most appropriate first: the running architecture,
    /// then the other one (useful under Rosetta), then the architecture-neutral fallbacks.
    private static func bundledDirectoryNames() -> [String] {
        var machine = utsname()
        uname(&machine)
        let architecture = withUnsafeBytes(of: &machine.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return architecture == "x86_64" ? ["x64", "arm64"] : ["arm64", "x64"]
    }

    private static func relativeCandidates() -> [URL] {
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return [
            workingDirectory.appendingPathComponent("Helper/bin/Release/net7.0/ILWorkbench.Helper"),
            workingDirectory.appendingPathComponent("Helper/bin/Release/net7.0/ILWorkbench.Helper.dll"),
            workingDirectory.appendingPathComponent("Helper/bin/Debug/net7.0/ILWorkbench.Helper.dll")
        ]
    }

    private static func command(inDirectory directory: URL, fileManager: FileManager) throws -> (URL, [String]) {
        let executable = directory.appendingPathComponent("ILWorkbench.Helper")
        if fileManager.fileExists(atPath: executable.path) { return try command(forFile: executable) }
        let dll = directory.appendingPathComponent("ILWorkbench.Helper.dll")
        if fileManager.fileExists(atPath: dll.path) { return try command(forFile: dll) }
        throw HelperError.helperNotFound
    }

    private static func command(forFile url: URL) throws -> (URL, [String]) {
        url.pathExtension.lowercased() == "dll" ? (try dotnet(), [url.path]) : (url, [])
    }

    private static func dotnet() throws -> URL {
        let candidates = [
            "/usr/local/share/dotnet/dotnet",
            "/opt/homebrew/bin/dotnet",
            "/usr/local/bin/dotnet",
            "/usr/bin/dotnet"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw HelperError.dotnetNotFound
    }
}

/// Drives the .NET helper over a loopback TCP connection, speaking one JSON object per line.
///
/// A dedicated reader thread demultiplexes responses by request id, so `cancel` can be sent while a
/// long request is still running (a serialized queue would deliver it only after the request it is
/// supposed to abort).
final class HelperClient {
    private let writeQueue = DispatchQueue(label: "io.github.ilworkbench.helper.write")
    private let stateLock = NSLock()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var process: Process?
    private var socketFD: Int32 = -1
    private var handshakePath: String?
    private var nextID = 1
    private var readerStarted = false
    private var buffer = Data()

    private struct Envelope<T: Decodable>: Decodable {
        let id: Int
        let ok: Bool
        let error: String?
        let data: T?
    }

    deinit {
        if socketFD >= 0 { close(socketFD) }
    }

    // MARK: - requests

    func call<T: Decodable>(_ cmd: String, _ params: [String: Any] = [:], as type: T.Type) async throws -> T {
        let payload = try await perform(cmd, params)
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: payload)
        if envelope.ok, let data = envelope.data {
            return data
        }
        throw HelperError.rpc(envelope.error ?? "未知错误")
    }

    /// Aborts whatever the helper is currently computing. Fire and forget: the answer is dropped,
    /// the caller only cares that the in-flight request stops.
    func cancelInFlight() {
        guard socketFD >= 0 else { return }
        guard let id = allocateID(), let line = try? encode("cancel", [:], id: id) else { return }
        try? write(line)
    }

    func shutdown() {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        process?.terminate()
        process = nil
        if let path = handshakePath {
            try? FileManager.default.removeItem(atPath: path)
            handshakePath = nil
        }
    }

    // MARK: - internals

    private func perform(_ cmd: String, _ params: [String: Any]) async throws -> Data {
        try startIfNeeded()
        guard let id = allocateID() else { throw HelperError.launchFailed("请求编号耗尽") }
        let line = try encode(cmd, params, id: id)

        return try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            pending[id] = continuation
            stateLock.unlock()
            do {
                try write(line)
            } catch {
                stateLock.lock()
                let stored = pending.removeValue(forKey: id)
                stateLock.unlock()
                stored?.resume(throwing: error)
            }
        }
    }

    private func allocateID() -> Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        nextID += 1
        return nextID
    }

    private func encode(_ cmd: String, _ params: [String: Any], id: Int) throws -> Data {
        var payload = params
        payload["cmd"] = cmd
        payload["id"] = id
        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(0x0A)
        return line
    }

    private func write(_ data: Data) throws {
        try writeQueue.sync {
            guard socketFD >= 0 else { throw HelperError.processDied }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    guard let base = raw.baseAddress else { throw HelperError.processDied }
                    let written = Darwin.write(socketFD, base.advanced(by: offset), raw.count - offset)
                    if written <= 0 { throw HelperError.processDied }
                    offset += written
                }
            }
        }
    }

    private func startIfNeeded() throws {
        if socketFD >= 0 { return }

        let (executable, baseArguments) = try HelperLocator.locate()
        let identifier = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))"
        let handshake = NSTemporaryDirectory() + "ilworkbench-\(identifier).json"
        let logPath = NSTemporaryDirectory() + "ilworkbench-\(identifier).log"

        let task = Process()
        task.executableURL = executable
        task.arguments = baseArguments + ["--listen", handshake]
        task.standardInput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: logPath, contents: nil)
        if let logHandle = FileHandle(forWritingAtPath: logPath) {
            task.standardOutput = logHandle
            task.standardError = logHandle
        }

        do {
            try task.run()
        } catch {
            throw HelperError.launchFailed(error.localizedDescription)
        }
        process = task

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let data = FileManager.default.contents(atPath: handshake),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let port = object["port"] as? Int {
                try connect(port: UInt16(port))
                handshakePath = handshake
                startReader()
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        task.terminate()
        process = nil
        throw HelperError.launchFailed("助手进程未在 20 秒内就绪")
    }

    private func connect(port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperError.launchFailed("socket() 失败：errno \(errno)") }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw HelperError.launchFailed("连接 127.0.0.1:\(port) 失败：errno \(code)")
        }

        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        socketFD = fd
    }

    private func startReader() {
        stateLock.lock()
        let alreadyStarted = readerStarted
        readerStarted = true
        stateLock.unlock()
        guard !alreadyStarted else { return }

        Thread.detachNewThread { [weak self] in
            self?.readLoop()
        }
    }

    /// Reads responses and resumes the matching continuation; ids nobody waits for (cancel) are dropped.
    private func readLoop() {
        var local = Data()
        while true {
            if let newline = local.firstIndex(of: 0x0A) {
                let line = local[local.startIndex..<newline]
                local.removeSubrange(local.startIndex...newline)
                if !line.isEmpty { dispatch(Data(line)) }
                continue
            }

            guard socketFD >= 0 else { break }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(socketFD, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            local.append(contentsOf: chunk[0..<count])
        }

        // The helper went away: fail everything still waiting.
        stateLock.lock()
        let waiting = pending
        pending.removeAll()
        stateLock.unlock()
        for (_, continuation) in waiting {
            continuation.resume(throwing: HelperError.processDied)
        }
    }

    private func dispatch(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? Int else { return }

        stateLock.lock()
        let continuation = pending.removeValue(forKey: id)
        stateLock.unlock()
        continuation?.resume(returning: line)
    }
}
