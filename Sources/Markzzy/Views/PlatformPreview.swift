import SwiftUI

/// Polished UI overlay that mirrors real Instagram Reels and TikTok layouts.
/// Scales with the parent frame so it works both at preview size and full
/// phone-screen size.
struct PlatformChrome: View {
    enum Platform: String, CaseIterable, Identifiable {
        case instagram, tiktok
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .instagram: "Instagram"
            case .tiktok:    "TikTok"
            }
        }
    }

    let platform: Platform

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.height / 640
            Group {
                switch platform {
                case .instagram: InstagramReelsChrome(s: s)
                case .tiktok:    TikTokChrome(s: s)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Instagram Reels chrome

private struct InstagramReelsChrome: View {
    let s: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // Status bar (iOS)
            HStack {
                Text("9:41")
                    .font(.system(size: 12 * s, weight: .semibold))
                Spacer()
                HStack(spacing: 3 * s) {
                    Image(systemName: "dot.radiowaves.right")
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75")
                }
                .font(.system(size: 10 * s))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14 * s)
            .padding(.top, 8 * s)

            // Top nav bar
            HStack {
                Text("Reels")
                    .font(.system(size: 19 * s, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "camera")
                    .font(.system(size: 18 * s, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14 * s)
            .padding(.top, 8 * s)

            Spacer()

            // Bottom bar area (caption left, actions right)
            HStack(alignment: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 6 * s) {
                    HStack(spacing: 6 * s) {
                        // Avatar with gradient ring (story-style)
                        Circle()
                            .fill(
                                AngularGradient(
                                    colors: [
                                        Color(red: 0.95, green: 0.2, blue: 0.5),
                                        Color(red: 0.98, green: 0.6, blue: 0.25),
                                        Color(red: 1.0,  green: 0.85, blue: 0.3),
                                        Color(red: 0.55, green: 0.25, blue: 0.95),
                                        Color(red: 0.95, green: 0.2, blue: 0.5),
                                    ],
                                    center: .center
                                )
                            )
                            .frame(width: 22 * s, height: 22 * s)
                            .overlay(
                                Circle().fill(Color.gray.opacity(0.6))
                                    .padding(2 * s)
                            )
                            .overlay(Circle().stroke(.white, lineWidth: 0.5))

                        Text("username")
                            .font(.system(size: 12 * s, weight: .semibold))
                            .foregroundStyle(.white)

                        Text("• Follow")
                            .font(.system(size: 12 * s, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Text("Caption con #hashtag y algo más... ")
                        .font(.system(size: 11 * s))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    // Audio bar
                    HStack(spacing: 5 * s) {
                        Image(systemName: "music.note")
                            .font(.system(size: 9 * s, weight: .semibold))
                        Text("username · Original audio")
                            .font(.system(size: 10 * s))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                }
                .padding(.leading, 10 * s)
                .padding(.trailing, 4 * s)

                Spacer(minLength: 0)

                // Right action column
                VStack(spacing: 12 * s) {
                    iconStack(symbol: "heart",            count: "1,299")
                    iconStack(symbol: "message",          count: "32")
                    iconStack(symbol: "paperplane",       count: "104")
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18 * s, weight: .semibold))
                        .foregroundStyle(.white)
                    // Small album thumbnail
                    RoundedRectangle(cornerRadius: 3 * s)
                        .fill(.white)
                        .frame(width: 20 * s, height: 20 * s)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3 * s)
                                .stroke(.white, lineWidth: 1.2 * s)
                                .frame(width: 16 * s, height: 16 * s)
                        )
                }
                .padding(.trailing, 10 * s)
            }
            .padding(.bottom, 14 * s)

            // Tab bar
            HStack(spacing: 0) {
                tabBarIcon(systemName: "house")
                Spacer()
                tabBarIcon(systemName: "magnifyingglass")
                Spacer()
                tabBarIcon(systemName: "plus.app")
                Spacer()
                tabBarIcon(systemName: "play.square.stack", active: true)
                Spacer()
                Circle()
                    .fill(Color.gray.opacity(0.8))
                    .frame(width: 18 * s, height: 18 * s)
                    .overlay(Circle().stroke(.white, lineWidth: 1))
            }
            .padding(.horizontal, 22 * s)
            .padding(.top, 6 * s)
            .padding(.bottom, 10 * s)
            .background(Color.black.opacity(0.55))
        }
    }

    private func iconStack(symbol: String, count: String) -> some View {
        VStack(spacing: 2 * s) {
            Image(systemName: symbol)
                .font(.system(size: 20 * s, weight: .regular))
                .foregroundStyle(.white)
            Text(count)
                .font(.system(size: 9 * s, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private func tabBarIcon(systemName: String, active: Bool = false) -> some View {
        Image(systemName: systemName + (active ? ".fill" : ""))
            .font(.system(size: 18 * s))
            .foregroundStyle(.white)
    }
}

// MARK: - TikTok chrome

private struct TikTokChrome: View {
    let s: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            HStack {
                Text("9:41")
                    .font(.system(size: 12 * s, weight: .semibold))
                Spacer()
                HStack(spacing: 3 * s) {
                    Image(systemName: "dot.radiowaves.right")
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75")
                }
                .font(.system(size: 10 * s))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14 * s)
            .padding(.top, 8 * s)

            // Top tabs: Live · Following · For You
            HStack(spacing: 14 * s) {
                Spacer()
                Text("LIVE")
                    .font(.system(size: 12 * s, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text("Following")
                    .font(.system(size: 13 * s, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                VStack(spacing: 2 * s) {
                    Text("For You")
                        .font(.system(size: 14 * s, weight: .bold))
                        .foregroundStyle(.white)
                    Rectangle()
                        .fill(.white)
                        .frame(width: 18 * s, height: 2 * s)
                }
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14 * s, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14 * s)
            .padding(.top, 10 * s)

            Spacer()

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5 * s) {
                    Text("@username")
                        .font(.system(size: 14 * s, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Tu caption · #fyp #markzzy #tech")
                        .font(.system(size: 11 * s))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    HStack(spacing: 5 * s) {
                        Image(systemName: "music.note")
                            .font(.system(size: 10 * s, weight: .semibold))
                        Text("original sound · username")
                            .font(.system(size: 10 * s))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                }
                .padding(.leading, 10 * s)
                .padding(.trailing, 4 * s)

                Spacer(minLength: 0)

                // Right column
                VStack(spacing: 14 * s) {
                    // Avatar with + button (follow)
                    ZStack(alignment: .bottom) {
                        Circle()
                            .fill(Color.gray.opacity(0.8))
                            .frame(width: 36 * s, height: 36 * s)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5 * s))
                        Circle()
                            .fill(Color(red: 1.0, green: 0.2, blue: 0.35))
                            .frame(width: 14 * s, height: 14 * s)
                            .overlay(
                                Image(systemName: "plus")
                                    .font(.system(size: 8 * s, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                            .offset(y: 7 * s)
                    }
                    .padding(.bottom, 4 * s)

                    ttIcon(symbol: "heart.fill",    count: "1.3K")
                    ttIcon(symbol: "message.fill",  count: "32")
                    ttIcon(symbol: "bookmark.fill", count: "102")
                    ttIcon(symbol: "arrowshape.turn.up.right.fill", count: "Share")

                    // Rotating record disc with inner album
                    ZStack {
                        Circle()
                            .fill(
                                AngularGradient(
                                    colors: [.white.opacity(0.15), .white.opacity(0.4), .white.opacity(0.15)],
                                    center: .center
                                )
                            )
                            .frame(width: 34 * s, height: 34 * s)
                        Circle().fill(.black).frame(width: 10 * s, height: 10 * s)
                        Circle().fill(.white).frame(width: 3 * s, height: 3 * s)
                    }
                }
                .padding(.trailing, 8 * s)
            }
            .padding(.bottom, 12 * s)

            // Bottom tab bar
            HStack(spacing: 0) {
                ttTab(icon: "house.fill", label: "Home")
                Spacer()
                ttTab(icon: "person.2.fill", label: "Friends")
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 5 * s)
                        .fill(Color(red: 0.05, green: 0.8, blue: 0.85))
                        .frame(width: 34 * s, height: 24 * s)
                    RoundedRectangle(cornerRadius: 5 * s)
                        .fill(Color(red: 1.0, green: 0.2, blue: 0.35))
                        .frame(width: 34 * s, height: 24 * s)
                        .offset(x: 4 * s)
                    RoundedRectangle(cornerRadius: 5 * s)
                        .fill(.white)
                        .frame(width: 30 * s, height: 22 * s)
                    Image(systemName: "plus")
                        .font(.system(size: 11 * s, weight: .bold))
                        .foregroundStyle(.black)
                }
                Spacer()
                ttTab(icon: "tray.fill", label: "Inbox")
                Spacer()
                ttTab(icon: "person.crop.circle.fill", label: "Profile")
            }
            .padding(.horizontal, 18 * s)
            .padding(.top, 6 * s)
            .padding(.bottom, 10 * s)
            .background(Color.black.opacity(0.55))
        }
    }

    private func ttIcon(symbol: String, count: String) -> some View {
        VStack(spacing: 2 * s) {
            Image(systemName: symbol)
                .font(.system(size: 22 * s, weight: .regular))
                .foregroundStyle(.white)
            Text(count)
                .font(.system(size: 10 * s, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private func ttTab(icon: String, label: String) -> some View {
        VStack(spacing: 2 * s) {
            Image(systemName: icon)
                .font(.system(size: 14 * s))
            Text(label).font(.system(size: 9 * s, weight: .medium))
        }
        .foregroundStyle(.white)
    }
}
