import SwiftUI
import UniformTypeIdentifiers

// MARK: - Models

struct ScanRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    let domain: String
    let timestamp: Date
    let duration: TimeInterval
    let subdomains: [String]
}

enum SortOrder: String, CaseIterable, Identifiable {
    case alphabeticalAsc = "A to Z"
    case alphabeticalDesc = "Z to A"
    case lengthAsc = "Shortest First"
    case lengthDesc = "Longest First"

    var id: String { rawValue }
}

enum ExportFormat: String, CaseIterable {
    case txt = "Plain Text (.txt)"
    case json = "JSON (.json)"
    case csv = "CSV (.csv)"
}

// MARK: - Main View

struct ContentView: View {
    @State private var targetDomain: String = ""
    @State private var searchQuery: String = ""
    @State private var isScanning: Bool = false
    @State private var activeRecord: ScanRecord?
    @State private var sortOrder: SortOrder = .alphabeticalAsc
    @State private var showOnlyFavorites: Bool = false
    @State private var showHistorySheet: Bool = false
    @State private var showExportSheet: Bool = false
    @State private var toastMessage: String?
    @State private var isSearchFocused: Bool = false

    @AppStorage("scan_records_json") private var scanRecordsRaw: String = "[]"
    @AppStorage("favorite_subdomains") private var favoritesRaw: String = "[]"

    private let engine = ScannerEngine()
    private let hapticFeedback = UIImpactFeedbackGenerator(style: .medium)

    // MARK: - Computed Properties

    private var historyRecords: [ScanRecord] {
        get { (try? JSONDecoder().decode([ScanRecord].self, from: Data(scanRecordsRaw.utf8))) ?? [] }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                scanRecordsRaw = String(data: data, encoding: .utf8) ?? "[]"
            }
        }
    }

    private var favoriteSubdomains: Set<String> {
        get {
            let list = (try? JSONDecoder().decode([String].self, from: Data(favoritesRaw.utf8))) ?? []
            return Set(list)
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue)) {
                favoritesRaw = String(data: data, encoding: .utf8) ?? "[]"
            }
        }
    }

    private var displayedSubdomains: [String] {
        guard let record = activeRecord else { return [] }
        var list = record.subdomains

        if showOnlyFavorites {
            list = list.filter { favoriteSubdomains.contains($0) }
        }

        if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            list = list.filter { $0.localizedCaseInsensitiveContains(searchQuery) }
        }

        switch sortOrder {
        case .alphabeticalAsc:
            list.sort()
        case .alphabeticalDesc:
            list.sort(by: >)
        case .lengthAsc:
            list.sort { $0.count < $1.count }
        case .lengthDesc:
            list.sort { $0.count > $1.count }
        }

        return list
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    searchHeaderView
                    
                    if isScanning {
                        scanningAnimationView
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    } else if let record = activeRecord {
                        resultsDashboardView(for: record)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        emptyStateView
                            .transition(.opacity)
                    }
                }

                // Floating Toast Notification
                if let msg = toastMessage {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(msg)
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.ultraThickMaterial)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isScanning)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: activeRecord)
            .animation(.easeInOut(duration: 0.2), value: toastMessage)
            .navigationTitle("Recon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showHistorySheet = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }

                if activeRecord != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showExportSheet = true
                            } label: {
                                Label("Export Options", systemImage: "square.and.arrow.up")
                            }

                            Button {
                                copyAllToClipboard()
                            } label: {
                                Label("Copy All Subdomains", systemImage: "doc.on.doc")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                }
            }
            .sheet(isPresented: $showHistorySheet) {
                historySheetView
            }
            .sheet(isPresented: $showExportSheet) {
                exportSheetView
            }
        }
    }

    // MARK: - Views

    private var searchHeaderView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    
                    TextField("Enter target (e.g. github.com)", text: $targetDomain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { startScan(targetDomain) }

                    if !targetDomain.isEmpty {
                        Button {
                            targetDomain = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(12)

                Button {
                    startScan(targetDomain)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(targetDomain.isEmpty || isScanning ? Color.secondary.opacity(0.4) : Color.accentColor)
                }
                .disabled(targetDomain.isEmpty || isScanning)
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private var scanningAnimationView: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.15), lineWidth: 6)
                    .frame(width: 80, height: 80)

                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(isScanning ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isScanning)
            }

            VStack(spacing: 6) {
                Text("Querying Threat Databases")
                    .font(.headline)
                Text("Scanning CT logs, passive DNS and historical web archives...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "globe.americas.fill")
                .font(.system(size: 54))
                .foregroundStyle(.tertiary)

            VStack(spacing: 4) {
                Text("Ready to Discover")
                    .font(.headline)
                Text("Enter an apex domain above to scan subdomains across 6+ passive sources simultaneously.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Spacer()
        }
    }

    private func resultsDashboardView(for record: ScanRecord) -> some View {
        VStack(spacing: 0) {
            // Stats summary card
            HStack(spacing: 12) {
                statCard(title: "Found", value: "\(record.subdomains.count)", icon: "square.stack.3d.up.fill", color: .blue)
                statCard(title: "Duration", value: String(format: "%.2fs", record.duration), icon: "timer", color: .orange)
                statCard(title: "Apex", value: record.domain, icon: "network", color: .purple)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            // Filtering & Sorting Bar
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Filter results...", text: $searchQuery)
                        .font(.subheadline)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(8)

                // Favorite toggle
                Button {
                    hapticFeedback.impactOccurred()
                    showOnlyFavorites.toggle()
                } label: {
                    Image(systemName: showOnlyFavorites ? "star.fill" : "star")
                        .foregroundColor(showOnlyFavorites ? .yellow : .secondary)
                        .padding(8)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .cornerRadius(8)
                }

                // Sort Menu
                Menu {
                    Picker("Sort By", selection: $sortOrder) {
                        ForEach(SortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundColor(.secondary)
                        .padding(8)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            // List of subdomains
            List {
                Section {
                    ForEach(displayedSubdomains, id: \.self) { sub in
                        subdomainRow(sub)
                    }
                } header: {
                    Text("\(displayedSubdomains.count) SUBDOMAINS")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(color)
                Spacer()
            }
            Text(value)
                .font(.system(.body, design: .rounded).weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private func subdomainRow(_ sub: String) -> some View {
        let isFav = favoriteSubdomains.contains(sub)

        return HStack {
            Text(sub)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)

            Spacer()

            Button {
                toggleFavorite(sub)
            } label: {
                Image(systemName: isFav ? "star.fill" : "star")
                    .foregroundColor(isFav ? .yellow : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)

            Button {
                copySingle(sub)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button {
                copySingle(sub)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .tint(.blue)

            Button {
                toggleFavorite(sub)
            } label: {
                Label(isFav ? "Unstar" : "Star", systemImage: isFav ? "star.slash" : "star.fill")
            }
            .tint(.yellow)
        }
    }

    // MARK: - History Sheet

    private var historySheetView: some View {
        NavigationStack {
            List {
                if historyRecords.isEmpty {
                    ContentUnavailableView("No Scan History", systemImage: "clock", description: Text("Your past reconnaissance runs will appear here."))
                } else {
                    ForEach(historyRecords) { rec in
                        Button {
                            activeRecord = rec
                            targetDomain = rec.domain
                            showHistorySheet = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rec.domain)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text("\(rec.subdomains.count) subdomains found • \(rec.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.tertiaryLabel)
                            }
                        }
                    }
                    .onDelete(perform: deleteHistoryItem)
                }
            }
            .navigationTitle("Scan History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !historyRecords.isEmpty {
                        Button(role: .destructive) {
                            historyRecords.removeAll()
                        } label: {
                            Text("Clear All")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showHistorySheet = false
                    }
                }
            }
        }
    }

    // MARK: - Export Sheet

    private var exportSheetView: some View {
        NavigationStack {
            List {
                Section("Choose Format") {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Button {
                            exportFormattedData(format)
                        } label: {
                            HStack {
                                Text(format.rawValue)
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Export Subdomains")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { showExportSheet = false }
                }
            }
        }
    }

    // MARK: - Logic & Actions

    private func startScan(_ domain: String) {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        hapticFeedback.impactOccurred()
        isScanning = true

        Task {
            let res = await engine.scan(apex: clean)
            let newRecord = ScanRecord(
                domain: res.domain,
                timestamp: Date(),
                duration: res.duration,
                subdomains: res.subdomains
            )

            await MainActor.run {
                self.activeRecord = newRecord
                self.isScanning = false
                saveToHistory(newRecord)
                showToast("Found \(res.subdomains.count) subdomains")
            }
        }
    }

    private func saveToHistory(_ record: ScanRecord) {
        var list = historyRecords.filter { $0.domain != record.domain }
        list.insert(record, at: 0)
        if list.count > 25 { list = Array(list.prefix(25)) }
        historyRecords = list
    }

    private func deleteHistoryItem(at offsets: IndexSet) {
        historyRecords.remove(atOffsets: offsets)
    }

    private func toggleFavorite(_ sub: String) {
        hapticFeedback.impactOccurred()
        var favs = favoriteSubdomains
        if favs.contains(sub) {
            favs.remove(sub)
        } else {
            favs.insert(sub)
        }
        favoriteSubdomains = favs
    }

    private func copySingle(_ text: String) {
        UIPasteboard.general.string = text
        hapticFeedback.impactOccurred()
        showToast("Copied: \(text)")
    }

    private func copyAllToClipboard() {
        guard let list = activeRecord?.subdomains, !list.isEmpty else { return }
        UIPasteboard.general.string = list.joined(separator: "\n")
        hapticFeedback.impactOccurred()
        showToast("Copied \(list.count) subdomains")
    }

    private func exportFormattedData(_ format: ExportFormat) {
        guard let record = activeRecord else { return }
        var output = ""

        switch format {
        case .txt:
            output = record.subdomains.joined(separator: "\n")
        case .json:
            if let data = try? JSONEncoder().encode(record.subdomains), let str = String(data: data, encoding: .utf8) {
                output = str
            }
        case .csv:
            output = "Subdomain\n" + record.subdomains.joined(separator: "\n")
        }

        UIPasteboard.general.string = output
        showExportSheet = false
        showToast("Exported to clipboard as \(format.rawValue)")
    }

    private func showToast(_ msg: String) {
        toastMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if self.toastMessage == msg {
                self.toastMessage = nil
            }
        }
    }
}
