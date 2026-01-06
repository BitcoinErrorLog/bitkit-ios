//
//  ImageUploadService.swift
//  Bitkit
//
//  Uploads images to homeserver and creates PubkyAppFile entries.
//  Follows pubky-app-specs for file storage.
//

import Foundation
import UIKit

/// Represents a file uploaded to the homeserver (pubky-app-specs PubkyAppFile)
public struct PubkyAppFile: Codable {
    public let name: String
    public let createdAt: Int64
    public let src: String
    public let contentType: String
    public let size: Int
    
    enum CodingKeys: String, CodingKey {
        case name
        case createdAt = "created_at"
        case src
        case contentType = "content_type"
        case size
    }
    
    public init(name: String, createdAt: Int64, src: String, contentType: String, size: Int) {
        self.name = name
        self.createdAt = createdAt
        self.src = src
        self.contentType = contentType
        self.size = size
    }
}

/// Service for uploading images to the homeserver
public class ImageUploadService {
    
    public static let shared = ImageUploadService()
    
    private let maxImageSize: CGFloat = 1024  // Max dimension
    private let jpegQuality: CGFloat = 0.8
    
    private init() {}
    
    /// Upload an image and return the pubky:// URL for use in profile.image
    /// - Parameters:
    ///   - image: The UIImage to upload
    ///   - ownerPubkey: The owner's pubkey (z32)
    /// - Returns: The pubky:// URL pointing to the file metadata
    public func uploadProfileImage(_ image: UIImage, ownerPubkey: String) async throws -> String {
        // 1. Resize and compress image
        let resizedImage = resizeImage(image, maxDimension: maxImageSize)
        guard let imageData = resizedImage.jpegData(compressionQuality: jpegQuality) else {
            throw ImageUploadError.compressionFailed
        }
        
        // 2. Generate file ID (timestamp-based, Crockford Base32)
        let fileId = generateTimestampId()
        
        // 3. Upload blob to homeserver
        let blobPath = "/pub/pubky.app/blobs/\(fileId)"
        try await uploadBlob(data: imageData, path: blobPath, contentType: "image/jpeg")
        
        // 4. Create file metadata entry
        let blobUrl = "pubky://\(ownerPubkey)\(blobPath)"
        let fileMetadata = PubkyAppFile(
            name: "profile-image.jpg",
            createdAt: Int64(Date().timeIntervalSince1970 * 1000000), // microseconds
            src: blobUrl,
            contentType: "image/jpeg",
            size: imageData.count
        )
        
        let filePath = "/pub/pubky.app/files/\(fileId)"
        try await uploadFileMetadata(fileMetadata, path: filePath)
        
        // 5. Return the file URL for use in profile
        let fileUrl = "pubky://\(ownerPubkey)\(filePath)"
        Logger.info("Uploaded profile image: \(fileUrl)", context: "ImageUploadService")
        
        return fileUrl
    }
    
    // MARK: - Private Methods
    
    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxSize = max(size.width, size.height)
        
        guard maxSize > maxDimension else {
            return image
        }
        
        let scale = maxDimension / maxSize
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return resizedImage ?? image
    }
    
    /// Generate a timestamp-based ID in Crockford Base32 (13 characters)
    private func generateTimestampId() -> String {
        // Timestamp in microseconds
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        return encodeCrockfordBase32(timestamp)
    }
    
    /// Encode a UInt64 to 13-character Crockford Base32
    private func encodeCrockfordBase32(_ value: UInt64) -> String {
        let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
        var result = ""
        var remaining = value
        
        for _ in 0..<13 {
            let index = Int(remaining & 0x1F)
            let char = alphabet[alphabet.index(alphabet.startIndex, offsetBy: index)]
            result = String(char) + result
            remaining >>= 5
        }
        
        return result
    }
    
    private func uploadBlob(data: Data, path: String, contentType: String) async throws {
        guard let adapter = DirectoryService.shared.getAuthenticatedAdapter() else {
            throw ImageUploadError.notAuthenticated
        }
        
        // Use PubkyStorageAdapter to write the blob
        let result = adapter.putData(path: path, data: data, contentType: contentType)
        
        if !result.success {
            throw ImageUploadError.uploadFailed(result.error ?? "Unknown error")
        }
        
        Logger.debug("Uploaded blob to \(path) (\(data.count) bytes)", context: "ImageUploadService")
    }
    
    private func uploadFileMetadata(_ file: PubkyAppFile, path: String) async throws {
        guard let adapter = DirectoryService.shared.getAuthenticatedAdapter() else {
            throw ImageUploadError.notAuthenticated
        }
        
        let data = try JSONEncoder().encode(file)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw ImageUploadError.encodingFailed
        }
        
        let result = adapter.put(path: path, content: jsonString)
        
        if !result.success {
            throw ImageUploadError.uploadFailed(result.error ?? "Unknown error")
        }
        
        Logger.debug("Uploaded file metadata to \(path)", context: "ImageUploadService")
    }
}

// MARK: - Errors

public enum ImageUploadError: LocalizedError {
    case compressionFailed
    case notAuthenticated
    case uploadFailed(String)
    case encodingFailed
    
    public var errorDescription: String? {
        switch self {
        case .compressionFailed:
            return "Failed to compress image"
        case .notAuthenticated:
            return "Not authenticated to homeserver"
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        case .encodingFailed:
            return "Failed to encode file metadata"
        }
    }
}

