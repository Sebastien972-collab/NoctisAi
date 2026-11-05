//
//  EmbeddedSearXNGService.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 05/11/2026.
//

#if os(macOS)
import Foundation
import Darwin

public enum EmbeddedSearXNGError: Error, LocalizedError, Equatable {
    case invalidConfiguration, runtimeUnavailable, startupFailed(Int32), startupTimedOut, busy

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: String(localized: "error.searxng.invalid_configuration", defaultValue: "Configuration du runtime SearXNG invalide.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .runtimeUnavailable: String(localized: "error.searxng.runtime_unavailable", defaultValue: "Runtime Python SearXNG absent ou non exécutable.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .startupFailed(let code): String(localized: "error.searxng.startup_failed", defaultValue: "Le processus SearXNG a échoué (code \(code)). Vérifiez le runtime et ses dépendances.", bundle: .module, comment: "Le nombre est le code de sortie du processus, pas une quantité.")
        case .startupTimedOut: String(localized: "error.searxng.startup_timeout", defaultValue: "Le démarrage de SearXNG a dépassé le délai autorisé.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        case .busy: String(localized: "error.searxng.busy", defaultValue: "Une recherche SearXNG ou son arrêt est déjà en cours.", bundle: .module, comment: "Description d’une erreur affichée à l’utilisateur.")
        }
    }
}

/// One lazy local worker. Keep this instance for the lifetime of the app's search session.
public actor EmbeddedSearXNGService: WebSearchService {
    private let pythonExecutable: URL
    private let idleTimeout: Duration
    private let startupTimeout: Duration
    private let launchScript: String
    private var process: Process?
    private var parentPipe: Pipe?
    private var directory: URL?
    private var endpoint: URL?
    private var token: String?
    private var operation: Task<[SearchResult], any Error>?
    private var idleTask: Task<Void, Never>?
    private var stopping = false

    public init(pythonExecutable: URL, idleTimeout: Duration = .seconds(120),
                startupTimeout: Duration = .seconds(45)) throws {
        try self.init(pythonExecutable: pythonExecutable, idleTimeout: idleTimeout,
                      startupTimeout: startupTimeout, launchScript: Self.bootstrap)
    }

    init(pythonExecutable: URL, idleTimeout: Duration, startupTimeout: Duration,
         launchScript: String) throws {
        guard pythonExecutable.isFileURL, pythonExecutable.path.hasPrefix("/"),
              idleTimeout > .zero, idleTimeout <= .seconds(3_600),
              startupTimeout > .zero, startupTimeout <= .seconds(120) else {
            throw EmbeddedSearXNGError.invalidConfiguration
        }
        self.pythonExecutable = pythonExecutable
        self.idleTimeout = idleTimeout
        self.startupTimeout = startupTimeout
        self.launchScript = launchScript
    }

    /// A relocatable Python distribution, with SearXNG installed, supplied by the host app.
    public static func bundled(in bundle: Bundle = .main) throws -> EmbeddedSearXNGService? {
        guard bundle.bundleURL.pathExtension == "app" else { return nil }
        let runtime = bundle.bundleURL.appendingPathComponent("Contents/Helpers/SearXNG/python/bin/python3")
        guard FileManager.default.fileExists(atPath: runtime.path) else { return nil }
        return try EmbeddedSearXNGService(pythonExecutable: runtime)
    }

    /// Development runtime installed once by infrastructure/searxng/setup_runtime.py.
    public static func installed(in applicationSupportDirectory: URL? = nil) throws -> EmbeddedSearXNGService? {
        let support = try applicationSupportDirectory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let python = support.appendingPathComponent("Noctis/SearXNG/venv/bin/python")
        guard FileManager.default.fileExists(atPath: python.path) else { return nil }
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw EmbeddedSearXNGError.runtimeUnavailable
        }
        return try EmbeddedSearXNGService(pythonExecutable: python)
    }

    public func search(query: String) async throws -> [SearchResult] {
        try Task.checkCancellation()
        try SearXNGService.validate(query: query)
        guard operation == nil, !stopping else { throw EmbeddedSearXNGError.busy }
        idleTask?.cancel()
        let task = Task { try await self.performSearch(query: query) }
        operation = task
        defer {
            operation = nil
            if !stopping { scheduleIdleStop() }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Call from the host's application termination hook before allowing it to quit.
    public func shutdown() async {
        guard !stopping else { return }
        stopping = true
        idleTask?.cancel()
        idleTask = nil
        let active = operation
        active?.cancel()
        _ = try? await active?.value
        await stopProcess()
        stopping = false
    }

    private func performSearch(query: String) async throws -> [SearchResult] {
        do {
            try await startIfNeeded()
            try Task.checkCancellation()
            guard let endpoint, let token else { throw EmbeddedSearXNGError.runtimeUnavailable }
            return try await SearXNGService(baseURL: endpoint, token: token).search(query: query)
        } catch {
            // Discard a failed/cancelled worker; the next search can start a clean one.
            await stopProcess()
            throw error
        }
    }

    private func scheduleIdleStop() {
        idleTask?.cancel()
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() async {
        guard operation == nil, !stopping else { return }
        stopping = true
        await stopProcess()
        stopping = false
    }

    private func startIfNeeded() async throws {
        if process?.isRunning == true, endpoint != nil { return }
        await stopProcess()
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: pythonExecutable.path) else {
            throw EmbeddedSearXNGError.runtimeUnavailable
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctis-searxng-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        directory = root
        let secret = UUID().uuidString + UUID().uuidString
        let settings = """
        use_default_settings: true
        general:
          debug: false
          enable_metrics: false
        server:
          secret_key: "\(secret)"
          bind_address: "127.0.0.1"
          limiter: false
          public_instance: false
          image_proxy: false
        search:
          formats: [json]
        outgoing:
          request_timeout: 5.0
          max_request_timeout: 10.0
        """
        try Data(settings.utf8).write(to: root.appendingPathComponent("settings.yml"))
        let authentication = UUID().uuidString + UUID().uuidString
        let child = Process()
        child.executableURL = pythonExecutable
        child.arguments = ["-I", "-B", "-u", "-c", launchScript]
        // No inherited PYTHONPATH, proxy, SEARXNG_*, shell or user-site configuration.
        child.environment = [
            "PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path,
            "XDG_CACHE_HOME": root.path, "XDG_CONFIG_HOME": root.path,
            "SEARXNG_SETTINGS_PATH": root.appendingPathComponent("settings.yml").path,
            "NOCTIS_READY_PATH": root.appendingPathComponent("ready.json").path,
            "NOCTIS_TOKEN": authentication
        ]
        child.currentDirectoryURL = root
        let pipe = Pipe()
        child.standardInput = pipe
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        process = child
        parentPipe = pipe
        do { try child.run() } catch { throw EmbeddedSearXNGError.runtimeUnavailable }
        // Only the child owns the read end; EOF then detects parent death, including crashes.
        try? pipe.fileHandleForReading.close()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: startupTimeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            guard child.isRunning else { throw EmbeddedSearXNGError.startupFailed(child.terminationStatus) }
            let ready = root.appendingPathComponent("ready.json")
            if let data = try? Data(contentsOf: ready), data.count < 1_024,
               let port = try? JSONDecoder().decode(UInt16.self, from: data), port > 0,
               let url = URL(string: "http://127.0.0.1:\(port)") {
                let client = BoundedHTTPClient(limits: try HTTPResponseLimits(maximumBytes: 1_024,
                                                                            requestTimeout: 1, resourceTimeout: 2))
                let (body, _) = try await client.get(url.appendingPathComponent("healthz"),
                                                    mimeTypes: ["application/json"],
                                                    headers: ["X-Noctis-Token": authentication])
                guard body == Data("{\"ready\":true}".utf8), child.isRunning else {
                    throw EmbeddedSearXNGError.startupFailed(-1)
                }
                endpoint = url
                token = authentication
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw EmbeddedSearXNGError.startupTimedOut
    }

    private func stopProcess() async {
        endpoint = nil
        token = nil
        let child = process
        process = nil
        try? parentPipe?.fileHandleForWriting.close()
        parentPipe = nil
        if let child, child.isRunning {
            child.terminate()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
            while child.isRunning, ContinuousClock.now < deadline {
                // Cleanup must complete even when the caller is cancelled.
                await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            // Process reaps its child asynchronously; do not block the actor waiting on it.
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    deinit {
        idleTask?.cancel()
        operation?.cancel()
        try? parentPipe?.fileHandleForWriting.close()
        if process?.isRunning == true { process?.terminate() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // Bind port 0 in the serving process: no free-port probe race and no worker/reloader.
    // stdin is a lifetime pipe, not a command channel. No queries or tokens reach logs.
    static let bootstrap = #"""
    import hmac, json, os, sys, threading
    def parent_watch():
        sys.stdin.buffer.read()
        os._exit(0)
    threading.Thread(target=parent_watch, daemon=True).start()
    from searx.webapp import app
    from werkzeug.serving import make_server, WSGIRequestHandler
    token = os.environ.pop("NOCTIS_TOKEN")
    class QuietHandler(WSGIRequestHandler):
        def log(self, *args, **kwargs):
            pass
    def application(environ, start_response):
        if (environ.get("REQUEST_METHOD") != "GET"
            or environ.get("HTTP_ORIGIN")
            or not hmac.compare_digest(environ.get("HTTP_X_NOCTIS_TOKEN", ""), token)):
            start_response("403 Forbidden", [("Content-Type", "application/json")])
            return [b'{}']
        path = environ.get("PATH_INFO")
        if path == "/healthz":
            start_response("200 OK", [("Content-Type", "application/json")])
            return [b'{"ready":true}']
        if path != "/search":
            start_response("404 Not Found", [("Content-Type", "application/json")])
            return [b'{}']
        # Ignore forwarded host/IP headers; this is a direct loopback connection.
        for key in list(environ):
            if key.startswith("HTTP_X_FORWARDED_") or key == "HTTP_FORWARDED":
                del environ[key]
        return app(environ, start_response)
    server = make_server("127.0.0.1", 0, application, threaded=False,
                         request_handler=QuietHandler)
    ready = os.environ["NOCTIS_READY_PATH"]
    with open(ready + ".tmp", "w") as stream:
        json.dump(server.server_port, stream)
    os.replace(ready + ".tmp", ready)
    server.serve_forever()
    """#
}
#endif
