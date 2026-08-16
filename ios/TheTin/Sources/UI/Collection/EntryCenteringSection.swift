import SwiftUI

/// Centring for a card already in the tin: photograph it, place the eight lines, keep the ratios
/// on the entry.
///
/// It reuses the scanner's editor and the entry's own photo storage rather than repeating either.
/// The picture goes in `EntryPhotos.centering`, so `PhotoStore`'s iCloud mirror carries it and a
/// restore brings it back with everything else — a saved ratio whose picture didn't survive would
/// be a number with nothing behind it, and nobody could check it again.
///
/// ⚠️ **This view presents NOTHING** — the same rule, and the same reason, as `EntryPhotosSection`
/// above it. A `.sheet` attached inside a `Form` `Section` opened and then closed itself on the
/// next re-render (device, 2026-08-15); the editor lives in `centeringEditor(...)`, attached to
/// the form's ROOT.
struct EntryCenteringSection: View {
    let entryId: String
    @Binding var photos: EntryPhotos
    @Binding var centering: Centering?
    /// Shared with the photo tiles above: one request drives the one camera/library presentation
    /// that lives on the form's root. Two presenters on one form is the case SwiftUI drops.
    @Binding var request: PhotoRequest?
    var photoStore: PhotoStore = .live()

    /// Owned by the form, because the presentation it drives has to be attached to the form's
    /// root — see `centeringEditor(...)`.
    @Binding var editing: Bool
    /// True only between choosing a photo source and that photo landing. See `shouldOpenEditor`.
    /// Not a presentation, so it can safely stay here.
    @State private var awaitingCapture = false

    /// Whether a change to the stored picture should throw the editor open.
    ///
    /// ⚠️ `awaitingCapture` is the whole point. Without it this fired on `populate()` — which
    /// assigns the entry's saved photos into the form on open, a nil → filename change — so
    /// merely opening the form launched the editor a second later, on whatever picture was last
    /// saved. That reads as the app reopening an old photo at random (Tomas, device, 2026-08-15).
    /// Only a picture the user just asked for may open anything.
    static func shouldOpenEditor(awaitingCapture: Bool, old: String?, new: String?) -> Bool {
        awaitingCapture && new != nil && new != old
    }

    private var hasPlate: Bool { photos.centering != nil }

    var body: some View {
        Section {
            if let centering {
                LabeledContent("Centering") {
                    Text(centering.summary).monospacedDigit()
                        .accessibilityLabel(centering.spokenSummary)
                }
            }
            if hasPlate {
                Button("Adjust the lines") { editing = true }
            }
            Menu {
                Button {
                    awaitingCapture = true
                    request = PhotoRequest(slot: .centering, source: .camera)
                } label: {
                    Label("Take a photo", systemImage: "camera")
                }
                Button {
                    awaitingCapture = true
                    request = PhotoRequest(slot: .centering, source: .library)
                } label: {
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
            if Self.shouldOpenEditor(awaitingCapture: awaitingCapture, old: old, new: new) {
                awaitingCapture = false
                editing = true
            }
        }
    }
}

extension View {
    /// The centring editor, attached to the FORM'S ROOT.
    ///
    /// ⚠️ Not inside the section that opens it. A `.sheet` on a `Form` `Section` presented and
    /// then dismissed itself immediately as the form re-rendered — the same class of bug the
    /// photo picker hit before it moved to `photoCapture(...)`, and the confirmation dialogs in
    /// `StagingReviewView` before they were anchored on their buttons.
    func centeringEditor(entryId: String, photos: EntryPhotos, centering: Binding<Centering?>,
                         isPresented: Binding<Bool>,
                         photoStore: PhotoStore = .live()) -> some View {
        modifier(CenteringEditorModifier(entryId: entryId, photos: photos, centering: centering,
                                         isPresented: isPresented, photoStore: photoStore))
    }
}

private struct CenteringEditorModifier: ViewModifier {
    let entryId: String
    let photos: EntryPhotos
    @Binding var centering: Centering?
    @Binding var isPresented: Bool
    let photoStore: PhotoStore

    /// Loaded when the sheet opens rather than on every render: this reads a ~250 KB JPEG off
    /// disk and decodes it, and the form re-renders on every keystroke in it.
    private var plate: UIImage? {
        photos.centering.flatMap { UIImage(contentsOfFile: photoStore.url(entryId: entryId,
                                                                          file: $0).path) }
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
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
