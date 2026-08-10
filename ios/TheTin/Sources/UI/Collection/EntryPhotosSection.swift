import PhotosUI
import SwiftUI

/// The photo tiles on the entry form: Front · Back · then the detail shots.
///
/// Photos are written to disk at CAPTURE time, not at Save — the tile has to show the image
/// immediately and the form may stay open for a while. Cancelling the form therefore leaves an
/// orphan directory, which `PhotoStore.prune(keeping:)` clears at the next launch.
///
/// Detail tiles render as "however many exist, plus one empty tile if under the cap", so a tap
/// can only ever APPEND. That is what keeps `EntryPhotos.details` dense — a fixed pair of detail
/// tiles would let someone fill the second while the first is empty.
struct EntryPhotosSection: View {
    let entryId: String
    @Binding var photos: EntryPhotos
    var photoStore: PhotoStore = .live()

    @State private var target: EntryPhotos.Slot?
    @State private var choosingSource = false
    @State private var showingCamera = false
    @State private var showingLibrary = false
    @State private var pickerItem: PhotosPickerItem?

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    /// Front, back, every detail that exists, and one empty detail tile while under the cap.
    private var slots: [EntryPhotos.Slot] {
        var out: [EntryPhotos.Slot] = [.front, .back]
        out += (0..<photos.details.count).map { EntryPhotos.Slot.detail($0) }
        if photos.details.count < EntryPhotos.maxDetails {
            out.append(.detail(photos.details.count))
        }
        return out
    }

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(slots, id: \.self) { slot in tile(slot) }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Photos")
        } footer: {
            Text("Your own photographs of this copy. They're printed in the collection report as an evidence appendix, and backed up to your iCloud alongside your collection.")
        }
        .confirmationDialog("Add a photo", isPresented: $choosingSource, titleVisibility: .visible) {
            if cameraAvailable {
                Button("Take Photo") { showingCamera = true }
            }
            Button("Choose from Library") { showingLibrary = true }
            Button("Cancel", role: .cancel) { target = nil }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { image in store(image) }
                .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showingLibrary, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                defer { pickerItem = nil }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                store(image)
            }
        }
    }

    private func label(_ slot: EntryPhotos.Slot) -> String {
        switch slot {
        case .front: return "Front"
        case .back: return "Back"
        case .detail(let i): return "Detail \(i + 1)"
        }
    }

    @ViewBuilder
    private func tile(_ slot: EntryPhotos.Slot) -> some View {
        VStack(spacing: 4) {
            Group {
                if let file = photos.file(slot),
                   let image = photoStore.image(entryId: entryId, file: file) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                        .foregroundStyle(.secondary)
                        .overlay { Image(systemName: "camera").foregroundStyle(.secondary) }
                }
            }
            .frame(width: 64, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(label(slot)).font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            target = slot
            choosingSource = true
        }
        .contextMenu {
            if photos.file(slot) != nil {
                Button("Remove", role: .destructive) { photos.set(nil, slot) }
            }
        }
        .accessibilityLabel(photos.file(slot) == nil
                            ? "Add \(label(slot)) photo" : "\(label(slot)) photo")
    }

    /// Persist, then point the slot at the new file. The mirror is fire-and-forget: a photo that
    /// never reaches iCloud is still on the device and still in the report.
    private func store(_ image: UIImage) {
        guard let slot = target else { return }
        target = nil
        guard let name = try? photoStore.save(image, entryId: entryId) else { return }
        photos.set(name, slot)
        let store = photoStore
        Task.detached(priority: .utility) { store.mirrorUp(entryId: entryId, file: name) }
    }
}
