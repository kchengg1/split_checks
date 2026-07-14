import SwiftUI
import PhotosUI
import SplitChecksCore

/// Step 1: build the item list — by scanning a receipt, importing a photo,
/// or typing items in. Scanned items land here as an editable draft:
/// low-confidence lines are flagged and the printed subtotal acts as a
/// checksum on the parse.
struct ItemsEntryView: View {
    @Environment(BillFlowModel.self) private var model
    @State private var newName = ""
    @State private var newPriceCents = 0
    @FocusState private var nameFocused: Bool

    @State private var showingScanner = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isProcessingScan = false
    @State private var scanFailed = false
    @State private var editingItem: LineItem?

    var body: some View {
        List {
            if model.items.isEmpty && !isProcessingScan {
                scanPromptSection
            }
            itemsSection
            if !model.items.isEmpty {
                totalsSection
            }
        }
        .navigationTitle(model.merchantName ?? "New Bill")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if DocumentScannerView.isSupported {
                    Button {
                        showingScanner = true
                    } label: {
                        Label("Scan receipt", systemImage: "doc.viewfinder")
                    }
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Import photo", systemImage: "photo")
                }
            }
        }
        .overlay {
            if isProcessingScan {
                ProgressView("Reading receipt…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("Couldn't read that photo", isPresented: $scanFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No receipt text was found. Try a straighter, brighter photo — or add items by hand below.")
        }
        .fullScreenCover(isPresented: $showingScanner) {
            DocumentScannerView { pages in
                showingScanner = false
                guard !pages.isEmpty else { return }
                process(pages: pages)
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) {
            guard let photoItem else { return }
            self.photoItem = nil
            loadAndProcess(photoItem)
        }
        .sheet(item: $editingItem) { item in
            EditItemSheet(item: item)
                .presentationDetents([.medium])
        }
        .navigationDestination(for: BillStep.self) { step in
            switch step {
            case .people: PeopleView()
            case .assign: AssignView()
            case .tipTax: TipTaxView()
            case .summary: SummaryView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            NavigationLink(value: BillStep.people) {
                Text("Next: Who's here?")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.items.isEmpty)
            .padding()
            .background(.bar)
        }
    }

    // MARK: - Sections

    private var scanPromptSection: some View {
        Section {
            if DocumentScannerView.isSupported {
                Button {
                    showingScanner = true
                } label: {
                    Label("Scan receipt", systemImage: "doc.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Import a receipt photo", systemImage: "photo")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
        } footer: {
            Text("Everything stays on your phone — the photo is read on-device and never uploaded.")
        }
    }

    private var itemsSection: some View {
        Section {
            ForEach(model.items) { item in
                Button {
                    editingItem = item
                } label: {
                    itemRow(item)
                }
                .foregroundStyle(.primary)
            }
            .onDelete { model.removeItems(at: $0) }

            HStack {
                TextField("Item name", text: $newName)
                    .focused($nameFocused)
                CurrencyField(title: "0.00", cents: $newPriceCents)
                    .frame(width: 90)
                    // Recreate the field after each add so its text clears.
                    .id(model.items.count)
                Button {
                    addItem()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
                .disabled(newPriceCents == 0 && newName.isEmpty)
                .accessibilityLabel("Add item")
            }
        } header: {
            Text("Items")
        } footer: {
            if model.items.isEmpty {
                Text("Or add each dish by hand. Discounts can be negative amounts.")
            } else {
                Text("Tap an item to fix its name or price.")
            }
        }
    }

    private func itemRow(_ item: LineItem) -> some View {
        HStack {
            if item.ocrConfidence < 0.6 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Low confidence — double-check this line")
            }
            Text(item.quantity > 1 ? "\(item.quantity) × \(item.name)" : item.name)
            Spacer()
            Text(Money.format(item.priceCents))
                .monospacedDigit()
                .foregroundStyle(item.priceCents < 0 ? .green : .primary)
        }
    }

    private var totalsSection: some View {
        Section {
            HStack {
                Text("Subtotal")
                Spacer()
                Text(Money.format(model.subtotalCents))
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
            if let matches = model.subtotalChecksumMatches {
                if matches {
                    Label("Items add up to the receipt's subtotal", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                } else {
                    Label(
                        "Receipt says \(Money.format(model.scannedSubtotalCents ?? 0)) — tap items to fix, or add what's missing",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.subheadline)
                }
            }
        }
    }

    // MARK: - Actions

    private func addItem() {
        model.addItem(name: newName, priceCents: newPriceCents)
        newName = ""
        newPriceCents = 0
        nameFocused = true
    }

    private func loadAndProcess(_ item: PhotosPickerItem) {
        isProcessingScan = true
        Task {
            defer { isProcessingScan = false }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                scanFailed = true
                return
            }
            await runOCR(pages: [image])
        }
    }

    private func process(pages: [UIImage]) {
        isProcessingScan = true
        Task {
            defer { isProcessingScan = false }
            await runOCR(pages: pages)
        }
    }

    private func runOCR(pages: [UIImage]) async {
        do {
            let parsed = try await ReceiptOCR.recognizeAndParse(pages: pages)
            if parsed.items.isEmpty {
                scanFailed = true
            } else {
                model.applyParsedReceipt(parsed)
            }
        } catch {
            scanFailed = true
        }
    }
}

/// Inline fix-ups for a parsed or mistyped line. Saving marks the item
/// user-confirmed (clears the low-confidence flag).
struct EditItemSheet: View {
    @Environment(BillFlowModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: LineItem

    @State private var name: String
    @State private var priceCents: Int
    @State private var quantity: Int

    init(item: LineItem) {
        self.item = item
        _name = State(initialValue: item.name)
        _priceCents = State(initialValue: item.priceCents)
        _quantity = State(initialValue: item.quantity)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                HStack {
                    Text("Price")
                    Spacer()
                    CurrencyField(title: "0.00", cents: $priceCents)
                        .frame(width: 110)
                }
                Stepper("Quantity: \(quantity)", value: $quantity, in: 1...99)
            }
            .navigationTitle("Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.updateItem(id: item.id, name: name, priceCents: priceCents, quantity: quantity)
                        dismiss()
                    }
                }
            }
        }
    }
}
