import Foundation
import Combine
import CodeScopeCore

/// User preferences. Everything except the API key lives in UserDefaults; the key is in the Keychain.
@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let model = "codescope.model"
        static let effort = "codescope.effort"
        static let fallbacks = "codescope.fallbacks"
        static let showThinking = "codescope.showThinking"
        static let tokenBudget = "codescope.tokenBudget"
        static let recentProjects = "codescope.recentProjects"
        static let apiKeyFallback = "codescope.apiKeyFallback"
    }

    @Published var apiKey: String {
        didSet {
            if !KeychainStore.write(apiKey) {
                // Keychain unavailable (e.g. unsigned debug build on some setups): fall back to defaults.
                defaults.set(apiKey, forKey: Keys.apiKeyFallback)
            } else {
                defaults.removeObject(forKey: Keys.apiKeyFallback)
            }
        }
    }

    @Published var model: String { didSet { defaults.set(model, forKey: Keys.model) } }
    @Published var effort: Effort { didSet { defaults.set(effort.rawValue, forKey: Keys.effort) } }
    @Published var enableFallbacks: Bool { didSet { defaults.set(enableFallbacks, forKey: Keys.fallbacks) } }
    @Published var showThinking: Bool { didSet { defaults.set(showThinking, forKey: Keys.showThinking) } }
    @Published var tokenBudget: Int { didSet { defaults.set(tokenBudget, forKey: Keys.tokenBudget) } }
    @Published var recentProjects: [String] { didSet { defaults.set(recentProjects, forKey: Keys.recentProjects) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedKey = KeychainStore.read() ?? defaults.string(forKey: Keys.apiKeyFallback) ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        _apiKey = Published(initialValue: storedKey)
        _model = Published(initialValue: defaults.string(forKey: Keys.model) ?? ClaudeModels.defaultModel)
        _effort = Published(initialValue: Effort(rawValue: defaults.string(forKey: Keys.effort) ?? "") ?? .high)
        _enableFallbacks = Published(initialValue: defaults.object(forKey: Keys.fallbacks) as? Bool ?? true)
        _showThinking = Published(initialValue: defaults.object(forKey: Keys.showThinking) as? Bool ?? true)
        let budget = defaults.integer(forKey: Keys.tokenBudget)
        _tokenBudget = Published(initialValue: budget == 0 ? ContextBuilder.defaultTokenBudget : budget)
        _recentProjects = Published(initialValue: defaults.stringArray(forKey: Keys.recentProjects) ?? [])
    }

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var clientConfiguration: ClaudeConfiguration {
        ClaudeConfiguration(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                            model: model,
                            effort: effort,
                            enableFallbacks: enableFallbacks,
                            showThinking: showThinking)
    }

    func noteRecentProject(_ path: String) {
        var list = recentProjects.filter { $0 != path }
        list.insert(path, at: 0)
        recentProjects = Array(list.prefix(8))
    }

    func removeRecentProject(_ path: String) {
        recentProjects.removeAll { $0 == path }
    }
}
