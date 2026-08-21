import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Models

struct ScanRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let domain: String
    let timestamp: Date
    let duration: TimeInterval
    let subdomains: [String]

    init(id: UUID = UUID(), domain: String, timestamp: Date, duration: TimeInterval, subdomains: [String]) {
        self.id = id
        self.domain = domain
        self.timestamp = timestamp
        self.duration = duration
        self.subdomains = subdomains
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case nameAsc = "A to Z"
    case nameDesc = "Z to A"
    case lenAsc = "Shortest"
    case lenDesc = "Longest"

    var id: String { rawValue }
}

enum ExportType: String, CaseIterable, Identifiable {
    case txt = "Text file (.txt)"
    case json = "JSON (.json)"
    case csv = "CSV (.csv)"

    var id: String { rawValue }
}

// MARK: - Notifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func sendCompletedNotification(domain: String, count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Scan Complete"
        content.body = "Found \(count) subdomains for \(domain)."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Store

@MainActor
final class AppStore: ObservableObject {
    @Published var history: [ScanRecord] = []
    @Published var favorites: Set<String> = []
    @Published var activeRecord: ScanRecord?
    @Published var isScanning: Bool = false

    private let historyKey = "scanner_history_v7"
    private let favoritesKey = "scanner_favorites_v7"

    init() {
        loadData()
    }

    func loadData() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let records = try? JSONDecoder().decode([ScanRecord].self, from: data) {
            self.history = records
        }
        if let favList = UserDefaults.standard.stringArray(forKey: favoritesKey) {
            self.favorites = Set(favList)
        }
    }

    func saveScan(_ record: ScanRecord) {
        history.removeAll { $0.domain.lowercased() == record.domain.lowercased() }
        history.insert(record, at: 0)
        if history.count > 50 { history = Array(history.prefix(50)) }
        persist()
    }

    func deleteHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        persist()
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

    private func persist() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }
}

// MARK: - Main View

struct ContentView: View {
    @StateObject private var store = AppStore()
    private let engine = ScannerEngine()
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

    @Namespace private var animationNamespace

    @State private var targetDomain: String = ""
    @State private var filterText: String = ""
    @State private var sortOption: SortOption = .nameAsc
    @State private var showFavoritesOnly: Bool = false
    @State private var showHistorySheet: Bool = false
    @State private var showExportSheet: Bool = false
    @State private var snackbarText: String?

    private var filteredSubdomains: [String] {
        guard let record = store.activeRecord else { return [] }
        var list = record.subdomains

        if showFavoritesOnly {
            list = list.filter { store.favorites.contains($0) }
        }

        if !filterText.trimmingCharacters(in: .whitespaces).isEmpty {
            list = list.filter { $0.localizedCaseInsensitiveContains(filterText) }
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
            ZStack(alignment: .top) {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    if !store.isScanning {
                        searchBarSection
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if store.isScanning {
                        loadingCenterView
                            .transition(.opacity)
                    } else if let record = store.activeRecord {
                        resultsView(record: record)
                            .transition(.opacity)
                    } else {
                        emptyStateView
                            .transition(.opacity)
                    }
                }

                // Simple Animated Snackbar
                if let message = snackbarText {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.green)
                        Text(message)
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThickMaterial)
                    .clipShape(Capsule())
                    .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.8), value: store.isScanning)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: store.activeRecord)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: snackbarText)
            .navigationTitle(store.isScanning ? "" : "Domain Scanner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !store.isScanning {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            lightHaptic.impactOccurred()
                            showHistorySheet = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }

                    if store.activeRecord != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button {
                                    showExportSheet = true
                                } label: {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                }

                                Button {
                                    copyAllSubdomains()
                                } label: {
                                    Label("Copy All", systemImage: "doc.on.doc")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
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

    // MARK: - Search Bar

    private var searchBarSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)

                    TextField("Enter domain (e.g. github.com)", text: $targetDomain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
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
                        .foregroundColor(targetDomain.isEmpty ? Color.secondary.opacity(0.3) : Color.accentColor)
                }
                .disabled(targetDomain.isEmpty)
            }
            .padding(.horizontal)
            .padding(.top, 6)

            // History Quick Chips
            if !store.history.isEmpty && store.activeRecord == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(store.history.prefix(5)), id: \.id) { (item: ScanRecord) in
                            Button {
                                targetDomain = item.domain
                                startScan(item.domain)
                            } label: {
                                Text(item.domain)
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                                    .foregroundColor(.primary)
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - Morphing Loading Screen (Clean & Minimal)

    private var loadingCenterView: some View {
        VStack(spacing: 20) {
            Spacer()

            Text(targetDomain)
                .font(.title2.weight(.bold))
                .matchedGeometryEffect(id: "domainHeader", in: animationNamespace)

            ProgressView()
                .controlSize(.regular)

            Text("Searching subdomains...")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "network")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.7))
            Text("Search a domain above to find its subdomains.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: - Results View

    private func resultsView(record: ScanRecord) -> some View {
        VStack(spacing: 0) {
            // Top Summary Bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.domain)
                        .font(.headline)
                        .matchedGeometryEffect(id: "domainHeader", in: animationNamespace)
                    Text("\(record.subdomains.count) subdomains found • \(String(format: "%.1fs", record.duration))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    targetDomain = ""
                    store.activeRecord = nil
                } label: {
                    Text("New Scan")
                        .font(.subheadline.weight(.medium))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)

            // Filter & Options Bar
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Filter...", text: $filterText)
                        .font(.subheadline)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(8)

                Button {
                    lightHaptic.impactOccurred()
                    showFavoritesOnly.toggle()
                } label: {
                    Image(systemName: showFavoritesOnly ? "star.fill" : "star")
                        .foregroundColor(showFavoritesOnly ? .yellow : .secondary)
                        .padding(8)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .cornerRadius(8)
                }

                Menu {
                    Picker("Sort", selection: $sortOption) {
                        ForEach(SortOption.allCases) { (opt: SortOption) in
                            Text(opt.rawValue).tag(opt)
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
            .padding(.bottom, 6)

            // List
            List {
                ForEach(filteredSubdomains, id: \.self) { (sub: String) in
                    subdomainRow(sub)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func subdomainRow(_ sub: String) -> some View {
        let isFav = store.favorites.contains(sub)

        return HStack {
            Text(sub)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            Spacer()

            Button {
                lightHaptic.impactOccurred()
                store.toggleFavorite(sub)
            } label: {
                Image(systemName: isFav ? "star.fill" : "star")
                    .foregroundColor(isFav ? .yellow : Color.secondary.opacity(0.3))
            }
            .buttonStyle(.plain)

            Button {
                copySingle(sub)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    // MARK: - History Sheet

    private var historySheetView: some View {
        NavigationStack {
            List {
                if store.history.isEmpty {
                    ContentUnavailableView("No History", systemImage: "clock", description: Text("Previous scans will appear here."))
                } else {
                    ForEach(store.history, id: \.id) { (rec: ScanRecord) in
                        Button {
                            targetDomain = rec.domain
                            store.activeRecord = rec
                            showHistorySheet = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rec.domain)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text("\(rec.subdomains.count) subdomains • \(rec.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        store.deleteHistory(at: offsets)
                    }
                }
            }
            .navigationTitle("History")
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

    private var exportSheetView: some View {
        NavigationStack {
            List {
                Section("Choose Format") {
                    ForEach(ExportType.allCases, id: \.id) { (format: ExportType) in
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
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showExportSheet = false
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func startScan(_ domain: String) {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        mediumHaptic.impactOccurred()
        store.isScanning = true

        var bgTaskId: UIBackgroundTaskIdentifier = .invalid
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "Scan-\(clean)") {
            if bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskId)
                bgTaskId = .invalid
            }
        }

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
                self.store.saveScan(newRecord)
                
                showSnackbar("Found \(res.subdomains.count) subdomains")
                NotificationManager.shared.sendCompletedNotification(domain: res.domain, count: res.subdomains.count)

                if bgTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskId)
                    bgTaskId = .invalid
                }
            }
        }
    }

    private func copySingle(_ text: String) {
        UIPasteboard.general.string = text
        lightHaptic.impactOccurred()
        showSnackbar("Copied")
    }

    private func copyAllSubdomains() {
        guard let subs = store.activeRecord?.subdomains, !subs.isEmpty else { return }
        UIPasteboard.general.string = subs.joined(separator: "\n")
        lightHaptic.impactOccurred()
        showSnackbar("Copied all \(subs.count) subdomains")
    }

    private func exportData(_ format: ExportType) {
        guard let subs = store.activeRecord?.subdomains else { return }
        var output = ""

        switch format {
        case .txt:
            output = subs.joined(separator: "\n")
        case .json:
            if let data = try? JSONEncoder().encode(subs), let str = String(data: data, encoding: .utf8) {
                output = str
            }
        case .csv:
            output = "Subdomain\n" + subs.joined(separator: "\n")
        }

        UIPasteboard.general.string = output
        showExportSheet = false
        showSnackbar("Exported as \(format.rawValue)")
    }

    private func showSnackbar(_ text: String) {
        snackbarText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if self.snackbarText == text {
                self.snackbarText = nil
            }
        }
    }
}
