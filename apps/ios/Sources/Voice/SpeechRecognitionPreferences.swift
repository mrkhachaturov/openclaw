import Foundation

enum SpeechRecognitionProviderKind: String, CaseIterable {
    case apple = "apple"
    case parakeet = "parakeet"
}

enum SpeechRecognitionPreferences {
    private static let providerKey = "speechRecognitionProvider"
    private static let parakeetModelKey = "parakeetActiveModel"

    static var activeProvider: SpeechRecognitionProviderKind {
        get {
            guard let raw = UserDefaults.standard.string(forKey: providerKey),
                  let kind = SpeechRecognitionProviderKind(rawValue: raw)
            else { return .apple }
            return kind
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }

    static var activeParakeetModel: String {
        get { UserDefaults.standard.string(forKey: parakeetModelKey) ?? "parakeet-v3" }
        set { UserDefaults.standard.set(newValue, forKey: parakeetModelKey) }
    }
}
