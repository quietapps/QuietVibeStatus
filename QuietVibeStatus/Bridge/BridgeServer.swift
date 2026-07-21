import Darwin
import Foundation

/// Unix-domain socket server that agent hooks talk to.
///
/// One connection per hook invocation: read a line, route it, write a line, close. Connections for
/// blocking events (permission requests, questions) stay open while the user decides, which is
/// exactly what makes the agent wait for the notch instead of its own terminal prompt.
final class BridgeServer {
    static let shared = BridgeServer()

    /// `~/.quietvibestatus`
    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".quietvibestatus")
    }

    static var socketPath: String {
        supportDirectory.appendingPathComponent("run/bridge.sock").path
    }

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "app.quiet.qvs.bridge", attributes: .concurrent)

    private init() {}

    // MARK: - Lifecycle

    func start() {
        stop()

        let path = Self.socketPath
        try? FileManager.default.createDirectory(
            at: Self.supportDirectory.appendingPathComponent("run"),
            withIntermediateDirectories: true
        )
        // A socket file left behind by a crash would make bind() fail with EADDRINUSE.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Log.bridge.error("socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxPathLength else {
            Log.bridge.error("socket path too long: \(path)")
            close(fd)
            return
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            path.withCString { cString in
                strncpy(
                    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                    cString,
                    maxPathLength - 1
                )
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Log.bridge.error("bind() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        // Only this user may talk to the app.
        chmod(path, 0o600)

        guard listen(fd, 128) == 0 else {
            Log.bridge.error("listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source

        Log.bridge.info("listening on \(path)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            listenFD = -1
        }
        unlink(Self.socketPath)
        Task { @MainActor in PendingRequestRegistry.shared.cancelAll() }
    }

    // MARK: - Connections

    private func acceptConnection() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }

        queue.async { [weak self] in
            self?.handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }

        guard let line = readLine(from: clientFD), !line.isEmpty else { return }
        guard let data = line.data(using: .utf8) else { return }

        let envelope: HookEnvelope
        do {
            envelope = try JSONDecoder().decode(HookEnvelope.self, from: data)
        } catch {
            Log.bridge.error("undecodable envelope: \(error.localizedDescription)")
            return
        }

        // Bridge back into structured concurrency, then block this worker thread until the router
        // answers. Blocking is intended here: the connection *is* the agent's wait.
        let semaphore = DispatchSemaphore(value: 0)
        var response = "{}"

        Task {
            response = await HookRouter.shared.handle(envelope)
            semaphore.signal()
        }
        semaphore.wait()

        write(response + "\n", to: clientFD)
    }

    /// Reads bytes until the first newline. Hook payloads are always one line (the bridge script
    /// flattens them), so this never needs to handle framing beyond that.
    private func readLine(from fd: Int32) -> String? {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            if let newlineIndex = chunk[0 ..< count].firstIndex(of: 0x0A) {
                buffer.append(contentsOf: chunk[0 ..< newlineIndex])
                break
            }
            buffer.append(contentsOf: chunk[0 ..< count])
            // Guard against a runaway payload rather than growing without bound.
            if buffer.count > 8 * 1024 * 1024 { break }
        }

        guard !buffer.isEmpty else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    private func write(_ string: String, to fd: Int32) {
        let bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { pointer in
                Darwin.write(fd, pointer.baseAddress! + offset, bytes.count - offset)
            }
            if written <= 0 { break }
            offset += written
        }
    }
}
