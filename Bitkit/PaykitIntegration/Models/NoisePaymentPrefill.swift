import Foundation

/// Shared storage for pre-filling noise payment recipient from other views
class NoisePaymentPrefill {
    static let shared = NoisePaymentPrefill()
    
    var recipientPubkey: String?
    
    private init() {}
    
    func consume() -> String? {
        let value = recipientPubkey
        recipientPubkey = nil
        return value
    }
}
