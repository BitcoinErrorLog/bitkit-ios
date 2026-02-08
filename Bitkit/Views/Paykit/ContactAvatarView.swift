import SwiftUI
import UIKit

struct ContactAvatarView: View {
    let name: String
    let avatarUrl: String?
    let size: CGFloat

    @State private var image: UIImage?
    @State private var isLoading = false

    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.brandAccent.opacity(0.2))

            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Text(initials)
                    .foregroundColor(.brandAccent)
                    .font(Fonts.semiBold(size: size * 0.45))
            }
        }
        .frame(width: size, height: size)
        .task(id: avatarUrl) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        guard let url = avatarUrl, !url.isEmpty else {
            image = nil
            return
        }

        if let cached = Self.cache.object(forKey: url as NSString) {
            image = cached
            return
        }

        if isLoading {
            return
        }

        isLoading = true
        defer { isLoading = false }

        var loaded: UIImage?
        if url.hasPrefix("pubky://") {
            loaded = await ImageUploadService.shared.downloadProfileImage(fileUrl: url)
        } else if let httpUrl = URL(string: url) {
            do {
                let (data, _) = try await URLSession.shared.data(from: httpUrl)
                loaded = UIImage(data: data)
            } catch {
                loaded = nil
            }
        }

        if let loaded = loaded {
            Self.cache.setObject(loaded, forKey: url as NSString)
        }

        image = loaded
    }

    private var initials: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "?" : String(trimmed.prefix(1))
        return source.uppercased()
    }
}
