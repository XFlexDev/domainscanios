import Foundation

struct ScanResult {
    let domain: String
    let duration: TimeInterval
    let subdomains: [String]
}

final class ScannerEngine {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"
        ]
        self.session = URLSession(configuration: config)
    }

    func scan(apex: String) async -> ScanResult {
        let startTime = Date()
        let cleanApex = apex.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init) ?? apex

        var found = Set<String>()

        await withTaskGroup(of: [String].self) { group in
            // 1. crt.name API
            group.addTask { await self.fetchCrtName(apex: cleanApex) }
            // 2. crt.sh
            group.addTask { await self.fetchCrtSh(apex: cleanApex) }
            // 3. AlienVault OTX
            group.addTask { await self.fetchAlienVault(apex: cleanApex) }
            // 4. HackerTarget
            group.addTask { await self.fetchHackerTarget(apex: cleanApex) }
            // 5. Anubis
            group.addTask { await self.fetchAnubis(apex: cleanApex) }
            // 6. Wayback Machine
            group.addTask { await self.fetchWayback(apex: cleanApex) }

            for await sublist in group {
                for item in sublist {
                    let cleaned = item.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                        .replacingOccurrences(of: "*.", with: "")
                        .split(separator: ":").first.map(String.init) ?? item
                    
                    if cleaned == cleanApex || cleaned.hasSuffix(".\(cleanApex)") {
                        found.insert(cleaned)
                    }
                }
            }
        }

        let sorted = Array(found).sorted()
        let duration = Date().timeIntervalSince(startTime)
        return ScanResult(domain: cleanApex, duration: duration, subdomains: sorted)
    }

    private func fetchCrtName(apex: String) async -> [String] {
        guard let url = URL(string: "https://crt.name/v1/search?apex=\(apex)") else { return [] }
        guard let (data, resp) = try? await session.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String] { return json }
        if let text = String(data: data, encoding: .utf8) { return text.components(separatedBy: .newlines) }
        return []
    }

    private func fetchCrtSh(apex: String) async -> [String] {
        guard let url = URL(string: "https://crt.sh/?q=%25.\(apex)&output=json") else { return [] }
        guard let (data, resp) = try? await session.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        struct CrtEntry: Decodable { let name_value: String? }
        guard let entries = try? JSONDecoder().decode([CrtEntry].self, from: data) else { return [] }
        return entries.compactMap { $0.name_value }.flatMap { $0.components(separatedBy: .newlines) }
    }

    private func fetchAlienVault(apex: String) async -> [String] {
        guard let url = URL(string: "https://otx.alienvault.com/api/v1/indicators/domain/\(apex)/passive_dns") else { return [] }
        guard let (data, resp) = try? await session.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        struct OTXResp: Decodable {
            struct Record: Decodable { let hostname: String? }
            let passive_dns: [Record]?
        }
        guard let res = try? JSONDecoder().decode(OTXResp.self, from: data), let records = res.passive_dns else { return [] }
        return records.compactMap { $0.hostname }
    }

    private func fetchHackerTarget(apex: String) async -> [String] {
        guard let url = URL(string: "https://api.hackertarget.com/hostsearch/?q=\(apex)") else { return [] }
        guard let (data, resp) = try? await session.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(separator: ",")
            return parts.isEmpty ? nil : String(parts[0])
        }
    }

    private func fetchAnubis(apex: String) async -> [String] {
        guard let url = URL(string: "https://jldc.me/anubis/subdomains/\(apex)") else { return [] }
        guard let (data, resp) = try? await session.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func fetchWayback(apex: String) async -> [String] {
        guard let url = URL(string: "https://web.archive.org/cdx/search/cdx?url=*.\(apex)/*&output=json&collapse=urlkey&fl=original") else { return [] }
        guard let (data, resp) = try? await session.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String]] else { return [] }
        return list.dropFirst().compactMap { row in
            guard let rawUrl = row.first, let host = URL(string: rawUrl)?.host else { return nil }
            return host
        }
    }
}
