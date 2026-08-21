import SwiftUI

struct ContentView: View {
    @State private var targetDomain: String = ""
    @State private var filterQuery: String = ""
    @State private var isScanning: Bool = false
    @State private var result: ScanResult?
    
    @AppStorage("scan_history") private var historyRaw: String = "[]"
    private let engine = ScannerEngine()

    private var history: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(historyRaw.utf8))) ?? [] }
    }

    private var filteredSubdomains: [String] {
        guard let subs = result?.subdomains else { return [] }
        if filterQuery.isEmpty { return subs }
        return subs.filter { $0.localizedCaseInsensitiveContains(filterQuery) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Taustalla hienovarainen dynaaminen sävy, joka herättää Liquid Glass -taittumisen eloon
                LinearGradient(
                    colors: [
                        Color.blue.opacity(0.12),
                        Color.indigo.opacity(0.08),
                        Color(UIColor.systemBackground)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    
                    // --- NESTEMÄINEN LASIHAKUPALKKI (Liquid Glass Floating Panel) ---
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.secondary)
                            
                            TextField("Syötä apex (esim. apple.com)", text: $targetDomain)
                                .font(.system(size: 16, weight: .regular))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.go)
                                .onSubmit { startScan(targetDomain) }
                            
                            if isScanning {
                                ProgressView()
                                    .scaleEffect(0.9)
                            } else if !targetDomain.isEmpty {
                                Button(action: { startScan(targetDomain) }) {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: 26))
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        // Aito iOS 26 Liquid Glass -määre
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))

                        // Historia-chipit nestelasilla
                        if !history.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(history, id: \.self) { item in
                                        Button(action: {
                                            targetDomain = item
                                            startScan(item)
                                        }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "clock.arrow.circlepath")
                                                    .font(.system(size: 11))
                                                Text(item)
                                                    .font(.system(size: 13, weight: .medium))
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                        }
                                        .buttonStyle(.plain)
                                        .glassEffect(.clear, in: .capsule)
                                    }
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                    // --- TULOSOSIO ---
                    if let res = result {
                        VStack(spacing: 8) {
                            // Tilastorivi nestelasilla
                            HStack {
                                Text("\(res.subdomains.count) alidomainia")
                                    .font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Text(String(format: "%.2fs", res.duration))
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .glassEffect(.regular, in: .rect(cornerRadius: 12))
                            .padding(.horizontal, 16)

                            // Suodatus
                            if res.subdomains.count > 6 {
                                HStack {
                                    Image(systemName: "line.3.horizontal.decrease")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    TextField("Filtteröi listaa...", text: $filterQuery)
                                        .font(.subheadline)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .glassEffect(.clear, in: .rect(cornerRadius: 10))
                                .padding(.horizontal, 16)
                            }
                        }

                        // Alidomain-lista
                        List(filteredSubdomains, id: \.self) { sub in
                            Text(sub)
                                .font(.system(size: 15, design: .monospaced))
                                .padding(.vertical, 2)
                                .textSelection(.enabled)
                                .listRowBackground(Color.clear)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)

                    } else {
                        Spacer()
                        Image(systemName: "globe.badge.chevron.backward")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let res = result, !res.subdomains.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: res.subdomains.joined(separator: "\n")) {
                            Image(systemName: "square.and.arrow.up")
                                .padding(8)
                        }
                        .glassEffect(.clear, in: .circle)
                    }
                }
            }
        }
    }

    private func startScan(_ domain: String) {
        guard !domain.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isScanning = true
        saveHistory(domain)
        
        Task {
            let res = await engine.scan(apex: domain)
            await MainActor.run {
                self.result = res
                self.isScanning = false
            }
        }
    }

    private func saveHistory(_ domain: String) {
        var current = history.filter { $0 != domain }
        current.insert(domain, at: 0)
        if current.count > 8 { current = Array(current.prefix(8)) }
        if let data = try? JSONEncoder().encode(current) {
            historyRaw = String(data: data, encoding: .utf8) ?? "[]"
        }
    }
}
