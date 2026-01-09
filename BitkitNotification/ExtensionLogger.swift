import Foundation
import os.log

class Logger {
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "to.bitkit-regtest.notification", category: "Extension")

    static func info(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        os_log("INFO: %{public}@ %{public}@ [%{public}@:%{public}@ line:%d]", log: log, type: .info, "\(message)", context, fileName, function, line)
    }

    static func debug(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        os_log("DEBUG: %{public}@ %{public}@ [%{public}@:%{public}@ line:%d]", log: log, type: .debug, "\(message)", context, fileName, function, line)
    }

    static func warn(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        os_log("WARN: %{public}@ %{public}@ [%{public}@:%{public}@ line:%d]", log: log, type: .default, "\(message)", context, fileName, function, line)
    }

    static func error(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        os_log("ERROR: %{public}@ %{public}@ [%{public}@:%{public}@ line:%d]", log: log, type: .error, "\(message)", context, fileName, function, line)
    }
}
