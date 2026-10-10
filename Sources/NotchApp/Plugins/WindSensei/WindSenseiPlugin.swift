import Combine
import Foundation
import OSLog
import SwiftUI

let windSenseiLog = Logger(subsystem: "com.robin.notch", category: "windsensei")

/// Favourite kiting spots from a WindSensei account: the station's observed wind, today's
/// forecast strip and the next rideable block. Uses the account's API key against the same
/// widget endpoint WindSensei's own widgets read, refreshed every 15 minutes while a key is set
/// and when the notch opens on data older than five minutes.
@MainActor
final class WindSenseiPlugin: ObservableObject, NotchPlugin {
    let id = "windsensei"
    let title = "Wind"

    static let site = URL(string: "https://windsensei.com")!
    private static let keyFile = "windsensei-api-key"
    private static let refreshEvery: TimeInterval = 15 * 60
    private static let staleAfter: TimeInterval = 5 * 60

    @Published private(set) var apiKey: String?
    @Published private(set) var spots: [WindSenseiSpot] = []
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    var isConfigured: Bool { apiKey != nil }
    var changes: AnyPublisher<Void, Never> { objectWillChange.eraseToAnyPublisher() }
    var settingsView: AnyView { AnyView(WindSenseiSettingsView(plugin: self)) }
    var tabView: AnyView { AnyView(WindSenseiView(plugin: self)) }

    private var timer: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    init() {
        apiKey = SecretFile.read(Self.keyFile)
        if apiKey != nil { start() }
    }

    // MARK: Setup

    func connect(apiKey key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        SecretFile.write(key, as: Self.keyFile)
        apiKey = key
        spots = []
        fetchedAt = nil
        lastError = nil
        start()
    }

    func disconnect() {
        SecretFile.delete(Self.keyFile)
        timer?.cancel()
        timer = nil
        fetchTask?.cancel()
        fetchTask = nil
        apiKey = nil
        spots = []
        fetchedAt = nil
        lastError = nil
    }

    func notchOpened() {
        guard let fetchedAt else { return refresh() }
        if Date().timeIntervalSince(fetchedAt) > Self.staleAfter { refresh() }
    }

    func refresh() {
        guard apiKey != nil, fetchTask == nil else { return }
        isLoading = true
        fetchTask = Task { [weak self] in
            defer { self?.fetchTask = nil }
            await self?.fetch()
            self?.isLoading = false
        }
    }

    private func start() {
        refresh()
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshEvery))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    // MARK: Fetching

    private func fetch() async {
        guard let apiKey else { return }
        var request = URLRequest(url: Self.site.appending(path: "/api/v1/dashboard/widget").appending(queryItems: [URLQueryItem(name: "days", value: "2")]))
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                throw WindSenseiError.http(status)
            }
            let decoded = try JSONDecoder().decode(WindSenseiResponse.self, from: data)
            // WindSensei's contract for this endpoint: a response missing a favourite is partial
            // and must not replace a complete one, or a spot that merely failed upstream this
            // round reads as gone.
            if decoded.complete == false, !spots.isEmpty {
                windSenseiLog.notice("partial response, keeping \(self.spots.count) spots")
            } else {
                spots = decoded.spots
            }
            fetchedAt = Date()
            lastError = nil
            windSenseiLog.notice("\(decoded.spots.count) spots")
        } catch {
            lastError = error.localizedDescription
            windSenseiLog.error("fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum WindSenseiError: LocalizedError {
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .http(401): return "WindSensei rejected the API key."
        case .http(let status): return "WindSensei answered HTTP \(status)."
        }
    }
}
