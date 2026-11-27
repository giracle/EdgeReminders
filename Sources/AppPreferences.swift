import Combine
import Foundation

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    @Published var theme: String {
        didSet { defaults.set(theme, forKey: Keys.theme) }
    }
    @Published var panelOpacity: Double {
        didSet { defaults.set(panelOpacity, forKey: Keys.opacity) }
    }
    @Published var completionSound: String {
        didSet { defaults.set(completionSound, forKey: Keys.sound) }
    }
    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }
    @Published var celebrationEnabled: Bool {
        didSet { defaults.set(celebrationEnabled, forKey: Keys.celebration) }
    }
    @Published var rainbowHairline: Bool {
        didSet { defaults.set(rainbowHairline, forKey: Keys.rainbow) }
    }
    @Published var clipboardAutoCapture: Bool {
        didSet { defaults.set(clipboardAutoCapture, forKey: Keys.clipboard) }
    }
    @Published var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: Keys.autoUpdate) }
    }

    private enum Keys {
        static let theme = "app.theme"
        static let opacity = "app.panelOpacity"
        static let sound = "app.completionSound"
        static let soundEnabled = "app.soundEnabled"
        static let celebration = "app.celebration"
        static let rainbow = "app.rainbowHairline"
        static let clipboard = "app.clipboardAutoCapture"
        static let autoUpdate = "app.autoCheckUpdates"
    }

    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = defaults.string(forKey: Keys.theme) ?? AppTheme.fuguang.rawValue
        panelOpacity = defaults.object(forKey: Keys.opacity) as? Double ?? 1.0
        completionSound = defaults.string(forKey: Keys.sound) ?? "Pop"
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        celebrationEnabled = defaults.object(forKey: Keys.celebration) as? Bool ?? true
        rainbowHairline = defaults.object(forKey: Keys.rainbow) as? Bool ?? false
        clipboardAutoCapture = defaults.object(forKey: Keys.clipboard) as? Bool ?? false
        autoCheckUpdates = defaults.object(forKey: Keys.autoUpdate) as? Bool ?? true
    }

    var accentTheme: AppTheme {
        AppTheme(rawValue: theme) ?? .fuguang
    }
}
