import SwiftUI
import AppKit

/// The dashboard "Breakdown" card — shows the scoped fleet broken down by
/// every attribute at once (macOS version, model, FileVault, …), each bucket
/// a compact, drillable bar. No attribute picker: it's an at-a-glance overview,
/// so all dimensions are visible. Owns its own drill state so opening a bucket
/// doesn't re-render the rest of the dashboard.
struct PrismChart: View {
    /// Devices in scope (a smart group's members, or everything).
    let devices: [MDMEnrollment]
    let facts: DashboardFacts

    @State private var selected: BucketKey?

    /// Bucket identity is attribute + label, since two attributes can share a
    /// label (e.g. "Not reported").
    private struct BucketKey: Hashable {
        let attribute: PrismView.Attribute
        let label: String
    }

    /// Compact bar track width — fixed so bars stay short and comparable
    /// instead of stretching across the whole pane.
    private let barWidth: CGFloat = 240
    private let labelWidth: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Breakdown", systemImage: "chart.bar.xaxis").font(.headline)
            ForEach(PrismView.Attribute.allCases) { attr in
                attributeGroup(attr)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }

    @ViewBuilder
    private func attributeGroup(_ attr: PrismView.Attribute) -> some View {
        let buckets = buckets(for: attr)
        let maxCount = max(1, buckets.map(\.count).max() ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            Label(attr.rawValue, systemImage: attr.icon)
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(buckets, id: \.label) { row in
                let key = BucketKey(attribute: attr, label: row.label)
                let isSel = selected == key
                VStack(alignment: .leading, spacing: 4) {
                    Button { selected = isSel ? nil : key } label: {
                        HStack(spacing: 10) {
                            Text(row.label).font(.caption)
                                .frame(width: labelWidth, alignment: .leading)
                                .lineLimit(1).truncationMode(.middle)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.accentColor.opacity(0.12))
                                    .frame(width: barWidth, height: 14)
                                Capsule().fill(Color.accentColor.opacity(isSel ? 0.95 : 0.6))
                                    .frame(width: max(6, barWidth * CGFloat(row.count) / CGFloat(maxCount)), height: 14)
                            }
                            Text("\(row.count)").font(.caption.monospacedDigit())
                                .frame(width: 28, alignment: .trailing)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isSel ? "Hide devices" : "Show the \(row.count) device\(row.count == 1 ? "" : "s") here")

                    if isSel { drillList(attr, label: row.label) }
                }
            }
        }
    }

    @ViewBuilder
    private func drillList(_ attr: PrismView.Attribute, label: String) -> some View {
        let matches = devicesInBucket(attr, label)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(matches, id: \.id) { d in
                HStack(spacing: 6) {
                    Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                    Text(facts.label(for: d)).font(.caption)
                    Spacer()
                    if let os = facts.osVersions[d.id] {
                        Text("macOS \(os)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.06)))
        .padding(.leading, labelWidth + 10)
        .padding(.bottom, 2)
    }

    private func buckets(for attr: PrismView.Attribute) -> [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for d in devices { counts[facts.bucket(for: d, attribute: attr), default: 0] += 1 }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { (label: $0.key, count: $0.value) }
    }

    private func devicesInBucket(_ attr: PrismView.Attribute, _ label: String) -> [MDMEnrollment] {
        devices.filter { facts.bucket(for: $0, attribute: attr) == label }
    }
}
