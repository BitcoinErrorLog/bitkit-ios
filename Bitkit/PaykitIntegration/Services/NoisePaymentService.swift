//
//  NoisePaymentService.swift
//  Bitkit
//
//  Noise Payment Service for coordinating Noise protocol payments
//

import Foundation
import Network
import BitkitCore
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
    /// Invoice number for cross-referencing
    public let invoiceNumber: String?
    public let createdAt: Int
    
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
        self.createdAt = Int(Date().timeIntervalSince1970)
    }
}

/// Response from a payment request
public struct NoisePaymentResponse: Codable {
    public let success: Bool
    public let receiptId: String?
    public let confirmedAt: Int?
    public let errorCode: String?
    public let errorMessage: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case receiptId = "receipt_id"
        case confirmedAt = "confirmed_at"
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
    
    public init(
        success: Bool,
        receiptId: String? = nil,
        confirmedAt: Int? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.success = success
        self.receiptId = receiptId
        self.confirmedAt = confirmedAt
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

/// Base class for Noise messages
internal struct NoiseMessage: Codable {
    let type: String
    let receiptId: String
    let payer: String?
    let payee: String?
    let methodId: String?
    let amount: String?
    let currency: String?
    let description: String?
    let invoiceNumber: String?
    let createdAt: Int?
    let confirmedAt: Int?
    let success: Bool?
    let errorCode: String?
    let errorMessage: String?
    
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
    case noKeypair
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
    
    public var errorDescription: String? {
        switch self {
        case .noIdentity:
            return "No identity configured"
        case .noKeypair:
            return "No noise keypair available. Please reconnect to Pubky Ring."
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
        }
    }
}

/// Service for coordinating Noise protocol payments
public final class NoisePaymentService {
    
    public static let shared = NoisePaymentService()
    
    private var paykitClient: PaykitClient?
    private var noiseManager: FfiNoiseManager?
    private var currentSessionId: String?
    
    private init() {}
    
    /// Initialize with PaykitClient
    public func initialize(client: PaykitClient) {
        self.paykitClient = client
    }
    
    private func getNoiseManager(isServer: Bool) throws -> FfiNoiseManager {
        if let existing = noiseManager { return existing }
        
        // Get cached X25519 keypair from Ring (no local Ed25519 derivation)
        guard let keypair = PaykitKeyManager.shared.getCachedNoiseKeypair() else {
            throw NoisePaymentError.noKeypair
        }
        
        // Use X25519 secret key as seed for Noise manager
        guard let seedData = Data(hex: keypair.secretKeyHex) else {
            throw NoisePaymentError.noKeypair
        }
        
        let deviceId = PaykitKeyManager.shared.getDeviceId()
        let deviceIdData = deviceId.data(using: .utf8) ?? Data()
        
        let config = FfiMobileConfig(
            autoReconnect: false,
            maxReconnectAttempts: 0,
            reconnectDelayMs: 0,
            batterySaver: false,
            chunkSize: 32768
        )
        
        let manager: FfiNoiseManager
        if isServer {
            manager = try FfiNoiseManager.newServer(
                config: config,
                serverSeed: seedData,
                serverKid: "bitkit-ios-server",
                deviceId: deviceIdData
            )
        } else {
            manager = try FfiNoiseManager.newClient(
                config: config,
                clientSeed: seedData,
                clientKid: "bitkit-ios",
                deviceId: deviceIdData
            )
        }
        
        self.noiseManager = manager
        return manager
    }
    
    /// Send a payment request over Noise protocol
    public func sendPaymentRequest(_ request: NoisePaymentRequest) async throws -> NoisePaymentResponse {
        guard paykitClient != nil else {
            throw NoisePaymentError.noIdentity
        }
        
        // Step 1: Discover Noise endpoint for recipient
        guard let endpoint = try? await DirectoryService.shared.discoverNoiseEndpoint(for: request.payeePubkey) else {
            Logger.warn("No Noise endpoint found for \(request.payeePubkey.prefix(16))..., will fallback to async", context: "NoisePaymentService")
            throw NoisePaymentError.endpointNotFound
        }
        
        // Step 2: Parse endpoint (host:port)
        let components = endpoint.host.split(separator: ":")
        guard components.count == 2,
              let port = UInt16(components[1]) else {
            throw NoisePaymentError.invalidEndpoint(endpoint.host)
        }
        let host = String(components[0])
        
        Logger.info("Connecting to Noise endpoint: \(host):\(port)", context: "NoisePaymentService")
        
        // Step 3: Connect and send
        return try await sendRequestOverNoise(
            request: request,
            host: host,
            port: port,
            recipientNoisePubkey: endpoint.serverNoisePubkey
        )
    }
    
    /// Send request over Noise connection
    private func sendRequestOverNoise(
        request: NoisePaymentRequest,
        host: String,
        port: UInt16,
        recipientNoisePubkey: String
    ) async throws -> NoisePaymentResponse {
        // Create TCP connection
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .tcp)
        
        return try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Connection established, send request
                    Task {
                        do {
                            let response = try await self.performNoiseExchange(
                                connection: connection,
                                request: request,
                                recipientNoisePubkey: recipientNoisePubkey
                            )
                            connection.cancel()
                            continuation.resume(returning: response)
                        } catch {
                            connection.cancel()
                            continuation.resume(throwing: error)
                        }
                    }
                case .failed(let error):
                    continuation.resume(throwing: NoisePaymentError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    continuation.resume(throwing: NoisePaymentError.cancelled)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
    }
    
    /// Perform Noise handshake and exchange
    private func performNoiseExchange(
        connection: NWConnection,
        request: NoisePaymentRequest,
        recipientNoisePubkey: String
    ) async throws -> NoisePaymentResponse {
        let manager = try getNoiseManager(isServer: false)
        
        // Step 1: Handshake
        guard let serverPk = recipientNoisePubkey.hexaData as Data? else {
            throw NoisePaymentError.invalidEndpoint("Invalid recipient noise pubkey")
        }
        
        let initResult = try manager.initiateConnection(serverPk: serverPk, hint: nil)
        
        // Send first message
        try await sendRawData(initResult.firstMessage, connection: connection)
        
        // Receive server response
        let serverResponse = try await receiveRawData(connection: connection)
        
        // Complete connection
        let sessionId = try manager.completeConnection(sessionId: initResult.sessionId, serverResponse: serverResponse)
        self.currentSessionId = sessionId
        
        Logger.info("Noise handshake completed, session: \(sessionId)", context: "NoisePaymentService")
        
        // Step 2: Encrypted Message
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
            createdAt: request.createdAt,
            confirmedAt: nil,
            success: nil,
            errorCode: nil,
            errorMessage: nil
        )
        
        let jsonData = try JSONEncoder().encode(message)
        let ciphertext = try manager.encrypt(sessionId: sessionId, plaintext: jsonData)
        
        // Send encrypted message
        try await sendRawData(ciphertext, connection: connection)
        
        // Receive encrypted response
        let responseCiphertext = try await receiveRawData(connection: connection)
        let responsePlaintext = try manager.decrypt(sessionId: sessionId, ciphertext: responseCiphertext)
        
        // Parse response
        let responseMessage = try JSONDecoder().decode(NoiseMessage.self, from: responsePlaintext)
        
        return NoisePaymentResponse(
            success: responseMessage.success ?? false,
            receiptId: responseMessage.receiptId,
            confirmedAt: responseMessage.confirmedAt,
            errorCode: responseMessage.errorCode,
            errorMessage: responseMessage.errorMessage
        )
    }
    
    private func sendRawData(_ data: Data, connection: NWConnection) async throws {
        // Send length prefix (4 bytes)
        var length = UInt32(data.count).bigEndian
        var prefixedData = Data(bytes: &length, count: 4)
        prefixedData.append(data)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: prefixedData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    private func receiveRawData(connection: NWConnection) async throws -> Data {
        // Read length prefix
        let lengthData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NoisePaymentError.invalidResponse("No data received"))
                }
            }
        }
        
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        // Read message body
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NoisePaymentError.invalidResponse("No data received"))
                }
            }
        }
    }
    
    /// Receive data with timeout
    private func receiveWithTimeout(connection: NWConnection, timeout: TimeInterval) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                // Read length prefix
                let lengthData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let data = data {
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(throwing: NoisePaymentError.invalidResponse("No data received"))
                        }
                    }
                }
                
                let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                
                // Read message body
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { data, _, _, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let data = data {
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(throwing: NoisePaymentError.invalidResponse("No data received"))
                        }
                    }
                }
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NoisePaymentError.timeout
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    /// Receive a payment request (server mode)
    public func receivePaymentRequest() async throws -> NoisePaymentRequest? {
        // In production, this would:
        // 1. Listen for incoming Noise connections
        // 2. Perform handshake
        // 3. Decrypt and parse payment request
        // 4. Return request for processing
        
        return nil
    }
    
    // MARK: - Background Server Mode
    
    private var serverConnection: NWListener?
    private var isServerRunning = false
    private var onRequestCallback: ((NoisePaymentRequest) -> Void)?
    
    /// Start a background Noise server to receive incoming payment requests.
    /// This is called when the app is woken by a push notification indicating
    /// an incoming Noise connection.
    ///
    /// - Parameters:
    ///   - port: Port to listen on
    ///   - onRequest: Callback invoked when a payment request is received
    public func startBackgroundServer(
        port: UInt16,
        onRequest: @escaping (NoisePaymentRequest) -> Void
    ) async throws {
        guard !isServerRunning else {
            Logger.warn("NoisePaymentService: Background server already running", context: "NoisePaymentService")
            return
        }
        
        self.onRequestCallback = onRequest
        
        do {
            // Create NWListener for incoming connections
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            self.serverConnection = listener
            self.isServerRunning = true
            
            Logger.info("NoisePaymentService: Starting Noise server on port \(port)", context: "NoisePaymentService")
            
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleServerConnection(connection)
            }
            
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Logger.info("NoisePaymentService: Server ready on port \(port)", context: "NoisePaymentService")
                case .failed(let error):
                    Logger.error("NoisePaymentService: Server failed: \(error)", context: "NoisePaymentService")
                    self?.stopBackgroundServer()
                case .cancelled:
                    Logger.info("NoisePaymentService: Server cancelled", context: "NoisePaymentService")
                default:
                    break
                }
            }
            
            listener.start(queue: DispatchQueue.global(qos: .userInitiated))
            
            // Wait for connection with timeout
            try await withTimeout(seconds: 30) { [weak self] in
                // Keep server running until connection is handled
                while self?.isServerRunning == true {
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
            }
            
        } catch {
            Logger.error("NoisePaymentService: Server error: \(error)", context: "NoisePaymentService")
            stopBackgroundServer()
            throw error
        }
    }
    
    /// Stop the background server
    public func stopBackgroundServer() {
        serverConnection?.cancel()
        serverConnection = nil
        isServerRunning = false
        onRequestCallback = nil
        Logger.info("NoisePaymentService: Background server stopped", context: "NoisePaymentService")
    }
    
    /// Handle an incoming server connection
    private func handleServerConnection(_ connection: NWConnection) {
        Logger.info("NoisePaymentService: Received incoming connection", context: "NoisePaymentService")
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task {
                    await self?.handleServerConnectionAsync(connection)
                }
            case .failed(let error):
                Logger.error("NoisePaymentService: Connection failed: \(error)", context: "NoisePaymentService")
                self?.stopBackgroundServer()
            default:
                break
            }
        }
        
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
    }
    
    /// Handle server connection with proper Noise handshake
    private func handleServerConnectionAsync(_ connection: NWConnection) async {
        do {
            // Step 1: Create server-mode Noise manager
            let manager = try getNoiseManager(isServer: true)
            
            // Step 2: Perform server-side Noise handshake
            let sessionId = try await performServerHandshake(connection: connection, manager: manager)
            self.currentSessionId = sessionId
            
            Logger.info("NoisePaymentService: Server handshake completed, session: \(sessionId)", context: "NoisePaymentService")
            
            // Step 3: Receive encrypted message
            let ciphertext = try await receiveRawData(connection: connection)
            
            // Step 4: Decrypt the message
            let plaintext = try manager.decrypt(sessionId: sessionId, ciphertext: ciphertext)
            
            // Step 5: Parse the payment request
            let message = try JSONDecoder().decode(NoiseMessage.self, from: plaintext)
            
            guard message.type == "request_receipt" else {
                throw NoisePaymentError.invalidResponse("Unexpected message type: \(message.type)")
            }
            
            let request = NoisePaymentRequest(
                payerPubkey: message.payer ?? "",
                payeePubkey: message.payee ?? "",
                methodId: message.methodId ?? "",
                amount: message.amount,
                currency: message.currency,
                description: message.description,
                invoiceNumber: message.invoiceNumber
            )
            
            // Step 6: Create and encrypt confirmation response
            let response = NoiseMessage(
                type: "confirm_receipt",
                receiptId: request.receiptId,
                payer: nil,
                payee: nil,
                methodId: nil,
                amount: nil,
                currency: nil,
                description: nil,
                invoiceNumber: nil,
                createdAt: nil,
                confirmedAt: Int(Date().timeIntervalSince1970),
                success: true,
                errorCode: nil,
                errorMessage: nil
            )
            
            let responseData = try JSONEncoder().encode(response)
            let encryptedResponse = try manager.encrypt(sessionId: sessionId, plaintext: responseData)
            
            // Step 7: Send encrypted response
            try await sendRawData(encryptedResponse, connection: connection)
            
            // Step 8: Notify callback
            onRequestCallback?(request)
            Logger.info("NoisePaymentService: Successfully received payment request: \(request.receiptId)", context: "NoisePaymentService")
            
            // Stop server after handling request
            stopBackgroundServer()
            
        } catch {
            Logger.error("NoisePaymentService: Server connection error: \(error)", context: "NoisePaymentService")
            stopBackgroundServer()
        }
    }
    
    /// Perform server-side Noise handshake
    private func performServerHandshake(connection: NWConnection, manager: FfiNoiseManager) async throws -> String {
        // Step 1: Receive first message from client
        let firstMessage = try await receiveRawData(connection: connection)
        
        // Step 2: Process handshake
        let acceptResult = try manager.acceptConnection(firstMsg: firstMessage)
        
        // Step 3: Send response message to client
        try await sendRawData(acceptResult.responseMessage, connection: connection)
        
        return acceptResult.sessionId
    }
    
    /// Helper to run async operation with timeout
    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NoisePaymentError.timeout
            }
            
            guard let result = try await group.next() else {
                throw NoisePaymentError.timeout
            }
            
            group.cancelAll()
            return result
        }
    }
}

