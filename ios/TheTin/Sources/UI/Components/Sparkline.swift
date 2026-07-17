import SwiftUI
import Charts

/// Bare-axes price trend line with a soft area fill — a glanceable shape, not a chart to read.
/// Shared by the pager's card pages and the divider landing's performance row.
struct Sparkline: View {
    let points: [PricePoint]
    var color: Color

    var body: some View {
        Chart(points) { p in
            AreaMark(x: .value("Date", p.date), y: .value("USD", p.value))
                .foregroundStyle(.linearGradient(colors: [color.opacity(0.3), .clear],
                                                 startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Date", p.date), y: .value("USD", p.value))
                .foregroundStyle(color)
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
    }
}
