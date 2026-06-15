import SwiftUI
import AppKit

/// The configurable "break the scoped fleet down by <attribute>" chart
/// from the dashboard summary, each bar drillable to its devices. Owns its
/// own expanded-bucket state so expanding a bar doesn't re-render the rest
/// of the dashboard.
struct PrismChart: View {
    /// Devices in scope (a smart group's members, or everything).
    let devices: [MDMEnrollment]
    let facts: DashboardFacts
    @Binding var attribute: PrismView.Attribute
    /// Called when the operator changes the attribute, so the parent can
    /// clear its "active saved view" highlight.
    let onAttributeChange: () -> Void

    @State private var prismBucket: String?

    var body: some View {
        let buckets = prismBuckets()
        let maxCount = max(1, buckets.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Breakdown", systemImage: attribute.icon).font(.headline)
                Spacer()
                Picker("", selection: $attribute) {
                    ForEach(PrismView.Attribute.allCases) { a in
                        Label(a.rawValue, systemImage: a.icon).tag(a)
                    }
                }
                .labelsHidden().frame(maxWidth: 200)
                .onChange(of: attribute) { _, _ in prismBucket = nil; onAttributeChange() }
            }
            ForEach(buckets, id: \.label) { row in
                Button { prismBucket = (prismBucket == row.label) ? nil : row.label } label: {
                    HStack(spacing: 8) {
                        Text(row.label).font(.caption).frame(width: 150, alignment: .leading)
                            .lineLimit(1).truncationMode(.middle)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.accentColor.opacity(0.15))
                                Capsule().fill(Color.accentColor.opacity(prismBucket == row.label ? 0.95 : 0.7))
                                    .frame(width: max(6, geo.size.width * CGFloat(row.count) / CGFloat(maxCount)))
                            }
                        }
                        .frame(height: 16)
                        Text("\(row.count)").font(.caption.monospacedDigit()).frame(width: 32, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let b = prismBucket {
                let matches = devicesInBucket(b)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(b) — \(matches.count) device\(matches.count == 1 ? "" : "s")")
                        .font(.caption.bold())
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
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }

    private func prismBuckets() -> [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for d in devices { counts[facts.bucket(for: d, attribute: attribute), default: 0] += 1 }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { (label: $0.key, count: $0.value) }
    }

    private func devicesInBucket(_ b: String) -> [MDMEnrollment] {
        devices.filter { facts.bucket(for: $0, attribute: attribute) == b }
    }
}
