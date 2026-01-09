import Foundation

enum Env {
    static let keychainGroup = "KYH47R284B.to.bitkit"

    enum ExecutionContext {
        case foregroundApp
        case pushNotificationExtension

        var filenamePrefix: String {
            switch self {
            case .foregroundApp:
                return "app"
            case .pushNotificationExtension:
                return "ext"
            }
        }
    }

    static var currentExecutionContext: ExecutionContext {
        return .pushNotificationExtension
    }

    static var appStorageUrl: URL {
        if let groupContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.bitkit") {
            return groupContainer
        } else {
            guard let fallback = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                fatalError("Could not find documents directory")
            }
            return fallback
        }
    }

    static var logDirectory: String {
        return appStorageUrl.appendingPathComponent("logs").path
    }
}
