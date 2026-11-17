#if os(macOS)
import Foundation
import LocalAuthentication
import Observation
import OSLog
import Security
import WitermCore

/// The OpenAI API key, in the data protection Keychain on this Mac only,
/// and only after the user chooses to keep it there.
enum OrbitKeychain {
    private static let service = "com.witerm.orbit.v1"
    private static let account = "openai-api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) -> Bool {
        delete()
        var request = query
        request[kSecValueData as String] = Data(key.utf8)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(request as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Orbit for this window and Settings: starts `witerm orbit serve` from the
/// app's helpers when needed, gives it the key and model, and follows its
/// threads while someone is looking.
@MainActor @Observable
final class OrbitService {
    enum KeyState: Equatable {
        case none
        /// Given for this session only; gone when Witerm quits.
        case session
        /// Kept in the Keychain.
        case keychain
    }

    static let modelKey = "witerm.orbit.model"

    private(set) var threads: [OrbitThreadSummary] = []
    private(set) var detail: OrbitThreadDetail?
    private(set) var status: OrbitStatus?
    private(set) var available = false
    private(set) var keyState: KeyState = .none
    private(set) var sending = false
    /// Something the user should know: Orbit couldn't start, a request failed.
    private(set) var problem: String?
    var selectedID: String? {
        didSet { if selectedID != oldValue { detail = nil; Task { await refreshDetail() } } }
    }
    /// A new thread started from a terminal names it here.
    var draftTerminalID: String?
    var draftKind: OrbitThreadKind = .chat

    @ObservationIgnored private var key: String?
    @ObservationIgnored private var helper: Process?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.witerm.mac", category: "Orbit")

    init() {
        if let saved = OrbitKeychain.read() { key = saved; keyState = .keychain }
    }

    var model: String {
        get { UserDefaults.standard.string(forKey: Self.modelKey) ?? OrbitWire.defaultModel }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.modelKey)
            Task { await configure() }
        }
    }

    var runningCount: Int { threads.filter { $0.status == .running }.count }
    var waitingCount: Int { threads.filter { $0.status == .waiting }.count }

    private var client: OrbitClient? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "WitermAppGroup") as? String,
              let directory = try? OrbitPaths.directory(appGroupID: group) else { return nil }
        return OrbitClient(socketURL: directory.appendingPathComponent(OrbitPaths.socketName))
    }

    // MARK: Key

    /// `remember` keeps it in the Keychain; otherwise it lives in memory
    /// here and in Orbit until Witerm quits.
    func setKey(_ newKey: String, remember: Bool) async -> Bool {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if remember {
            guard OrbitKeychain.save(trimmed) else {
                problem = String(localized: "Couldn’t save the key in the Keychain.", bundle: .main)
                return false
            }
        } else {
            OrbitKeychain.delete()
        }
        key = trimmed
        keyState = remember ? .keychain : .session
        problem = nil
        await ensureRunning()
        await configure()
        return true
    }

    func removeKey() async {
        OrbitKeychain.delete()
        key = nil
        keyState = .none
        if let client { _ = try? await client.configure(apiKey: "", model: nil) }
        await refresh()
    }

    // MARK: Lifecycle

    /// While a view shows Orbit, it is kept running and followed.
    func watch() {
        watchers += 1
        guard polling == nil else { return }
        polling = Task { [weak self] in
            await self?.ensureRunning()
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { polling?.cancel(); polling = nil }
    }

    func ensureRunning() async {
        guard let client else { available = false; return }
        if (try? await client.status()) != nil { available = true; await configureIfNeeded(); return }
        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/witerm")
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            problem = String(localized: "Orbit is missing from this copy of Witerm. Reinstall Witerm.", bundle: .main)
            return
        }
        if helper?.isRunning != true {
            let process = Process()
            process.executableURL = helperURL
            process.arguments = ["orbit", "serve"]
            process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.helper = nil } }
            do { try process.run(); helper = process } catch {
                logger.error("Orbit didn't start: \((error as NSError).code)")
                problem = String(localized: "Orbit didn’t start. Try again.", bundle: .main)
                return
            }
        }
        for _ in 0..<30 {
            if (try? await client.status()) != nil {
                available = true
                problem = nil
                await configureIfNeeded()
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        available = false
        problem = String(localized: "Orbit didn’t start. Try again.", bundle: .main)
    }

    /// Orbit restarted, or the model changed: give it the key and model again.
    private func configureIfNeeded() async {
        guard let client, let current = try? await client.status() else { return }
        status = current
        if (key != nil && !current.hasKey) || current.model != model { await configure() }
    }

    private func configure() async {
        guard let client else { return }
        status = (try? await client.configure(apiKey: key, model: OrbitWire.validModel(model) ? model : nil)) ?? status
    }

    func refresh() async {
        guard let client else { return }
        do {
            let latest = try await client.threads()
            available = true
            if latest != threads { threads = latest }
            if let id = selectedID, let summary = latest.first(where: { $0.id == id }),
               summary.revision != detail?.summary.revision {
                await refreshDetail()
            } else if let id = selectedID, !latest.contains(where: { $0.id == id }) {
                selectedID = nil
            }
            let current = try await client.status()
            if current != status { status = current }
            if key != nil && !current.hasKey { await configure() }
        } catch OrbitClientError.unavailable {
            available = false
            if watchers > 0 { await ensureRunning() }
        } catch {
            available = false
        }
    }

    private func refreshDetail() async {
        guard let client, let id = selectedID else { return }
        if let latest = try? await client.thread(id), selectedID == id { detail = latest }
    }

    // MARK: Actions

    func start(_ text: String) async -> Bool {
        await act { client in
            let thread = try await client.start(text: text, kind: draftKind, terminalID: draftTerminalID)
            draftTerminalID = nil
            selectedID = thread.summary.id
            detail = thread
        }
    }

    func send(_ text: String) async -> Bool {
        guard let id = selectedID else { return false }
        return await act { client in detail = try await client.send(text, to: id) }
    }

    func stop() async {
        guard let id = selectedID else { return }
        _ = await act { client in detail = try await client.stop(id) }
    }

    func delete(_ id: String) async {
        _ = await act { client in
            try await client.delete(id)
            if selectedID == id { selectedID = nil }
        }
    }

    func clearAll() async {
        _ = await act { client in
            try await client.clear()
            selectedID = nil
        }
    }

    /// Starts a new conversation about a terminal, from its menu.
    func newThread(about terminalID: String?) {
        selectedID = nil
        draftTerminalID = terminalID
    }

    private func act(_ body: (OrbitClient) async throws -> Void) async -> Bool {
        await ensureRunning()
        guard let client else { return false }
        sending = true
        defer { sending = false }
        do {
            try await body(client)
            problem = nil
            await refresh()
            return true
        } catch {
            problem = String(localized: "Orbit didn’t answer. Try again.", bundle: .main)
            return false
        }
    }
}
#endif
