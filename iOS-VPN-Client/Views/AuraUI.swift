import SwiftUI

enum AuraPalette {
    static let midnight = Color(red: 0.04, green: 0.12, blue: 0.22)
    static let ocean = Color(red: 0.06, green: 0.33, blue: 0.48)
    static let aqua = Color(red: 0.10, green: 0.72, blue: 0.65)
    static let ice = Color(red: 0.52, green: 0.91, blue: 0.88)
}

struct AuraScreenBackground: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            LinearGradient(
                colors: [AuraPalette.aqua.opacity(0.09), .clear, AuraPalette.ocean.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

struct AuraSectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(title))
                .font(.headline)
            Spacer()
            if let detail {
                Text(LocalizedStringKey(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AuraEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(AuraPalette.aqua)
            Text(LocalizedStringKey(title))
                .font(.headline)
            Text(LocalizedStringKey(message))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
    }
}

extension View {
    func auraCard(cornerRadius: CGFloat = 22) -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AuraPalette.aqua.opacity(0.12), lineWidth: 1)
            }
    }
}
