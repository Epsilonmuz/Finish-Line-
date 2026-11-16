import SwiftUI

/// Epsilon "precision luxury": near-black, warm gold for live/active things only.
enum Theme {
    static let bg = Color(red: 0.055, green: 0.055, blue: 0.063)
    static let card = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let line = Color.white.opacity(0.08)
    static let gold = Color(red: 0.788, green: 0.659, blue: 0.416)
    static let stop = Color(red: 0.92, green: 0.16, blue: 0.14)
    static let calm = Color(red: 0.55, green: 0.62, blue: 0.70)
    static let dim = Color.white.opacity(0.55)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.5)
            .foregroundStyle(Theme.dim)
    }
}

/// The 4-rung ladder: Planned → Green → Loads → Used.
struct LadderView: View {
    let milestone: Milestone
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Milestone.allCases, id: \.self) { m in
                VStack(spacing: 4) {
                    Capsule()
                        .fill(m <= milestone ? Theme.gold : Color.white.opacity(0.12))
                        .frame(height: 6)
                    Text(m.short)
                        .font(.caption2)
                        .foregroundStyle(m <= milestone ? Theme.gold : Theme.dim)
                }
            }
        }
    }
}
