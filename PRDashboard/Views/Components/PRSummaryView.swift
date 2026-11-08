import SwiftUI

struct PRSummaryView: View {
    let readyToMerge: Int
    let changesRequested: Int
    let ciFailing: Int
    let ciRunning: Int
    let toReview: Int

    private struct Segment {
        let icon: String
        let color: Color
        let label: String
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        if readyToMerge > 0 {
            result.append(
                Segment(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    label: String(localized: "\(readyToMerge) ready to merge")
                )
            )
        }
        if changesRequested > 0 {
            result.append(
                Segment(
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    label: String(localized: "\(changesRequested) needs changes")
                )
            )
        }
        if ciFailing > 0 {
            result.append(
                Segment(
                    icon: "xmark.circle.fill",
                    color: .red,
                    label: String(localized: "\(ciFailing) CI failed or unknown")
                )
            )
        }
        if ciRunning > 0 {
            result.append(
                Segment(
                    icon: "clock.circle.fill",
                    color: .orange,
                    label: String(localized: "\(ciRunning) CI running")
                )
            )
        }
        if toReview > 0 {
            result.append(
                Segment(
                    icon: "person.crop.circle.badge.clock",
                    color: .orange,
                    label: String(localized: "\(toReview) to review")
                )
            )
        }
        return result
    }

    var body: some View {
        let items = segments
        SummaryFlowLayout(spacing: 8) {
            if items.isEmpty {
                Label("No summary items", systemImage: "minus.circle")
                    .foregroundColor(.secondary)
                    .accessibilityHint("This summary does not establish whether there is other work to do.")
            } else {
                ForEach(items, id: \.icon) { segment in
                    Label {
                        Text(segment.label)
                            .foregroundColor(.primary)
                    } icon: {
                        Image(systemName: segment.icon)
                            .foregroundColor(segment.color)
                    }
                    .accessibilityElement(children: .combine)
                    .help(summaryExplanation)
                }
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(summaryExplanation)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PR summary")
        .accessibilityHint(summaryExplanation)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var summaryExplanation: String {
        String(localized: "Each count is the number of PRs in the current filter. Categories can overlap. CI failed or unknown includes both failed and unknown CI status. Ready to merge means the configured criteria are met; it does not establish merge permission.")
    }
}

/// Keeps each summary item readable and wraps items instead of squeezing five columns.
private struct SummaryFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity, origin: nil)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        _ = arrange(subviews, width: bounds.width, origin: bounds.origin)
    }

    private func arrange(_ subviews: Subviews, width: CGFloat, origin: CGPoint?) -> CGSize {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let itemProposal = ProposedViewSize(width: width.isFinite ? width : nil, height: nil)
            let size = subview.sizeThatFits(itemProposal)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            if let origin {
                subview.place(at: CGPoint(x: origin.x + x, y: origin.y + y), anchor: .topLeading, proposal: itemProposal)
            }
            usedWidth = max(usedWidth, x + size.width)
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: usedWidth, height: y + lineHeight)
    }
}
