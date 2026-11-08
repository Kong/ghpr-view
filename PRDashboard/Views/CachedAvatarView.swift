import SwiftUI

private struct AllowsRemoteAvatarsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var allowsRemoteAvatars: Bool {
        get { self[AllowsRemoteAvatarsKey.self] }
        set { self[AllowsRemoteAvatarsKey.self] = newValue }
    }
}

struct CachedAvatarView: View {
    let url: URL?
    let authorInitial: String

    @State private var image: NSImage?
    @Environment(\.allowsRemoteAvatars) private var allowsRemoteAvatars

    var body: some View {
        Group {
            if allowsRemoteAvatars, let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                initialsView
            }
        }
        .task(id: AvatarRequest(url: url, allowed: allowsRemoteAvatars)) {
            image = nil
            guard allowsRemoteAvatars, let url else { return }
            let loaded = await AvatarCache.shared.avatar(for: url)
            guard !Task.isCancelled, allowsRemoteAvatars else { return }
            image = loaded
        }
        .onChange(of: allowsRemoteAvatars) { allowed in
            if !allowed { image = nil }
        }
    }

    private struct AvatarRequest: Equatable {
        let url: URL?
        let allowed: Bool
    }

    private var initialsView: some View {
        ZStack {
            Circle()
                .fill(Color.gray.opacity(0.3))
            Text(String(authorInitial.prefix(1)).uppercased())
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
        }
    }
}

#if DEBUG
struct CachedAvatarView_Previews: PreviewProvider {
    static var previews: some View {
        CachedAvatarView(
            url: URL(string: "https://avatars.githubusercontent.com/u/1?v=4"),
            authorInitial: "X"
        )
        .frame(width: 32, height: 32)
        .clipShape(Circle())
    }
}
#endif
