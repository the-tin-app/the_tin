import SwiftUI

/// Capture on top, results below.
///
/// ⚠️ Both stay in the hierarchy at all times. A `switch`/`if` between "camera" and "results"
/// would be two `_ConditionalContent` identities and would tear the AVCapture session down and
/// restart it on every state change — a 3–5 s white screen, already shipped once in
/// `ScanTabContainer`. Only the results section's CONTENT changes; the photo overlay is a sheet
/// over the top, so the preview underneath is never removed.
///
/// Read-only by construction: nothing on this screen writes to the collection, and nothing here
/// is persisted.
struct LensView: View {
    @Bindable var model: LensModel
    let source: LensPhotoSource
    @State private var showing: LensRow?

    var body: some View {
        VStack(spacing: 0) {
            CameraPreview(session: source.session)
                .frame(height: 260)
                .overlay(alignment: .bottom) { shutter }
                .clipped()

            List {
                Section {
                    resultsContent
                } header: {
                    Text(model.wishlistHitCount > 0
                         ? "^[\(model.wishlistHitCount) card](inflect: true) from your wishlist"
                         : "Results")
                } footer: {
                    // Failures are stated, never hidden — a silent miss makes the user distrust
                    // the answers the lens DID get right.
                    if let note = failureNote { Text(note) }
                }
            }
            .listStyle(.plain)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Only my wishlist", isOn: $model.filter.wishlistOnly)
                    Toggle("Hide what I own", isOn: $model.filter.hideOwned)
                    Button("Clear", role: .destructive) { model.reset() }
                } label: {
                    // ⚠️ .labelStyle(.titleAndIcon) is silently IGNORED in the toolbar — it would
                    // render icon-only anyway. An explicit label is the only way to show words.
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter results")
            }
        }
        // ⚠️ `start()` is async and MUST be awaited before the first `capture()` —
        // `capturePhoto` against a session that has not started throws inside AVFoundation.
        .task { await source.start() }
        .onDisappear { source.stop() }
        .sheet(item: $showing) { row in
            NavigationStack {
                photoSheet(row)
                    .navigationTitle(row.name ?? "Where it is")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showing = nil }
                        }
                    }
            }
        }
    }

    @ViewBuilder private var resultsContent: some View {
        if model.rows.isEmpty {
            Text(model.isWorking
                 ? "Reading…"
                 : "Take a photo of the cards in front of you. Nothing is added to your tin.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(model.rows) { row in
                Button { showing = row } label: { LensRowView(row: row) }
                    .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func photoSheet(_ row: LensRow) -> some View {
        if let image = model.images[row.photoId] {
            LensPhotoOverlay(image: image, cells: model.photos[row.photoId] ?? [],
                             highlighted: row.id)
                .padding()
        } else {
            ContentUnavailableView("Photo unavailable", systemImage: "photo")
        }
    }

    /// One honest line covering both kinds of miss. Unreadable cards name their reason; cards that
    /// were read but not recognised are counted separately, because "we couldn't see it" and "we
    /// saw it and don't know it" are different answers.
    private var failureNote: String? {
        var parts: [String] = []
        let reasons = model.unreadableReasons
        if !reasons.isEmpty {
            let why = Set(reasons).sorted().joined(separator: ", ")
            parts.append("^[\(reasons.count) card](inflect: true) couldn't be read — \(why).")
        }
        if model.unidentifiedCount > 0 {
            parts.append("^[\(model.unidentifiedCount) card](inflect: true) wasn't recognised.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var shutter: some View {
        Button {
            Task { await model.shoot() }
        } label: {
            Circle().strokeBorder(.white, lineWidth: 4).frame(width: 62, height: 62)
                .background(Circle().fill(.white.opacity(0.25)))
        }
        .padding(.bottom, 12)
        .disabled(!source.isAvailable)
        .accessibilityLabel("Take a photo")
    }
}

/// ⚠️ Reads everything off `row`. It must NEVER query the catalog: a synchronous GRDB read inside
/// a `List` row's `body` is re-run on every render of every visible row, which is the same class
/// of mistake as the twelve synchronous reads that used to sit in `CardDetailModel.init`.
/// ⚠️ Never name a variant here either — a photo cannot tell a reverse holo from a regular one,
/// so no printing-specific claim (price included) may be made.
private struct LensRowView: View {
    let row: LensRow

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name ?? row.cardId)
                if row.onWishlist {
                    Text("On your wishlist").font(.caption).foregroundStyle(Color.accentColor)
                } else if row.owned {
                    Text("Already in your tin").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let price = row.priceUsd {
                Text(price, format: .currency(code: "USD")).monospacedDigit()
            }
        }
        .contentShape(Rectangle())
    }
}
