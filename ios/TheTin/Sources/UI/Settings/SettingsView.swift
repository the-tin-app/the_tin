import SwiftUI
import UniformTypeIdentifiers

/// Settings sheet. Shows app version, live connection status to the self-hosted server and the
/// Firebase backup, the data-tier picker (with per-tier contents + download size), plus the
/// existing Support / Data / Storage sections.
struct SettingsView: View {
    @Bindable var app: AppModel
    let pack: ScannerPackModel
    @State private var model = SettingsModel()
    @State private var confirmingClear = false
    @State private var confirmingPackDelete = false
    @State private var confirmingPackCellular = false
    @State private var restoreCandidate: BackupSnapshot?
    @State private var confirmingRestore = false
    @State private var restoreError: String?
    @State private var exportDoc: CSVDocument?
    @State private var importing = false
    @State private var importSummary: ImportSummary?
    @State private var importError: String?
    @State private var importInFlight = false
    @State private var showingReport = false
    @AppStorage(SheetPDF.contactLineKey) private var contactLine = ""
    @Environment(\.dismiss) private var dismiss

    private var funding: FundingDisplay { app.funding }

    /// Split out of `body`: with the scanner-pack section added, one ten-section `List` literal
    /// tipped the type-checker into "unable to type-check this expression in reasonable time".
    @ViewBuilder private var sections: some View {
        appSection
        connectionSection
        tierSection
        scannerPackSection
        activitySection
        alertsSection
        supportSection
        dataSection
        printoutSection
        storageSection
    }

    var body: some View {
        NavigationStack {
            List {
                sections
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await model.refresh()
                await model.probeConnections(app: app)
                await app.backup?.refreshStatus()
            }
            .confirmationDialog("Clear all cached card images?",
                                isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { Task { await model.clear() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Images will re-download as you view cards.")
            }
            .confirmationDialog("Delete the scanner pack?", isPresented: $confirmingPackDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { pack.deletePack() }
                Button("Cancel", role: .cancel) {}
            } message: {
                // Naming what is NOT lost matters more than naming what is: people assume
                // deleting anything in a collection app deletes their collection.
                Text("Camera scanning stops working until you download it again. Your collection isn't affected.")
            }
            .confirmationDialog("Download over cellular?", isPresented: $confirmingPackCellular,
                                titleVisibility: .visible) {
                Button("Download now") { pack.startDownload(allowingExpensive: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You're not on Wi-Fi. This may count against your data plan — you can pause and resume anytime.")
            }
            .confirmationDialog(manualRestoreTitle, isPresented: $confirmingRestore,
                                titleVisibility: .visible) {
                Button("Replace collection", role: .destructive) {
                    guard let backup = app.backup, let snapshot = restoreCandidate else { return }
                    Task {
                        do { try await backup.performRestore(snapshot: snapshot) }
                        catch { restoreError = error.localizedDescription }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This replaces everything currently in The Tin with the backup.")
            }
            .alert("Restore failed", isPresented: restoreErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(restoreError ?? "")
            }
            .fileExporter(isPresented: Binding(get: { exportDoc != nil },
                                               set: { if !$0 { exportDoc = nil } }),
                          document: exportDoc, contentType: .commaSeparatedText,
                          defaultFilename: CollectionCSV.filename("the-tin-collection")) { _ in
                exportDoc = nil
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                Task { await runImport(result) }
            }
            .sheet(item: $importSummary) { ImportResultSheet(summary: $0) }
            .alert("Import failed", isPresented: Binding(get: { importError != nil },
                                                         set: { if !$0 { importError = nil } })) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .modifier(OptionalCollectionReportFlow(isActive: $showingReport,
                                                    collection: app.collection, store: app.store))
        }
    }

    // MARK: App

    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system

    private var appSection: some View {
        Section("App") {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.label) }
            }
            LabeledContent("Version", value: Self.appVersion)
        }
    }

    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section {
            StatusRow(title: "Self-hosted", systemImage: "server.rack",
                      ok: model.connection.map { $0.selfHostAlive && $0.selfHostAuthOK },
                      detail: selfHostDetail)
            StatusRow(title: "Backup (Firebase)", systemImage: "externaldrive.badge.icloud",
                      ok: model.connection.map { $0.firebaseReachable }, detail: firebaseDetail)
            LabeledContent("Active source", value: activeSourceText)
        } header: {
            HStack {
                Text("Connection")
                Spacer()
                if model.probing {
                    ProgressView()
                } else {
                    Button("Refresh") { Task { await model.probeConnections(app: app) } }
                        .font(.caption).textCase(nil)
                }
            }
        } footer: {
            if onBackupSource {
                Text("The backup source only provides the Small catalog (latest prices, no history). Anything richer you already downloaded stays available on this device.")
            }
        }
    }

    /// True when catalog data is coming from the Firebase backup instead of the self-hosted
    /// server — either the last update actually fell back, or the probe shows auth failing.
    private var onBackupSource: Bool {
        if app.activeSource == .firebase { return true }
        if let c = model.connection { return c.selfHostConfigured && !c.selfHostAuthOK }
        return false
    }

    private var selfHostDetail: String {
        guard let c = model.connection else { return "…" }
        guard c.selfHostAlive else { return "Unreachable" }
        var parts: [String] = []
        if let ms = c.selfHostLatencyMs { parts.append("\(ms) ms") }
        parts.append(c.selfHostAuthOK ? Self.versionText(c.selfHostVersion) : "auth failed — using backup")
        return parts.joined(separator: " · ")
    }

    private var firebaseDetail: String {
        guard let c = model.connection else { return "…" }
        return c.firebaseReachable ? Self.versionText(c.firebaseVersion) : "Unreachable"
    }

    private var activeSourceText: String {
        switch app.activeSource {
        case .selfHosted: return "Self-hosted"
        case .firebase: return "Backup (Firebase)"
        case nil: return "—"
        }
    }

    private static func versionText(_ v: Int?) -> String { v.map { "v\($0)" } ?? "Reachable" }

    // MARK: Data tier

    private var tierSection: some View {
        Section {
            ForEach(CatalogTier.allCases) { tier in
                Button { Task { await app.setTier(tier) } } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tier.title)
                            Text(tier.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 2) {
                            if tier.rawValue == app.currentTier {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                            if let sz = model.connection?.tierSizes[tier.rawValue] {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .file))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(app.tierChange == .downloading)
            }
        } header: {
            Text("Catalog download")
        } footer: {
            tierFooter
        }
    }

    @ViewBuilder private var tierFooter: some View {
        switch app.tierChange {
        case .downloading:
            HStack(spacing: 6) { ProgressView(); Text("Switching catalog…") }
        case .done:
            Text("Downloaded. Restart The Tin to finish switching.")
        case .failed(let msg):
            Text(msg).foregroundStyle(.red)
        case .idle:
            if onBackupSource {
                Text("On the backup source only the Small catalog can download.\(installedTierNote)")
            } else {
                Text("Just a download-size choice — every option is free. Change it anytime.")
            }
        }
    }

    /// " Currently installed: Casual." when the on-device data doesn't match the picked tier.
    private var installedTierNote: String {
        guard let installed = app.catalogState?.tier, installed != app.currentTier else { return "" }
        return " Currently installed: \(CatalogTier(rawValue: installed)?.title ?? installed)."
    }

    // MARK: Scanner pack

    /// The scanner pack's own section: start it here instead of only from the Scan tab, watch a
    /// transfer that was started anywhere, and — the part that had no home at all — give the disk
    /// space back once you've finished cataloguing.
    private var scannerPackSection: some View {
        Section {
            switch pack.phase {
            case .checking:
                HStack(spacing: 6) { ProgressView(); Text("Checking…") }
            case .notInstalled:
                LabeledContent("Camera scanning", value: "Not set up")
                Button("Download scanner pack") {
                    if app.network.isExpensive { confirmingPackCellular = true } else { pack.startDownload() }
                }
            case .downloading(let p):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: p.fraction)
                    Text(p.byteSummary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button("Pause") { pack.pause() }
            case .paused(let p, let reason):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: p.fraction)
                    Text("Paused — \(p.byteSummary)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button(reason == .cellular ? "Resume anyway" : "Resume") {
                    pack.startDownload(allowingExpensive: reason == .cellular)
                }
                Button("Discard partial download", role: .destructive) { pack.discardPartialDownload() }
            case .ready:
                LabeledContent("Scanner pack", value: installedPackText)
                if pack.updateAvailable {
                    Button("Update scanner pack") {
                        if app.network.isExpensive { confirmingPackCellular = true } else { pack.startDownload() }
                    }
                }
                Button("Delete scanner pack", role: .destructive) { confirmingPackDelete = true }
            case .unavailable(let msg):
                LabeledContent("Camera scanning", value: "Unavailable")
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Connection", value: app.network.connectionDescription)
        } header: {
            Text("Camera scanning")
        } footer: {
            scannerPackFooter
        }
    }

    @ViewBuilder private var scannerPackFooter: some View {
        switch pack.phase {
        case .ready where pack.updateAvailable:
            Text("A newer scanner pack is available. The one you have keeps working until you update.")
        case .ready:
            Text("Used to identify cards from the camera. Deleting it frees the space and leaves your collection untouched.")
        case .paused(_, .cellular):
            Text("Paused automatically because you're not on Wi-Fi. Your progress is saved either way.")
        default:
            Text("Lets The Tin identify a card from your camera, offline. One-time download; you can pause and resume it.")
        }
    }

    private var installedPackText: String {
        let version = pack.installedVersion.map { "v\($0)" }
        let size = pack.installedBytes.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
        return [version, size].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Catalog activity

    /// Breadcrumb trail of recent catalog operations (source, outcome, failures) — the on-device
    /// answer to "why does my data look wrong", collapsed behind a DisclosureGroup.
    private var activitySection: some View {
        Section {
            DisclosureGroup("Catalog activity") {
                let lines = CatalogActivity.read()
                if lines.isEmpty {
                    Text("No catalog updates recorded yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(lines.prefix(20), id: \.self) { line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(line.contains("failed") || line.contains("FAILED")
                                             ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                }
            }
        }
    }

    // MARK: Wishlist price alerts

    private var alertsSection: some View {
        Section {
            Toggle("Wishlist price alerts", isOn: Binding(
                get: { model.alertsEnabled },
                set: { on in Task { await model.setAlertsEnabled(on) } }))
            if model.alertsEnabled {
                Picker("Sensitivity", selection: Binding(
                    get: { model.alertSensitivityPct },
                    set: { model.setAlertSensitivity($0) })) {
                    Text("5%").tag(5)
                    Text("10%").tag(10)
                    Text("20%").tag(20)
                }
            }
        } header: {
            Text("Alerts")
        } footer: {
            if model.alertsDenied {
                Text("Notifications are off for The Tin. Enable them in iOS Settings to get price alerts.")
            } else {
                // Target hits are named explicitly: they don't obey the sensitivity picker above
                // it, and a target you set months ago is the one alert here you're actually
                // waiting for.
                Text("Get notified when a wishlist card drops to the target price you set, or when its price moves by the amount above. Alerts arrive when new prices download — not real-time.")
            }
        }
    }

    // MARK: CSV export / import

    /// Snapshot the main-actor model state, then build the CSV off the main actor —
    /// mirrors `runImport`, so a 20k-entry export can't freeze the UI either.
    private func makeExportDocument() async -> CSVDocument? {
        guard let collection = app.collection, let store = app.store else { return nil }
        // `allEntries`: an export is the whole file. Using the owned-only list would drop every
        // sold copy — the one place a silent omission looks exactly like a successful backup.
        let entries = collection.allEntries
        let groups = collection.groups
        let prices = collection.prices
        let variantsByCard = collection.variantsByCard
        let conditionsByCard = collection.conditionsByCard
        let matrixByCard = collection.matrixByCard
        let gradedByPrintingByCard = collection.gradedByPrintingByCard
        return await Task.detached {
            let ids = Array(Set(entries.map(\.cardId)))
            let cards = Dictionary(uniqueKeysWithValues: ((try? store.cards(ids: ids)) ?? []).map { ($0.id, $0) })
            let sets = Dictionary(uniqueKeysWithValues: ((try? store.sets()) ?? []).map { ($0.id, $0) })
            return CSVDocument(data: CollectionCSV.export(
                entries: entries, groups: groups, cards: cards, sets: sets,
                prices: prices, variantsByCard: variantsByCard,
                conditionsByCard: conditionsByCard,
                matrixByCard: matrixByCard,
                gradedByPrintingByCard: gradedByPrintingByCard))
        }.value
    }

    private func runImport(_ picked: Result<URL, Error>) async {
        guard !importInFlight else { return }   // buttons are disabled while in flight; belt+suspenders
        guard let collection = app.collection, let store = app.store else { return }
        importInFlight = true
        defer { importInFlight = false }
        do {
            let url = try picked.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // File read + CSV parse + catalog matching (up to 20k rows) is real work — keep it
            // off the main actor so the UI doesn't freeze on a large import.
            let result = try await Task.detached {
                // UTF-8 only by design — Dex's UTF-16 exports are out of scope (spec).
                let text = try String(contentsOf: url, encoding: .utf8)
                return try CollectionCSVImport.importCSV(text, matcher: CardMatcher(store: store))
            }.value
            if !result.entries.isEmpty {
                // Append-only: everything lands in a fresh divider ("Imported Jul 14");
                // the user re-files from there. A re-import just makes a second divider.
                let divider = "Imported \(Date().formatted(.dateTime.month(.abbreviated).day()))"
                let groupId = await collection.createGroup(name: divider)
                let entries = result.entries.map { entry -> CollectionEntry in
                    var entry = entry
                    entry.groupId = groupId
                    return entry
                }
                await collection.addEntries(entries)
            }
            var skippedURL: URL?
            if !result.skipped.isEmpty {
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("skipped-rows.csv")
                try CollectionCSVImport.skippedRowsCSV(result).write(to: out)
                skippedURL = out
            }
            importSummary = ImportSummary(text: "\(result.formatName): \(result.summary)",
                                          experimental: result.experimental,
                                          skippedURL: skippedURL)
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: Existing sections

    private var supportSection: some View {
        Section("Support") {
            VStack(alignment: .leading, spacing: 8) {
                Text("The Tin is free and works offline. Chip in to help cover the price-data and hosting costs — nothing is locked either way.")
                    .font(.footnote).foregroundStyle(.secondary)
                if FundingModel.isLive {
                    FundedMeter(fundedPct: funding.fundedPct)
                    Text("\(FundingModel.dollars(funding.raisedCents)) of \(FundingModel.dollars(funding.monthlyGoalCents)) per month")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Community funding is almost ready — coming soon!")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            if FundingModel.isLive {
                Link("Support on Open Collective", destination: AppConfig.supportURL)
            }
        }
    }

    private var dataSection: some View {
        Section("Data") {
            LabeledContent("Card catalog", value: model.catalogText)
            Button("Collection report (PDF)") { showingReport = true }
                .disabled(app.collection?.entries.isEmpty ?? true)
            Button {
                Task { exportDoc = await makeExportDocument() }
            } label: {
                Label("Export collection (CSV)", systemImage: "square.and.arrow.up")
            }
            .disabled(app.collection == nil || app.store == nil || importInFlight)
            Button {
                importing = true
            } label: {
                Label("Import collection (CSV)…", systemImage: "square.and.arrow.down")
            }
            .disabled(app.collection == nil || app.store == nil || importInFlight)
            if importInFlight {
                HStack(spacing: 6) { ProgressView(); Text("Importing…") }
            }
            if let backup = app.backup {
                LabeledContent("iCloud Backup", value: Self.backupStatusText(backup.status))
                Button("Back Up Now") { Task { await backup.backUpNow() } }
                Button("Restore from backup…") { Task { await prepareManualRestore(backup) } }
            }
        }
    }

    private static func backupStatusText(_ status: BackupService.Status) -> String {
        switch status {
        case .unknown: return "No backup yet"
        case .unavailable: return "iCloud unavailable"
        case .backedUp(let date):
            return "Backed up \(date.formatted(date: .abbreviated, time: .shortened))"
        case .failed: return "Last backup failed"
        }
    }

    /// Load the backup before confirming, so the dialog can show its entry count and date.
    /// Errors (unavailable / missing / undecodable) surface in the failure alert.
    private func prepareManualRestore(_ backup: BackupService) async {
        do {
            restoreCandidate = try await backup.loadBackup()
            confirmingRestore = true
        } catch {
            restoreError = error.localizedDescription
        }
    }

    private var manualRestoreTitle: String {
        guard let c = restoreCandidate else { return "Restore from backup?" }
        return "Restore \(c.entries.count) cards from \(c.exportedAt.formatted(date: .abbreviated, time: .omitted))?"
    }

    private var restoreErrorBinding: Binding<Bool> {
        Binding(get: { restoreError != nil }, set: { if !$0 { restoreError = nil } })
    }

    private var printoutSection: some View {
        Section {
            TextField("Name or handle", text: $contactLine)
                .autocorrectionDisabled()
        } header: {
            Text("Printout contact line")
        } footer: {
            Text("Shown in the header of printed trade sheets, want lists, and collection reports. Leave empty to omit.")
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            LabeledContent("Cached images", value: model.sizeText)
            Button("Clear image cache", role: .destructive) { confirmingClear = true }
        }
    }
}

/// One backend's reachability: label, one-line detail, and a colored dot (gray until probed).
private struct StatusRow: View {
    let title: String
    let systemImage: String
    let ok: Bool?
    let detail: String

    var body: some View {
        HStack {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 24)
            Text(title)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Circle().fill(dotColor).frame(width: 9, height: 9)
        }
    }

    private var dotColor: Color {
        switch ok {
        case .some(true): return .green
        case .some(false): return .red
        case nil: return .gray
        }
    }
}

/// Import outcome for the result sheet: headline, experimental-format tag, skipped-rows file.
struct ImportSummary: Identifiable {
    let id = UUID()
    let text: String
    let experimental: Bool
    let skippedURL: URL?
}

private struct ImportResultSheet: View {
    let summary: ImportSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Text(summary.text)
                if summary.experimental {
                    Label("This format's support is experimental — double-check the imported cards.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let url = summary.skippedURL {
                    ShareLink("Share skipped rows (CSV)", item: url)
                }
            }
            .navigationTitle("Import complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}

/// `collectionReportFlow` needs non-optional `CollectionModel`/`CatalogStore`; at Settings' top
/// level (`SettingsView.body`) `AppModel`'s `collection`/`store` are still optional. No-ops when
/// either is nil, so the flow is attached to the whole screen (matching CollectionView) instead
/// of a single row button — the flow's progress UI is an `.overlay` and sizes to whatever it's
/// attached to.
private struct OptionalCollectionReportFlow: ViewModifier {
    @Binding var isActive: Bool
    let collection: CollectionModel?
    let store: CatalogStore?

    func body(content: Content) -> some View {
        if let collection, let store {
            content.collectionReportFlow(isActive: $isActive, collection: collection, store: store)
        } else {
            content
        }
    }
}
