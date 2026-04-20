import SwiftUI

/// Brand mark that mirrors the Markzzy app icon: slanted bold "M" with a
/// record-button dot (white ring + blue core) nested in the lower-right.
struct LogoMark: View {
    var size: CGFloat = 18
    var showBackground: Bool = true

    var body: some View {
        ZStack {
            if showBackground {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.07, green: 0.13, blue: 0.27),
                                Color(red: 0.02, green: 0.05, blue: 0.12),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            // "M" glyph — italic, heavy weight; nudged left to compensate the slant.
            Text("M")
                .font(.system(size: size * 0.68, weight: .black, design: .default))
                .italic()
                .foregroundStyle(showBackground ? Color.white : Color.primary)
                .offset(x: -size * 0.035, y: 0)

            // REC indicator — crisp red dot tucked above the M's right arm.
            Circle()
                .fill(Color(red: 1.0, green: 0.25, blue: 0.30))
                .frame(width: size * 0.16, height: size * 0.16)
                .shadow(color: Color(red: 1.0, green: 0.25, blue: 0.30).opacity(0.6), radius: size * 0.02)
                .offset(x: size * 0.34, y: -size * 0.19)
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    HStack(spacing: 12) {
        LogoMark(size: 16)
        LogoMark(size: 32)
        LogoMark(size: 64)
        LogoMark(size: 128)
    }
    .padding()
    .background(Color.gray.opacity(0.2))
}
