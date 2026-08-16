import SwiftUI

/// Centring for a card already in the tin: photograph it, place the eight lines, keep the ratios
/// on the entry.
///
/// It reuses the scanner's editor and the entry's own photo storage rather than repeating either.
/// The picture goes in `EntryPhotos.centering`, so `PhotoStore`'s iCloud mirror carries it and a
/// restore brings it back with everything else — a saved ratio whose picture didn't survive would
/// be a number with nothing behind it, and nobody could check it again.
struct EntryCenteringSection: View {
    let entryId: String
    @Binding var photos: EntryPhotos
    @Binding var centering: Centering?
    /// Shared with the photo tiles above: one request drives the one camera/library presentation
    /// that lives on the form's root. Two presenters on one form is the case SwiftUI drops.
    @Binding var request: PhotoRequest?
    var photoStore: PhotoStore = .live()

    @State private var editing = false

    private var plate: UIImage? {
        photos.centering.flatMap { UIImage(contentsOfFile: photoStore.url(entryId: entryId,
                                                                          file: $0).path) }
    }

    var body: some View {
        Section {
            if let centering {
                LabeledContent("Centering") {
                    Text(centering.summary).monospacedDigit()
                        .accessibilityLabel(centering.spokenSummary)
                }
            }
            if plate != nil {
                Button("Adjust the lines") { editing = true }
            }
            Menu {
                Button { request = PhotoRequest(slot: .centering, source: .camera) } label: {
                    Label("Take a photo", systemImage: "camera")
                }
                Button { request = PhotoRequest(slot: .centering, source: .library) } label: {
                    Label("Choose a photo", systemImage: "photo.on.rectangle")
                }
            } label: {
                Label(photos.centering == nil ? "Measure centering" : "Use a different photo",
                      systemImage: "square.dashed")
            }
        } header: {
            Text("Centering")
        } footer: {
            Text("Photograph the card flat and square-on, then drag the eight lines onto its "
                 + "edges and printed border. The ratios and the photo are both kept with this "
                 + "card and included in your backup.")
        }
        // Opening the editor is the point of taking the photo, so a new picture goes straight
        // there rather than leaving the user to find a second button.
        .onChange(of: photos.centering) { old, new in
            if new != nil, new != old { editing = true }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                if let plate {
                    CenteringEditorView(plate: plate, initial: centering) { centering = $0 }
                } else {
                    ContentUnavailableView("Photo missing", systemImage: "photo",
                                           description: Text("Take another photo of this card."))
                }
            }
        }
    }
}
