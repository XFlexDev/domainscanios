import SwiftUI
import UniformTypeIdentifiers

// MARK: - Data Models

struct ScanRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    let domain: String
    let timestamp: Date
    let duration: TimeInterval
    let subdomains: [String]
}

enum SortOption: String, CaseIterable, Identifiable {
    case nameAsc = "A → Z"
    case nameDesc = "Z → A"
    case lenAsc = "Shortest"
    case lenDesc = "Longest"

    var id: String { rawValue }
}

enum ExportType: String, CaseIterable, Identifiable {
    case txt = "Plain Text (.txt)"
    case json = "JSON Array (.json)"
    case csv = "CSV Spreadsheet (.csv)"

    var id: String { rawValue }
}

// MARK: - State Store (Thread-Safe Persistence)

@MainActor
final class AppStore: ObservableObject {
    @Published var history: [ScanRecord] = []
    @Published var favorites: Set<String> = []
    @Published var activeRecord: ScanRecord?
    @Published var isScanning: Bool = false

    private let historyKey = "domain_scanner_history_v3"
    private let favoritesKey = "domain_scanner_favorites_v3"

    init() {
        loadStorage()
    }

    func loadStorage() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let records = try? JSONDecoder().decode([ScanRecord].self, from: data) {
            self.history = records
        }
        if let favList = UserDefaults.standard.stringArray(forKey: favoritesKey) {
            self.favorites = Set(favList)
        }
    }

    func recordScan(_ record: ScanRecord) {
        history.removeAll { $0.domain.lowercased() == record.domain.lowercased() }
        history.insert(record, at: 0)
        if history.count > 50 { history = Array(history.prefix(50)) }
        persistHistory()
    }

    func deleteRecord(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        persistHistory()
    }

    func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    func toggleFavorite(_ subdomain: String) {
        if favorites.contains(subdomain) {
            favorites.remove(subdomain)
        } else {
            favorites.insert(subdomain)
        }
        UserDefaults.standard.set(Array(favorites), forKey: favoritesKey)
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }
}

// MARK: - Main User Interface

struct ContentView: View {
    @StateObject private var store = AppStore()
    private let engine = ScannerEngine()
    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    @State private var targetInput: String = ""
    @State private var filterQuery: String = ""
    @State private var sortOption: SortOption = .nameAsc
    @State private var onlyFavorites: Bool = false
    @State private var showHistorySheet: Bool = false
    @State private var showExportSheet: Bool = false
    @State private var toastText: String?

    // MARK: - Computed Filter & Sort

    private var filteredResults: [String] {
        guard let record = store.activeRecord else { return [] }
        var list = record.subdomains

        if onlyFavorites {
            list = list.filter { store.favorites.contains($0) }
        }

        if !filterQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            list = list.filter { $0.localizedCaseInsensitiveContains(filterQuery) }
        }

        switch sortOption {
        case .nameAsc:
            list.sort()
        case .nameDesc:
            list.sort(by: >)
        case .lenAsc:
            list.sort { $0.count < $1.count }
        case .lenDesc:
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
                    searchHeaderSection

                    if store.isScanning {
                        radarScannerSection
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    } else if let record = store.activeRecord {
                        dashboardResultsSection(for: record)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        emptyStateHeroSection
                            .transition(.opacity)
                    }
                }

                // Toast Notification Overlay
                if let msg = toastText {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.cyan)
                            Text(msg)
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThickMaterial)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: store.isScanning)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: store.activeRecord)
            .animation(.easeInOut(duration: 0.2), value: toastText)
            .navigationTitle("Recon OSINT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        haptic.impactOccurred()
                        showHistorySheet = true
                    } label: {
                        Image(systemName: "clock.arrow.2.circlepath")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }

                if store.activeRecord != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showExportSheet = true
                            } label: {
                                Label("Export Data", systemImage: "square.and.arrow.up")
                            }

                            Button {
                                copyAll()
                            } label: {
                                Label("Copy All Subdomains", systemImage: "doc.on.doc")
                            }
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                }
            }
            .sheet(isPresented: $showHistorySheet) {
                historySheet
            }
            .sheet(isPresented: $showExportSheet) {
                exportSheet
            }
        }
    }

    // MARK: - Search Header

    private var searchHeaderSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)

                    TextField("Target apex (e.g. stripe.com)", text: $targetInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { performScan(targetInput) }

                    if !targetInput.isEmpty {
                        Button {
                            targetInput = ""
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
                    performScan(targetInput)
                } label: {
                    ZStack {
                        Circle()
                            .fill(targetInput.isEmpty || store.isScanning ? Color.secondary.opacity(0.2) : Color.accentColor)
                            .frame(width: 42, height: 42)

                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .disabled(targetInput.isEmpty || store.isScanning)
            }
            .padding(.horizontal)
            .padding(.top, 6)

            // History Quick Chips
            if !store.history.isEmpty && store.activeRecord == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.history.prefix(6)) { item in
                            Button {
                                targetInput = item.domain
                                performScan(item.domain)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 10))
                                    Text(item.domain)
                                        .font(.caption.weight(.medium))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(uiColor: .secondarySystemGroupedBackground))
                                .foregroundColor(.primary)
                                .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: - Scanning Radar Animation

    private var radarScannerSection: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.12), lineWidth: 40)
                    .frame(width: 130, height: 130)

                Circle()
                    .trim(from: 0, to: 0.65)
                    .stroke(
                        AngularGradient(
                            colors: [.accentColor.opacity(0.1), .accentColor],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(store.isScanning ? 360 : 0))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: store.isScanning)

                Image(systemName: "network")
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(.accentColor)
            }

            VStack(spacing: 6) {
                Text("Searching Passive Intel")
                    .font(.headline)
                Text("Querying crt.name, crt.sh, AlienVault, HackerTarget, Anubis & Wayback archives...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }

            Spacer()
        }
    }

    // MARK: - Empty State

    private var emptyStateHeroSection: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .frame(width: 88, height: 88)

                Image(systemName: "globe.badge.chevron.backward")
                    .font(.system(size: 38, weight: .light))
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 6) {
                Text("Real-Time Domain Discovery")
                    .font(.headline)
                Text("Scan any apex domain to unearth all active and historical subdomains directly from your iPhone.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
            Spacer()
        }
    }

    // MARK: - Results Dashboard

    private func dashboardResultsSection(for record: ScanRecord) -> some View {
        VStack(spacing: 0) {
            // Stats Row
            HStack(spacing: 10) {
                statPill(title: "Subdomains", value: "\(record.subdomains.count)", icon: "square.3.layers.3d", color: .cyan)
                statPill(title: "Duration", value: String(format: "%.2fs", record.duration), icon: "stopwatch", color: .orange)
                statPill(title: "Target", value: record.domain, icon: "shield", color: .indigo)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Filtering & Controls
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Filter results...", text: $filterQuery)
                        .font(.subheadline)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(10)

                // Favorite Toggle
                Button {
                    haptic.impactOccurred()
                    onlyFavorites.toggle()
                } label: {
                    Image(systemName: onlyFavorites ? "star.fill" : "star")
                        .foregroundColor(onlyFavorites ? .yellow : .secondary)
                        .frame(width: 36, height: 36)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .cornerRadius(10)
                }

                // Sort Menu
                Menu {
                    Picker("Sort", selection: $sortOption) {
                        ForEach(SortOption.allCases) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.and.down.text.horizontal")
                        .foregroundColor(.secondary)
                        .frame(width: 36, height: 36)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .cornerRadius(10)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 6)

            // Results List
            List {
                Section {
                    ForEach(filteredResults, id: \.self) { sub in
                        subdomainRowItem(sub)
                    }
                } header: {
                    Text("\(filteredResults.count) SUBDOMAINS")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func statPill(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundColor(color)
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private func subdomainRowItem(_ sub: String) -> some View {
        let isFav = store.favorites.contains(sub)

        return HStack(spacing: 8) {
            Text(sub)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)

            Spacer()

            Button {
                store.toggleFavorite(sub)
                haptic.impactOccurred()
            } label: {
                Image(systemName: isFav ? "star.fill" : "star")
                    .foregroundColor(isFav ? .yellow : Color.secondary.opacity(0.3))
            }
            .buttonStyle(.plain)

            Button {
                copyText(sub)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button {
                copyText(sub)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .tint(.cyan)

            Button {
                store.toggleFavorite(sub)
            } label: {
                Label(isFav ? "Unstar" : "Star", systemImage: isFav ? "star.slash" : "star.fill")
            }
            .tint(.yellow)
        }
    }

    // MARK: - History Sheet

    private var historySheet: some View {
        NavigationStack {
            List {
                if store.history.isEmpty {
                    ContentUnavailableView(
                        "No Previous Scans",
                        systemImage: "clock",
                        description: Text("Scanned domains will be saved here automatically.")
                    )
                } else {
                    ForEach(store.history) { rec in
                        Button {
                            store.activeRecord = rec
                            targetInput = rec.domain
                            showHistorySheet = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(rec.domain)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text("\(rec.subdomains.count) subdomains • \(rec.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundColor(.tertiaryLabel)
                            }
                        }
                    }
                    .onDelete { offsets in
                        store.deleteRecord(at: offsets)
                    }
                }
            }
            .navigationTitle("Scan History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.history.isEmpty {
                        Button(role: .destructive) {
                            store.clearHistory()
                        } label: {
                            Text("Clear")
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

    private var exportSheet: some View {
        NavigationStack {
            List {
                Section("Choose File Format") {
                    ForEach(ExportType.allCases) { format in
                        Button {
                            exportData(format)
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
            .navigationTitle("Export Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { showExportSheet = false }
                }
            }
        }
    }

    // MARK: - Actions

    private func performScan(_ domain: String) {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        haptic.impactOccurred()
        store.isScanning = true

        Task {
            let res = await engine.scan(apex: clean)
            let newRecord = ScanRecord(
                domain: res.domain,
                timestamp: Date(),
                duration: res.duration,
                subdomains: res.subdomains
            )

            await MainActor.run {
                self.store.activeRecord = newRecord
                self.store.isScanning = false
                self.store.recordScan(newRecord)
                triggerToast("Found \(res.subdomains.count) subdomains")
            }
        }
    }

    private func copyText(_ text: String) {
        UIPasteboard.general.string = text
        haptic.impactOccurred()
        triggerToast("Copied: \(text)")
    }

    private func copyAll() {
        guard let subs = store.activeRecord?.subdomains, !subs.isEmpty else { return }
        UIPasteboard.general.string = subs.joined(separator: "\n")
        haptic.impactOccurred()
        triggerToast("Copied \(subs.count) subdomains")
    }

    private func exportData(_ type: ExportType) {
        guard let subs = store.activeRecord?.subdomains else { return }
        var result = ""

        switch type {
        case .txt:
            result = subs.joined(separator: "\n")
        case .json:
            if let data = try? JSONEncoder().encode(subs), let str = String(data: data, encoding: .utf8) {
                result = str
            }
        case .csv:
            result = "Subdomain\n" + subs.joined(separator: "\n")
        }

        UIPasteboard.general.string = result
        showExportSheet = false
        triggerToast("Exported as \(type.rawValue)")
    }

    private func triggerToast(_ message: String) {
        toastText = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if self.toastText == message {
                self.toastText = nil
            }
        }
    }
}
