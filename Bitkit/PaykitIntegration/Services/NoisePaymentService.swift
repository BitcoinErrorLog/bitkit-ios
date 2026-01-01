//
//  NoisePaymentService.swift
//  Bitkit
//
//  Noise Payment Service for coordinating Noise protocol payments
//  Uses pubky-noise FFI for secure encrypted communication
//

import Foundation
import Network
// PaykitMobile types are available from FFI/PaykitMobile.swift

/// A payment request to send over Noise channel
public struct NoisePaymentRequest: Codable {
    public let receiptId: String
    public let payerPubkey: String
    public let payeePubkey: String
    public let methodId: String
    public let amount: String?
    public let currency: String?
    public let description: String?
    public let invoiceNumber: String?
    public let createdAt: Int64
    
    enum CodingKeys: String, CodingKey {
        case receiptId = "receipt_id"
        case payerPubkey = "payer"
        case payeePubkey = "payee"
        case methodId = "method_id"
        case amount
        case currency
        case description
        case invoiceNumber = "invoice_number"
        case createdAt = "created_at"
    }
    
    public init(
        payerPubkey: String,
        payeePubkey: String,
        methodId: String,
        amount: String? = nil,
        currency: String? = nil,
        description: String? = nil,
        invoiceNumber: String? = nil
    ) {
        self.receiptId = "rcpt_\(UUID().uuidString)"
        self.payerPubkey = payerPubkey
        self.payeePubkey = payeePubkey
        self.methodId = methodId
        self.amount = amount
        self.currency = currency
        self.description = description
        self.invoiceNumber = invoiceNumber
        self.createdAt = Int64(Date().timeIntervalSince1970)
    }
}

/// Response from a payment request
public struct NoisePaymentResponse: Codable {
    public let success: Bool
    public let receiptId: String?
    public let confirmedAt: Date?
    public let errorCode: String?
    public let errorMessage: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case receiptId = "receipt_id"
        case confirmedAt = "confirmed_at"
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
    
    public init(success: Bool, receiptId: String?, confirmedAt: Date?, errorCode: String?, errorMessage: String?) {
        self.success = success
        self.receiptId = receiptId
        self.confirmedAt = confirmedAt
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

/// Wire format for Noise messages
private struct NoiseMessage: Codable {
    let type: String
    let receiptId: String
    var payer: String?
    var payee: String?
    var methodId: String?
    var amount: String?
    var currency: String?
    var description: String?
    var invoiceNumber: String?
    var createdAt: Int64?
    var confirmedAt: Int64?
    var success: Bool?
    var errorCode: String?
    var errorMessage: String?
    
    enum CodingKeys: String, CodingKey {
        case type
        case receiptId = "receipt_id"
        case payer
        case payee
        case methodId = "method_id"
        case amount
        case currency
        case description
        case invoiceNumber = "invoice_number"
        case createdAt = "created_at"
        case confirmedAt = "confirmed_at"
        case success
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}

/// Service errors
public enum NoisePaymentError: LocalizedError {
    case noIdentity
    case noKeypairCached(String)
    case keyDerivationFailed(String)
    case endpointNotFound
    case invalidEndpoint(String)
    case connectionFailed(String)
    case handshakeFailed(String)
    case encryptionFailed(String)
    case decryptionFailed(String)
    case invalidResponse(String)
    case timeout
    case cancelled
    case serverError(code: String, message: String)
    case noiseManagerNotInitialized
    case notConnected
    
    public var errorDescription: String? {
        switch self {
        case .noIdentity:
            return "No identity configured"
        case .noKeypairCached(let msg):
            return msg
        case .keyDerivationFailed(let msg):
            return "Failed to derive encryption keys: \(msg)"
        case .endpointNotFound:
            return "Recipient has no Noise endpoint published"
        case .invalidEndpoint(let msg):
            return "Invalid endpoint format: \(msg)"
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        case .handshakeFailed(let msg):
            return "Secure handshake failed: \(msg)"
        case .encryptionFailed(let msg):
            return "Encryption failed: \(msg)"
        case .decryptionFailed(let msg):
            return "Decryption failed: \(msg)"
        case .invalidResponse(let msg):
            return "Invalid response: \(msg)"
        case .timeout:
            return "Operation timed out"
        case .cancelled:
            return "Operation cancelled"
        case .serverError(let code, let message):
            return "Server error [\(code)]: \(message)"
        case .noiseManagerNotInitialized:
            return "Noise manager not initialized"
        case .notConnected:
            return "Not connected to peer"
        }
    }
}

/// Service for coordinating Noise protocol payments
/// Uses FfiNoiseManager from pubky-noise for encrypted communication
public final class NoisePaymentService {
    
    public static let shared = NoisePaymentService()
    
    private var paykitClient: PaykitClient?
    
    // Connection state
    private var isConnected = false
    private var currentSessionId: String?
    private var noiseManager: FfiNoiseManager?
    private var connection: NWConnection?
    
    // Server state
    private var listener: NWListener?
    private var isServerRunning = false
    private var serverRequestHandler: ((NoisePaymentRequest) async -> Void)?
    
    // Configuration
    public var connectionTimeoutSeconds: TimeInterval = 30
    
    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
    
    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    
    private init() {}
    
    /// Initialize with PaykitClient
    public func initialize(client: PaykitClient) {
        self.paykitClient = client
    }
    
    /// Check if key rotation is needed and perform epoch swap
    ///
    /// - Parameter forceRotation: If true, rotate immediately if epoch 1 is available
    /// - Returns: True if rotation occurred
    public func checkKeyRotation(forceRotation: Bool = false) async -> Bool {
        let keyManager = PaykitKeyManager.shared
        let currentEpoch = keyManager.getCurrentEpoch()
        
        guard currentEpoch == 0 else { return false }
        
        // Check if we have epoch 1 keypair available
        guard keyManager.getCachedNoiseKeypair(epoch: 1) != nil else { return false }
        
        if forceRotation {
            keyManager.setCurrentEpoch(1)
            Logger.info("NoisePaymentService: Rotated to epoch 1 keypair", context: "NoisePaymentService")
            return true
        }
        
        return false
    }
    
    /// Send a payment request over Noise protocol
    public func sendPaymentRequest(_ request: NoisePaymentRequest) async throws -> NoisePaymentResponse {
        guard paykitClient != nil else {
            throw NoisePaymentError.noIdentity
        }
        
        let directoryService = DirectoryService.shared
        
        // Step 1: Discover Noise endpoint for recipient
        guard let endpoint = try await directoryService.discoverNoiseEndpoint(for: request.payeePubkey) else {
            throw NoisePaymentError.endpointNotFound
        }
        
        // Step 2: Connect to endpoint
        try await connect(endpoint)
        
        guard let sessionId = currentSessionId, let manager = noiseManager else {
            throw NoisePaymentError.notConnected
        }
        
        // Step 3: Create and encrypt message
        let message = NoiseMessage(
            type: "request_receipt",
            receiptId: request.receiptId,
            payer: request.payerPubkey,
            payee: request.payeePubkey,
            methodId: request.methodId,
            amount: request.amount,
            currency: request.currency,
            description: request.description,
            invoiceNumber: request.invoiceNumber,
            createdAt: request.createdAt
        )
        
        let jsonData = try JSONEncoder().encode(message)
        
        let ciphertext: Data
        do {
            ciphertext = try manager.encrypt(sessionId: sessionId, plaintext: jsonData)
        } catch {
            throw NoisePaymentError.encryptionFailed(error.localizedDescription)
        }
        
        // Step 4: Send with length prefix
        try await sendLengthPrefixedData(ciphertext)
        
        // Step 5: Receive response
        let responseCiphertext = try await receiveLengthPrefixedData()
        
        // Step 6: Decrypt
        let responsePlaintext: Data
        do {
            responsePlaintext = try manager.decrypt(sessionId: sessionId, ciphertext: responseCiphertext)
        } catch {
            throw NoisePaymentError.decryptionFailed(error.localizedDescription)
        }
        
        // Step 7: Parse response
        return try parsePaymentResponse(responsePlaintext, expectedReceiptId: request.receiptId)
    }
    
    /// Connect to a Noise endpoint
    private func connect(_ endpoint: NoiseEndpointInfo) async throws {
        let keyManager = PaykitKeyManager.shared
        
        // Get cached X25519 keypair from Ring
        guard let keypair = keyManager.getCachedNoiseKeypair() else {
            throw NoisePaymentError.noKeypairCached("No noise keypair available. Please reconnect to Pubky Ring.")
        }
        
        let seedData = Data(hexString: keypair.secretKey)
        let deviceId = PubkyRingBridge.shared.deviceId
        let deviceIdData = deviceId.data(using: .utf8) ?? Data()
        
        // Create Noise manager
        let config = FfiMobileConfig(
            autoReconnect: false,
            maxReconnectAttempts: 0,
            reconnectDelayMs: 0,
            batterySaver: false,
            chunkSize: 32768
        )
        
        do {
            noiseManager = try FfiNoiseManager.newClient(
                config: config,
                clientSeed: seedData,
                clientKid: "bitkit-ios",
                deviceId: deviceIdData
            )
        } catch {
            Logger.error("NoisePaymentService: Failed to create Noise manager: \(error)", context: "NoisePaymentService")
            throw NoisePaymentError.handshakeFailed("Failed to create Noise manager: \(error.localizedDescription)")
        }
        
        // Parse server pubkey from hex
        let serverPubkey = Data(hexString: endpoint.serverNoisePubkey)
        
        // Create TCP connection
        let host = NWEndpoint.Host(endpoint.host)
        let port = NWEndpoint.Port(integerLiteral: endpoint.port)
        connection = NWConnection(host: host, port: port, using: .tcp)
        
        // Start connection with timeout
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.connection?.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    self?.connection?.stateUpdateHandler = nil
                    continuation.resume(throwing: NoisePaymentError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    self?.connection?.stateUpdateHandler = nil
                    continuation.resume(throwing: NoisePaymentError.cancelled)
                default:
                    break
                }
            }
            connection?.start(queue: .global())
        }
        
        // Perform Noise handshake
        try await performHandshake(serverPubkey: serverPubkey)
        isConnected = true
    }
    
    /// Perform Noise IK handshake
    private func performHandshake(serverPubkey: Data) async throws {
        guard let manager = noiseManager else {
            throw NoisePaymentError.noiseManagerNotInitialized
        }
        
        // Step 1: Initiate connection
        let initResult: FfiInitiateResult
        do {
            initResult = try manager.initiateConnection(serverPk: serverPubkey, hint: nil)
        } catch {
            Logger.error("NoisePaymentService: Failed to initiate Noise connection: \(error)", context: "NoisePaymentService")
            throw NoisePaymentError.handshakeFailed("Failed to initiate: \(error.localizedDescription)")
        }
        
        // Step 2: Send first message
        try await sendRawData(initResult.firstMessage)
        
        // Step 3: Receive server response
        let response = try await receiveRawData()
        
        // Step 4: Complete handshake
        do {
            let sessionId = try manager.completeConnection(sessionId: initResult.sessionId, serverResponse: response)
            currentSessionId = sessionId
            Logger.info("NoisePaymentService: Handshake completed, session: \(sessionId)", context: "NoisePaymentService")
        } catch {
            Logger.error("NoisePaymentService: Failed to complete Noise connection: \(error)", context: "NoisePaymentService")
            throw NoisePaymentError.handshakeFailed("Failed to complete: \(error.localizedDescription)")
        }
    }
    
    /// Disconnect from current peer
    public func disconnect() {
        if let sessionId = currentSessionId {
            noiseManager?.removeSession(sessionId: sessionId)
        }
        
        connection?.cancel()
        connection = nil
        noiseManager = nil
        isConnected = false
        currentSessionId = nil
    }
    
    /// Receive a payment request (server mode)
    /// Note: Server mode uses startBackgroundServer() with a callback
    public func receivePaymentRequest() async throws -> NoisePaymentRequest? {
        // Server mode is implemented via startBackgroundServer()
        // This method returns nil as server mode uses callbacks instead
        return nil
    }
    
    // MARK: - Background Server Mode
    
    /// Start a background Noise server to receive incoming payment requests.
    /// This is called when the app is woken by a push notification.
    ///
    /// - Parameters:
    ///   - port: Port to listen on
    ///   - handler: Callback invoked when a payment request is received
    public func startBackgroundServer(port: Int, handler: @escaping (NoisePaymentRequest) async -> Void) async throws {
        guard !isServerRunning else {
            Logger.warn("NoisePaymentService: Background server already running", context: "NoisePaymentService")
            return
        }
        
        serverRequestHandler = handler
        
        let params = NWParameters.tcp
        let nwPort = NWEndpoint.Port(integerLiteral: UInt16(port))
        
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            throw NoisePaymentError.connectionFailed("Failed to create listener: \(error.localizedDescription)")
        }
        
        isServerRunning = true
        
        Logger.info("NoisePaymentService: Server started on port \(port)", context: "NoisePaymentService")
        
        // Accept a single connection (push-wake mode)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.listener?.newConnectionHandler = nil
                
                Task {
                    do {
                        try await self?.handleServerConnection(newConnection)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            
            listener?.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    continuation.resume(throwing: NoisePaymentError.connectionFailed(error.localizedDescription))
                }
            }
            
            listener?.start(queue: .global())
            
            // Timeout after 30 seconds
            Task {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                if self.isServerRunning {
                    self.stopBackgroundServer()
                    continuation.resume(throwing: NoisePaymentError.timeout)
                }
            }
        }
    }
    
    /// Stop the background server
    public func stopBackgroundServer() {
        listener?.cancel()
        listener = nil
        isServerRunning = false
        serverRequestHandler = nil
        Logger.info("NoisePaymentService: Background server stopped", context: "NoisePaymentService")
    }
    
    /// Handle an incoming server connection
    private func handleServerConnection(_ clientConnection: NWConnection) async throws {
        connection = clientConnection
        
        defer {
            disconnect()
        }
        
        // Wait for connection ready
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            clientConnection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    clientConnection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    clientConnection.stateUpdateHandler = nil
                    continuation.resume(throwing: NoisePaymentError.connectionFailed(error.localizedDescription))
                default:
                    break
                }
            }
            clientConnection.start(queue: .global())
        }
        
        let keyManager = PaykitKeyManager.shared
        
        // Get cached X25519 keypair from Ring
        guard let keypair = keyManager.getCachedNoiseKeypair() else {
            throw NoisePaymentError.noKeypairCached("No noise keypair available. Please reconnect to Pubky Ring.")
        }
        
        let seedData = Data(hexString: keypair.secretKey)
        let deviceId = PubkyRingBridge.shared.deviceId
        let deviceIdData = deviceId.data(using: .utf8) ?? Data()
        
        // Create Noise manager in server mode
        let config = FfiMobileConfig(
            autoReconnect: false,
            maxReconnectAttempts: 0,
            reconnectDelayMs: 0,
            batterySaver: false,
            chunkSize: 32768
        )
        
        noiseManager = try FfiNoiseManager.newServer(
            config: config,
            serverSeed: seedData,
            serverKid: "bitkit-ios-server",
            deviceId: deviceIdData
        )
        
        // Perform server-side handshake
        try await performServerHandshake()
        
        guard let sessionId = currentSessionId, let manager = noiseManager else {
            throw NoisePaymentError.notConnected
        }
        
        // Receive encrypted message
        let ciphertext = try await receiveLengthPrefixedData()
        
        // Decrypt
        let plaintext: Data
        do {
            plaintext = try manager.decrypt(sessionId: sessionId, ciphertext: ciphertext)
        } catch {
            throw NoisePaymentError.decryptionFailed(error.localizedDescription)
        }
        
        // Parse as payment request
        let request = try parsePaymentRequest(plaintext)
        
        // Send confirmation response
        let response = NoiseMessage(
            type: "confirm_receipt",
            receiptId: request.receiptId,
            confirmedAt: Int64(Date().timeIntervalSince1970),
            success: true
        )
        let responseData = try JSONEncoder().encode(response)
        
        let encryptedResponse: Data
        do {
            encryptedResponse = try manager.encrypt(sessionId: sessionId, plaintext: responseData)
        } catch {
            throw NoisePaymentError.encryptionFailed(error.localizedDescription)
        }
        try await sendLengthPrefixedData(encryptedResponse)
        
        // Notify callback
        if let handler = serverRequestHandler {
            await handler(request)
        }
        
        Logger.info("NoisePaymentService: Successfully received payment request: \(request.receiptId)", context: "NoisePaymentService")
    }
    
    /// Perform server-side Noise handshake
    private func performServerHandshake() async throws {
        guard let manager = noiseManager else {
            throw NoisePaymentError.noiseManagerNotInitialized
        }
        
        // Receive first message from client
        let firstMessage = try await receiveRawData()
        
        // Process handshake
        let result: FfiAcceptResult
        do {
            result = try manager.acceptConnection(firstMsg: firstMessage)
        } catch {
            Logger.error("NoisePaymentService: Failed to accept Noise connection: \(error)", context: "NoisePaymentService")
            throw NoisePaymentError.handshakeFailed("Failed to accept: \(error.localizedDescription)")
        }
        
        // Send response
        try await sendRawData(result.responseMessage)
        
        currentSessionId = result.sessionId
        isConnected = true
        Logger.info("NoisePaymentService: Server handshake completed, session: \(result.sessionId)", context: "NoisePaymentService")
    }
    
    // MARK: - Network I/O
    
    private func sendRawData(_ data: Data) async throws {
        guard let conn = connection else {
            throw NoisePaymentError.notConnected
        }
        
        // Length prefix (4 bytes, big-endian)
        var length = UInt32(data.count).bigEndian
        var lengthData = Data(bytes: &length, count: 4)
        lengthData.append(data)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: lengthData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: NoisePaymentError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    private func receiveRawData() async throws -> Data {
        guard let conn = connection else {
            throw NoisePaymentError.notConnected
        }
        
        // Read length prefix (4 bytes)
        let lengthData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: NoisePaymentError.connectionFailed(error.localizedDescription))
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NoisePaymentError.connectionFailed("No data received"))
                }
            }
        }
        
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        // Read message body
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: NoisePaymentError.connectionFailed(error.localizedDescription))
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NoisePaymentError.connectionFailed("No data received"))
                }
            }
        }
    }
    
    private func sendLengthPrefixedData(_ data: Data) async throws {
        try await sendRawData(data)
    }
    
    private func receiveLengthPrefixedData() async throws -> Data {
        try await receiveRawData()
    }
    
    // MARK: - Parsing
    
    private func parsePaymentRequest(_ data: Data) throws -> NoisePaymentRequest {
        let message: NoiseMessage
        do {
            message = try JSONDecoder().decode(NoiseMessage.self, from: data)
        } catch {
            throw NoisePaymentError.invalidResponse("Invalid JSON structure: \(error.localizedDescription)")
        }
        
        guard message.type == "request_receipt" else {
            throw NoisePaymentError.invalidResponse("Unexpected message type: \(message.type)")
        }
        
        return NoisePaymentRequest(
            payerPubkey: message.payer ?? "",
            payeePubkey: message.payee ?? "",
            methodId: message.methodId ?? "",
            amount: message.amount,
            currency: message.currency,
            description: message.description,
            invoiceNumber: message.invoiceNumber
        )
    }
    
    private func parsePaymentResponse(_ data: Data, expectedReceiptId: String) throws -> NoisePaymentResponse {
        let message: NoiseMessage
        do {
            message = try JSONDecoder().decode(NoiseMessage.self, from: data)
        } catch {
            throw NoisePaymentError.invalidResponse("Invalid JSON structure: \(error.localizedDescription)")
        }
        
        switch message.type {
        case "confirm_receipt":
            return NoisePaymentResponse(
                success: message.success ?? true,
                receiptId: message.receiptId,
                confirmedAt: message.confirmedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                errorCode: nil,
                errorMessage: nil
            )
        case "error":
            return NoisePaymentResponse(
                success: false,
                receiptId: message.receiptId,
                confirmedAt: nil,
                errorCode: message.errorCode ?? "unknown",
                errorMessage: message.errorMessage ?? "Unknown error"
            )
        default:
            throw NoisePaymentError.invalidResponse("Unexpected message type: \(message.type)")
        }
    }
}

// MARK: - Data Extension for Hex String

private extension Data {
    init(hexString: String) {
        self.init()
        var hex = hexString
        while !hex.isEmpty {
            let index = hex.index(hex.startIndex, offsetBy: min(2, hex.count))
            let byteString = String(hex[..<index])
            hex = String(hex[index...])
            if let byte = UInt8(byteString, radix: 16) {
                append(byte)
            }
        }
    }
}

