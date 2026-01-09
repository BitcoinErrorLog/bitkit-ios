import os.log
import UserNotifications

class NotificationService: UNNotificationServiceExtension {
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    var notificationType: BlocktankNotificationType?
    var notificationPayload: [String: Any]?

    private lazy var notificationLogger: OSLog = {
        let bundleID = Bundle.main.bundleIdentifier ?? "to.bitkit-regtest.notification"
        return OSLog(subsystem: bundleID, category: "NotificationService")
    }()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        os_log("🚨 Push received! %{public}@", log: notificationLogger, type: .error, request.identifier)
        os_log("🔔 UserInfo: %{public}@", log: notificationLogger, type: .error, request.content.userInfo)

        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        Task {
            do {
                try await decryptPayload(request)
                os_log("🔔 Decryption successful. Type: %{public}@", log: notificationLogger, type: .error, notificationType?.rawValue ?? "nil")
            } catch {
                os_log(
                    "🔔 Failed to decrypt notification payload: %{public}@",
                    log: notificationLogger,
                    type: .error,
                    error.localizedDescription
                )
            }

            updateNotificationContent()
            deliver()
        }
    }

    func decryptPayload(_ request: UNNotificationRequest) async throws {
        guard let aps = request.content.userInfo["aps"] as? AnyObject else {
            os_log("🔔 Failed to decrypt payload: missing aps payload", log: notificationLogger, type: .error)
            return
        }

        guard let alert = aps["alert"] as? AnyObject,
              let payload = alert["payload"] as? AnyObject,
              let cipher = payload["cipher"] as? String,
              let iv = payload["iv"] as? String,
              let publicKey = payload["publicKey"] as? String,
              let tag = payload["tag"] as? String
        else {
            os_log("🔔 Failed to decrypt payload: missing details", log: notificationLogger, type: .error)
            return
        }

        guard let ciphertext = Data(base64Encoded: cipher) else {
            os_log("🔔 Failed to decrypt payload: failed to decode cipher", log: notificationLogger, type: .error)
            return
        }

        guard let privateKey = try Keychain.load(key: .pushNotificationPrivateKey) else {
            os_log("🔔 Failed to decrypt payload: missing pushNotificationPrivateKey", log: notificationLogger, type: .error)
            return
        }

        let password = try Crypto.generateSharedSecret(privateKey: privateKey, nodePubkey: publicKey, derivationName: "bitkit-notifications")
        let decrypted = try Crypto.decrypt(.init(cipher: ciphertext, iv: iv.hexaData, tag: tag.hexaData), secretKey: password)

        os_log("🔔 Decrypted payload: %{public}@", log: notificationLogger, type: .error, String(data: decrypted, encoding: .utf8) ?? "")

        guard let jsonData = try JSONSerialization.jsonObject(with: decrypted, options: []) as? [String: Any] else {
            os_log("🔔 Failed to decrypt payload: failed to convert decrypted data to utf8", log: notificationLogger, type: .error)
            return
        }

        guard let payload = jsonData["payload"] as? [String: Any] else {
            os_log("🔔 Failed to decrypt payload: missing payload", log: notificationLogger, type: .error)
            return
        }

        guard let typeStr = jsonData["type"] as? String, let type = BlocktankNotificationType(rawValue: typeStr) else {
            os_log("🔔 Failed to decrypt payload: missing type", log: notificationLogger, type: .error)
            return
        }

        notificationType = type
        notificationPayload = payload
    }

    func updateNotificationContent() {
        guard let type = notificationType else {
            bestAttemptContent?.title = "Bitkit"
            bestAttemptContent?.body = "Open Bitkit to continue"
            return
        }

        switch type {
        case .incomingHtlc:
            bestAttemptContent?.title = "Payment Incoming"
            bestAttemptContent?.body = "Open now to receive - funds are being held"
            if let amountMsat = notificationPayload?["amountMsat"] as? UInt64 {
                let sats = amountMsat / 1000
                ReceivedTxSheetDetails(type: .lightning, sats: sats).save()
            }

        case .cjitPaymentArrived:
            bestAttemptContent?.title = "Payment Incoming"
            bestAttemptContent?.body = "Open now to receive via new channel"
            if let amountMsat = notificationPayload?["amountMsat"] as? UInt64 {
                let sats = amountMsat / 1000
                ReceivedTxSheetDetails(type: .lightning, sats: sats).save()
            }

        case .orderPaymentConfirmed:
            bestAttemptContent?.title = "Channel Ready"
            bestAttemptContent?.body = "Open Bitkit to complete setup"

        case .mutualClose:
            bestAttemptContent?.title = "Channel Closed"
            bestAttemptContent?.body = "Funds moved to savings"

        case .wakeToTimeout:
            bestAttemptContent?.title = "Bitkit"
            bestAttemptContent?.body = "Open to complete pending operation"

        case .paykitPaymentRequest:
            bestAttemptContent?.title = "Payment Request Received"
            bestAttemptContent?.body = "Tap to review and pay"

        case .paykitSubscriptionDue:
            bestAttemptContent?.title = "Subscription Payment Due"
            bestAttemptContent?.body = "Open to process payment"

        case .paykitAutoPayExecuted:
            if let amount = notificationPayload?["amount"] as? UInt64 {
                bestAttemptContent?.title = "Auto-Pay Executed"
                bestAttemptContent?.body = "₿ \(amount) sent"
            } else {
                bestAttemptContent?.title = "Auto-Pay Executed"
                bestAttemptContent?.body = "Payment sent successfully"
            }

        case .paykitSubscriptionFailed:
            bestAttemptContent?.title = "Subscription Payment Failed"
            if let reason = notificationPayload?["reason"] as? String {
                bestAttemptContent?.body = reason
            } else {
                bestAttemptContent?.body = "Open to retry"
            }
        }

        bestAttemptContent?.categoryIdentifier = "INCOMING_PAYMENT"
    }

    func deliver() {
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
            os_log("🔔 Notification delivered successfully", log: notificationLogger, type: .error)
        } else {
            os_log("🔔 Missing contentHandler or bestAttemptContent", log: notificationLogger, type: .error)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        os_log("🔔 NotificationService: Delivering notification before timeout", log: notificationLogger, type: .error)

        if let contentHandler, let bestAttemptContent {
            bestAttemptContent.title = "Bitkit"
            bestAttemptContent.body = "Open Bitkit to continue"
            contentHandler(bestAttemptContent)
        }
    }
}
