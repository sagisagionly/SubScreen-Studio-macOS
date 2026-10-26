import AppKit
import AVFoundation
import Foundation

struct LyricLine: Equatable, Sendable {
    let time: Double
    let text: String
}

private struct LRCLyricsResponse: Decodable {
    let id: Int?
    let plainLyrics: String?
    let syncedLyrics: String?
    let duration: Double?
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let instrumental: Bool?
}

private struct FetchedLyrics: Sendable {
    let lines: [LyricLine]
    let plain: String?
    let provider: String
}

private struct ITunesSearchResponse: Decodable {
    struct Result: Decodable { let artworkUrl100: String? }
    let results: [Result]
}

extension NowPlayingMonitor {
    func refreshArtworkAndLyrics(for title: String, artist: String, album: String? = nil, duration: Double, source: String, videoID: String? = nil, exactArtworkData: Data? = nil, exactArtworkURL: URL? = nil) {
        artworkTask?.cancel()
        lyricsTask?.cancel()
        artwork = exactArtworkData.flatMap(NSImage.init(data:))
        lyricLines = []
        plainLyrics = nil
        lyricsStatus = "Finding lyrics…"

        let normalizedArtist = artist == "YouTube Music" ? "" : artist
        artworkTask = Task { [weak self] in
            guard let self else { return }
            if let exactArtworkURL,
               let (imageData, response) = try? await URLSession.shared.data(from: exactArtworkURL),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let image = NSImage(data: imageData), !Task.isCancelled {
                await MainActor.run { self.artwork = image }
                return
            }
            if source == "Apple Music", let image = await Self.readAppleMusicArtwork(), !Task.isCancelled {
                await MainActor.run { self.artwork = image }
                return
            }
            guard exactArtworkData == nil else { return }
            var components = URLComponents(string: "https://itunes.apple.com/search")!
            components.queryItems = [
                URLQueryItem(name: "term", value: "\(title) \(normalizedArtist)"),
                URLQueryItem(name: "media", value: "music"),
                URLQueryItem(name: "entity", value: "song"),
                URLQueryItem(name: "limit", value: "1")
            ]
            guard let url = components.url,
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let match = try? JSONDecoder().decode(ITunesSearchResponse.self, from: data),
                  let artworkString = match.results.first?.artworkUrl100,
                  let artworkURL = URL(string: artworkString.replacingOccurrences(of: "100x100", with: "600x600")),
                  let (imageData, _) = try? await URLSession.shared.data(from: artworkURL),
                  let image = NSImage(data: imageData), !Task.isCancelled else { return }
            await MainActor.run { self.artwork = image }
        }

        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let preference = UserDefaults.standard.string(forKey: "lyricsProvider") ?? "automatic"
            let result = await Self.fetchLyrics(provider: preference, title: title, artist: normalizedArtist, album: album, duration: duration, videoID: videoID)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.lyricLines = result?.lines ?? []
                self.plainLyrics = result?.plain
                self.lyricsStatus = result.map { "Original lyrics by \($0.provider)" }
                    ?? "No lyrics found for \(title) — \(normalizedArtist.isEmpty ? "unknown artist" : normalizedArtist)"
            }
        }
    }

    nonisolated private static func fetchLyrics(provider: String, title: String, artist: String, album: String?, duration: Double, videoID: String?) async -> FetchedLyrics? {
        // YouTube Music can occasionally provide first-party synced lyrics
        // when its video id is available. LRCLIB remains the fastest broad
        // catalog and is tried before providers that require token setup or
        // HTML parsing.
        let providers = provider == "automatic" ? ["ytmusic", "lrclib", "musixmatch", "megalobiz"] : [provider]
        if let result = await fetchFirstVerifiedLyrics(
            providers: providers,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            videoID: videoID
        ) {
            return result
        }

        // Apple Music can expose a localized English title while synced lyric
        // catalogs index the same recording under its original Japanese,
        // Korean, or Chinese script. MusicBrainz is used only as a metadata
        // bridge after the exact search fails; lyric text is never translated.
        let alternativeTitles = await fetchOriginalTitleAliases(title: title, artist: artist, duration: duration)
        for searchTitle in alternativeTitles where canonicalLyricsText(searchTitle) != canonicalLyricsText(title) {
            if let result = await fetchFirstVerifiedLyrics(
                providers: providers,
                title: searchTitle,
                artist: artist,
                album: album,
                duration: duration,
                videoID: videoID
            ) { return result }
        }
        return nil
    }

    nonisolated private static func fetchFirstVerifiedLyrics(providers: [String], title: String, artist: String, album: String?, duration: Double, videoID: String?) async -> FetchedLyrics? {
        for provider in providers {
            if Task.isCancelled { return nil }
            if let result = await fetchLyrics(from: provider, title: title, artist: artist, album: album, duration: duration, videoID: videoID),
               !result.lines.isEmpty || !(result.plain ?? "").isEmpty {
                return result
            }
        }
        return nil
    }

    nonisolated private static func fetchLyrics(from provider: String, title: String, artist: String, album: String?, duration: Double, videoID: String?) async -> FetchedLyrics? {
        switch provider {
        case "ytmusic":
            guard let videoID else { return nil }
            return await fetchYouTubeMusic(videoID: videoID, title: title, artist: artist)
        case "musixmatch": return try? await fetchMusixmatch(title: title, artist: artist, album: album, duration: duration)
        case "megalobiz": return try? await fetchMegalobiz(title: title, artist: artist, duration: duration)
        default: return try? await fetchLRCLib(title: title, artist: artist, album: album, duration: duration)
        }
    }

    nonisolated private static func fetchOriginalTitleAliases(title: String, artist: String, duration: Double) async -> [String] {
        guard !title.isEmpty, !artist.isEmpty else { return [] }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")!
        components.queryItems = [
            URLQueryItem(name: "query", value: "recording:\"\(title)\" AND artist:\"\(artist)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "8")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("SubScreenStudio/0.7 (macOS; lyrics metadata)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordings = root["recordings"] as? [[String: Any]] else { return [] }

        var candidates: [(title: String, score: Double)] = []
        for recording in recordings {
            guard let candidateTitle = recording["title"] as? String, !candidateTitle.isEmpty else { continue }
            let credits = recording["artist-credit"] as? [[String: Any]] ?? []
            let candidateArtist = credits.compactMap { credit -> String? in
                if let name = credit["name"] as? String { return name }
                return (credit["artist"] as? [String: Any])?["name"] as? String
            }.joined(separator: " & ")
            let artistScore = bestArtistSimilarity(candidateArtist, artist)
            guard artistScore >= 0.86 else { continue }
            let length = (recording["length"] as? NSNumber).map { $0.doubleValue / 1000 }
            let delta = duration > 1 && length != nil ? abs((length ?? duration) - duration) : 0
            guard delta <= 15 else { continue }
            let searchScore = (recording["score"] as? NSNumber)?.doubleValue ?? 0
            candidates.append((candidateTitle, artistScore * 4 + searchScore / 100 - delta / 15))
            for alias in recording["aliases"] as? [[String: Any]] ?? [] {
                if let name = alias["name"] as? String, !name.isEmpty {
                    candidates.append((name, artistScore * 4 + searchScore / 100 - delta / 15 - 0.05))
                }
            }
        }
        return candidates.sorted { $0.score > $1.score }.map(\.title).reduce(into: []) { titles, candidate in
            if !titles.contains(where: { canonicalLyricsText($0) == canonicalLyricsText(candidate) }) { titles.append(candidate) }
        }
    }

    nonisolated private static func fetchYouTubeMusic(videoID: String, title: String, artist: String) async -> FetchedLyrics? {
        let context: [String: Any] = [
            "client": ["clientName": "WEB_REMIX", "clientVersion": "1.20261015.01.00"]
        ]
        guard let next = await youtubeMusicRequest(
            path: "next",
            body: ["context": context, "videoId": videoID]
        ),
        let contents = next["contents"] as? [String: Any],
        let singleColumn = contents["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any],
        let tabbed = singleColumn["tabbedRenderer"] as? [String: Any],
        let results = tabbed["watchNextTabbedResultsRenderer"] as? [String: Any],
        let tabs = results["tabs"] as? [[String: Any]] else { return nil }

        var browseID: String?
        for tab in tabs {
            guard let renderer = tab["tabRenderer"] as? [String: Any],
                  let endpoint = renderer["endpoint"] as? [String: Any],
                  let browse = endpoint["browseEndpoint"] as? [String: Any],
                  let configs = browse["browseEndpointContextSupportedConfigs"] as? [String: Any],
                  let music = configs["browseEndpointContextMusicConfig"] as? [String: Any],
                  music["pageType"] as? String == "MUSIC_PAGE_TYPE_TRACK_LYRICS" else { continue }
            browseID = browse["browseId"] as? String
            break
        }
        guard let browseID,
              let page = await youtubeMusicRequest(
                path: "browse",
                body: ["context": context, "browseId": browseID]
              ),
              let pageContents = page["contents"] as? [String: Any] else { return nil }

        if let element = pageContents["elementRenderer"] as? [String: Any],
           let newElement = element["newElement"] as? [String: Any],
           let type = newElement["type"] as? [String: Any],
           let component = type["componentType"] as? [String: Any],
           let model = component["model"] as? [String: Any],
           let timedModel = model["timedLyricsModel"] as? [String: Any],
           let data = timedModel["lyricsData"] as? [String: Any],
           let timed = data["timedLyricsData"] as? [[String: Any]] {
            var lines = timed.compactMap { item -> LyricLine? in
                guard let text = item["lyricLine"] as? String,
                      let range = item["cueRange"] as? [String: Any],
                      let rawStart = range["startTimeMilliseconds"] else { return nil }
                let milliseconds: Double
                if let string = rawStart as? String { milliseconds = Double(string) ?? 0 }
                else { milliseconds = (rawStart as? NSNumber)?.doubleValue ?? 0 }
                return LyricLine(time: milliseconds / 1000, text: text == "♪" ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let first = lines.first, first.time > 0.3 { lines.insert(LyricLine(time: 0, text: ""), at: 0) }
            if !lines.isEmpty { return FetchedLyrics(lines: lines, plain: nil, provider: "YouTube Music") }
        }

        let plain: String?
        if let message = pageContents["messageRenderer"] as? [String: Any] {
            plain = youtubeRunsText(message["text"])
        } else if let section = pageContents["sectionListRenderer"] as? [String: Any],
                  let rows = section["contents"] as? [[String: Any]],
                  let shelf = rows.first?["musicDescriptionShelfRenderer"] as? [String: Any] {
            plain = youtubeRunsText(shelf["description"])
        } else {
            plain = nil
        }
        guard let plain, !plain.isEmpty, plain != "Lyrics not available" else { return nil }
        return FetchedLyrics(lines: [], plain: plain, provider: "YouTube Music")
    }

    nonisolated private static func youtubeMusicRequest(path: String, body: [String: Any]) async -> [String: Any]? {
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/\(path)?prettyPrint=false"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Apple Silicon Mac OS X) SubScreenStudio/0.11.0", forHTTPHeaderField: "User-Agent")
        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    }

    nonisolated private static func youtubeRunsText(_ value: Any?) -> String? {
        guard let object = value as? [String: Any],
              let runs = object["runs"] as? [[String: Any]] else { return nil }
        let text = runs.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    nonisolated private static func fetchLRCLib(title: String, artist: String, album: String?, duration: Double) async throws -> FetchedLyrics? {
        let titles = lyricSearchVariants(title)
        let artists = lyricSearchVariants(artist)

        // LRCLIB's exact endpoint uses album and duration to avoid returning a
        // cover, live performance, translation, or similarly named recording.
        for candidateTitle in titles.prefix(2) {
            var components = URLComponents(string: "https://lrclib.net/api/get")!
            components.queryItems = [
                URLQueryItem(name: "track_name", value: candidateTitle),
                URLQueryItem(name: "artist_name", value: artists.first ?? artist),
                URLQueryItem(name: "album_name", value: album?.isEmpty == false ? album : nil),
                URLQueryItem(name: "duration", value: duration > 1 ? String(Int(duration.rounded())) : nil)
            ].filter { $0.value != nil }
            if let exact: LRCLyricsResponse = try await lrclibRequest(components.url, as: LRCLyricsResponse.self),
               exact.instrumental != true,
               jaroWinkler(exact.trackName ?? "", title) >= 0.80,
               (artist.isEmpty || bestArtistSimilarity(exact.artistName ?? "", artist) >= 0.88),
               (duration <= 1 || exact.duration == nil || abs((exact.duration ?? duration) - duration) <= 15) {
                return lyricsResult(exact)
            }
        }

        for candidateTitle in titles.prefix(2) {
            // Start precise, then remove album because streaming services
            // often report a compilation while LRCLIB stores the single.
            for includeAlbum in [true, false] {
                var components = URLComponents(string: "https://lrclib.net/api/search")!
                components.queryItems = [
                    URLQueryItem(name: "track_name", value: candidateTitle),
                    URLQueryItem(name: "artist_name", value: artists.first?.isEmpty == false ? artists.first : nil),
                    URLQueryItem(name: "album_name", value: includeAlbum && album?.isEmpty == false ? album : nil)
                ].filter { $0.value != nil }
                if let matches: [LRCLyricsResponse] = try await lrclibRequest(components.url, as: [LRCLyricsResponse].self),
                   let selected = bestLRCLibMatch(matches, title: title, artist: artist, album: album, duration: duration) {
                    return lyricsResult(selected)
                }
            }
        }

        // LRCLIB's free-text query handles reordered collaborators and
        // separators such as “&”, “•”, “x”, and commas more reliably than the
        // structured endpoint. This is the important fallback for records such
        // as “Morad & Trobi” stored as “Trobi, Morad”.
        for query in ["\(title) \(artist)", title] where !query.trimmingCharacters(in: .whitespaces).isEmpty {
            var components = URLComponents(string: "https://lrclib.net/api/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            if let matches: [LRCLyricsResponse] = try await lrclibRequest(components.url, as: [LRCLyricsResponse].self),
               let selected = bestLRCLibMatch(matches, title: title, artist: artist, album: album, duration: duration) {
                return lyricsResult(selected)
            }
        }
        return nil
    }

    nonisolated private static func bestLRCLibMatch(_ results: [LRCLyricsResponse], title: String, artist: String, album: String?, duration: Double) -> LRCLyricsResponse? {
        var seen = Set<String>()
        let uniqueResults = results.filter { item in
            let key = item.id.map(String.init) ?? "\(canonicalLyricsText(item.trackName ?? ""))|\(canonicalLyricsText(item.artistName ?? ""))|\(Int((item.duration ?? 0).rounded()))"
            return seen.insert(key).inserted
        }
        return uniqueResults
            .filter { item in
                guard item.instrumental != true else { return false }
                let titleScore = jaroWinkler(item.trackName ?? "", title)
                let artistScore = artist.isEmpty ? 1 : bestArtistSimilarity(item.artistName ?? "", artist)
                let durationMatches = duration <= 1 || item.duration == nil || abs((item.duration ?? duration) - duration) <= 20
                return titleScore >= 0.78 && artistScore >= 0.84 && durationMatches
            }
            .max { lhs, rhs in
                lyricCandidateScore(lhs, title: title, artist: artist, album: album, duration: duration) <
                lyricCandidateScore(rhs, title: title, artist: artist, album: album, duration: duration)
            }
    }

    nonisolated private static func lrclibRequest<T: Decodable>(_ url: URL?, as type: T.Type) async throws -> T? {
        guard let url else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 10
        request.setValue("SubScreenStudio/0.5 (macOS; lyrics)", forHTTPHeaderField: "User-Agent")
        request.setValue("SubScreenStudio", forHTTPHeaderField: "Lrclib-App-Id")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    nonisolated private static func lyricsResult(_ item: LRCLyricsResponse) -> FetchedLyrics? {
        let lines = parseLRC(item.syncedLyrics ?? "")
        guard !lines.isEmpty || !(item.plainLyrics ?? "").isEmpty else { return nil }
        return FetchedLyrics(lines: lines, plain: item.plainLyrics, provider: "LRCLIB")
    }

    nonisolated private static func lyricSearchVariants(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [""] }
        let pattern = #"\s*[\(\[\{][^\)\]\}]*\b(feat|ft|remaster|live|version|official|audio|lyrics|explicit)\b[^\)\]\}]*[\)\]\}]"#
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let simplified = (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?
            .stringByReplacingMatches(in: trimmed, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
        let artistPattern = #"(\s+(feat\.?|ft\.?)\s+|\s*[,&]\s*).*$"#
        let artistRange = NSRange(simplified.startIndex..., in: simplified)
        let firstArtist = (try? NSRegularExpression(pattern: artistPattern, options: [.caseInsensitive]))?
            .stringByReplacingMatches(in: simplified, range: artistRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? simplified
        return Array(NSOrderedSet(array: [trimmed, simplified, firstArtist])).compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    nonisolated private static func lyricSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = canonicalLyricsText(lhs), right = canonicalLyricsText(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }
        if left.contains(right) || right.contains(left) { return Double(min(left.count, right.count)) / Double(max(left.count, right.count)) }
        let a = Set(left.split(separator: " ").map(String.init)), b = Set(right.split(separator: " ").map(String.init))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    nonisolated private static func canonicalLyricsText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    nonisolated private static func lyricCandidateScore(_ item: LRCLyricsResponse, title: String, artist: String, album: String?, duration: Double) -> Double {
        var score = lyricSimilarity(item.trackName ?? "", title) * 5 + lyricSimilarity(item.artistName ?? "", artist) * 3
        if let album, !album.isEmpty { score += lyricSimilarity(item.albumName ?? "", album) * 2 }
        if duration > 1, let candidateDuration = item.duration { score += max(0, 2 - abs(candidateDuration - duration) / 4) }
        if !(item.syncedLyrics ?? "").isEmpty { score += 1 }
        return score
    }

    nonisolated private static func fetchMusixmatch(title: String, artist: String, album: String?, duration: Double) async throws -> FetchedLyrics? {
        // Musixmatch retired the old apic-desktop/web-desktop identity in 2026
        // and now serves fixed decoy tracks from it. Try the current anonymous
        // mobile identities instead; every response still passes strict local
        // matching before it is shown.
        let identities = [
            (base: "https://apic-appmobile.musixmatch.com/ws/1.1", appID: "mac-ios-v2.0", agent: "Musixmatch/7.0.3 (iPhone; iOS 17.6; Scale/3.00)"),
            (base: "https://apic.musixmatch.com/ws/1.1", appID: "android-player-v1.0", agent: "Musixmatch/7.0.3 (Linux; Android 14)"),
        ]
        for identity in identities {
            if let result = try? await fetchMusixmatch(
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                base: identity.base,
                appID: identity.appID,
                userAgent: identity.agent
            ) { return result }
        }
        return nil
    }

    nonisolated private static func fetchMusixmatch(title: String, artist: String, album: String?, duration: Double, base: String, appID: String, userAgent: String) async throws -> FetchedLyrics? {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = .shared
        let session = URLSession(configuration: configuration)
        var tokenComponents = URLComponents(string: "\(base)/token.get")!
        tokenComponents.queryItems = [URLQueryItem(name: "app_id", value: appID)]
        guard let tokenURL = tokenComponents.url else { return nil }
        var tokenRequest = URLRequest(url: tokenURL); tokenRequest.timeoutInterval = 10
        tokenRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (tokenData, tokenResponse) = try await session.data(for: tokenRequest)
        guard (tokenResponse as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        guard let tokenJSON = try JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
              let token = (((tokenJSON["message"] as? [String: Any])?["body"] as? [String: Any])?["user_token"] as? String),
              !token.isEmpty,
              token.contains(where: { $0 != "0" }) else { return nil }
        let validDuration = duration >= 30 && duration <= 1200 ? String(Int(duration.rounded())) : nil
        // MediaRemote occasionally reports an album from a compilation or a
        // rounded/incorrect duration. Start precise, then relax only those two
        // hints while retaining strict title/artist validation.
        let searches: [(album: String?, duration: String?)] = [
            (album?.isEmpty == false ? album : nil, validDuration),
            (nil, validDuration),
            (nil, nil)
        ]
        for search in searches {
            if Task.isCancelled { return nil }
            var components = URLComponents(string: "\(base)/macro.subtitles.get")!
            components.queryItems = [
                URLQueryItem(name: "app_id", value: appID), URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "usertoken", value: token), URLQueryItem(name: "q_track", value: title),
                URLQueryItem(name: "q_artist", value: artist.isEmpty ? nil : artist),
                URLQueryItem(name: "q_duration", value: search.duration),
                URLQueryItem(name: "q_album", value: search.album),
                URLQueryItem(name: "namespace", value: "lyrics_richsynched"), URLQueryItem(name: "subtitle_format", value: "lrc")
            ].filter { $0.value != nil }
            guard let url = components.url else { continue }
            var request = URLRequest(url: url); request.timeoutInterval = 10
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = (root["message"] as? [String: Any])?["body"] as? [String: Any],
                  let calls = body["macro_calls"] as? [String: Any] else { continue }
            let trackMessage = ((calls["matcher.track.get"] as? [String: Any])?["message"] as? [String: Any])?["body"] as? [String: Any]
            guard let track = trackMessage?["track"] as? [String: Any],
                  let matchedTitle = track["track_name"] as? String,
                  let matchedArtist = track["artist_name"] as? String,
                  (track["track_id"] as? NSNumber)?.intValue != 115264642,
                  jaroWinkler(matchedTitle, title) >= 0.80,
                  (artist.isEmpty || bestArtistSimilarity(matchedArtist, artist) >= 0.82) else { continue }
            if let expected = search.duration.flatMap(Double.init),
               let matched = (track["track_length"] as? NSNumber)?.doubleValue,
               abs(matched - expected) > 22 { continue }
            let subtitleMessage = ((calls["track.subtitles.get"] as? [String: Any])?["message"] as? [String: Any])?["body"] as? [String: Any]
            let subtitleList = subtitleMessage?["subtitle_list"] as? [[String: Any]]
            let subtitle = (subtitleList?.first?["subtitle"] as? [String: Any])?["subtitle_body"] as? String
            let lyricsMessage = ((calls["track.lyrics.get"] as? [String: Any])?["message"] as? [String: Any])?["body"] as? [String: Any]
            let plain = (lyricsMessage?["lyrics"] as? [String: Any])?["lyrics_body"] as? String
            guard subtitle != nil || plain != nil else { continue }
            return FetchedLyrics(lines: parseLRC(subtitle ?? ""), plain: plain, provider: "Musixmatch")
        }
        return nil
    }

    nonisolated private static func bestArtistSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let separators = CharacterSet(charactersIn: "&,/;•·+×")
        let splitArtists: (String) -> [String] = { value in
            let normalized = value
                .replacingOccurrences(of: #"\s+(feat\.?|ft\.?)\s+"#, with: ",", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"\s+[xX]\s+"#, with: ",", options: .regularExpression)
            return normalized.components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let left = splitArtists(lhs), right = splitArtists(rhs)
        let pairScore = left.flatMap { a in right.map { b in jaroWinkler(a, b) } }.max() ?? 0
        // Also compare the complete unordered artist sets. This makes
        // “Morad & Trobi” equivalent to “Trobi, Morad” without accepting an
        // unrelated collaboration solely because it shares one guest artist.
        let leftSet = Set(left.map(canonicalLyricsText))
        let rightSet = Set(right.map(canonicalLyricsText))
        let setScore: Double
        if !leftSet.isEmpty, !rightSet.isEmpty {
            setScore = Double(leftSet.intersection(rightSet).count) / Double(leftSet.union(rightSet).count)
        } else {
            setScore = 0
        }
        return max(pairScore, setScore)
    }

    /// Unicode-safe Jaro-Winkler matching, mirroring Pear's strict provider
    /// validation without translating or romanizing the source metadata.
    nonisolated private static func jaroWinkler(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(canonicalLyricsText(lhs)), b = Array(canonicalLyricsText(rhs))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let distance = max(a.count, b.count) / 2 - 1
        var aMatch = Array(repeating: false, count: a.count)
        var bMatch = Array(repeating: false, count: b.count)
        var matches = 0
        for i in a.indices {
            let lower = max(0, i - max(0, distance))
            let upper = min(i + max(0, distance) + 1, b.count)
            guard lower < upper else { continue }
            for j in lower..<upper where !bMatch[j] && a[i] == b[j] {
                aMatch[i] = true; bMatch[j] = true; matches += 1; break
            }
        }
        guard matches > 0 else { return 0 }
        let matchedA = a.indices.filter { aMatch[$0] }.map { a[$0] }
        let matchedB = b.indices.filter { bMatch[$0] }.map { b[$0] }
        let transpositions = zip(matchedA, matchedB).filter { $0 != $1 }.count / 2
        let m = Double(matches)
        let jaro = (m / Double(a.count) + m / Double(b.count) + (m - Double(transpositions)) / m) / 3
        let prefix = zip(a, b).prefix(while: { $0 == $1 }).prefix(4).count
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    nonisolated private static func fetchMegalobiz(title: String, artist: String, duration: Double) async throws -> FetchedLyrics? {
        var components = URLComponents(string: "https://www.megalobiz.com/search/all")!
        components.queryItems = [URLQueryItem(name: "qry", value: "\(artist) \(title)")]
        guard let searchURL = components.url else { return nil }
        let (searchData, _) = try await URLSession.shared.data(from: searchURL)
        let html = String(decoding: searchData, as: UTF8.self)
        let anchorPattern = #"<a[^>]*class=\"[^\"]*entity_name[^\"]*\"[^>]*>|<a[^>]*href=\"/lrc/maker/[^\"]+\"[^>]*>"#
        guard let anchorRegex = try? NSRegularExpression(pattern: anchorPattern, options: [.caseInsensitive]) else { return nil }
        let matches = anchorRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var candidates: [(url: URL, score: Double)] = []
        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            let anchor = String(html[range])
            guard let path = firstRegexGroup(#"href=\"(/lrc/maker/[^\"]+)\""#, in: anchor),
                  let url = URL(string: "https://www.megalobiz.com" + path) else { continue }
            let rawName = firstRegexGroup(#"name=\"([^\"]+)\""#, in: anchor) ?? ""
            let durationText = firstRegexGroup(#"title=\"\[(\d+:\d+(?:\.\d+)?)\]"#, in: anchor) ?? ""
            let parts = rawName.replacingOccurrences(of: "&amp;", with: "&")
                .components(separatedBy: " - ")
            let candidateArtist = parts.count > 1 ? parts.dropLast().joined(separator: " - ") : ""
            let candidateTitle = parts.last ?? rawName
            let titleScore = jaroWinkler(candidateTitle, title)
            let artistScore = artist.isEmpty || candidateArtist.isEmpty ? 1 : bestArtistSimilarity(candidateArtist, artist)
            let candidateDuration = parseClockDuration(durationText)
            let durationDelta = duration > 1 && candidateDuration > 0 ? abs(candidateDuration - duration) : 0
            guard titleScore >= 0.80, artistScore >= 0.75, durationDelta <= 15 else { continue }
            candidates.append((url, titleScore * 5 + artistScore * 3 - durationDelta / 15))
        }
        guard let lyricURL = candidates.max(by: { $0.score < $1.score })?.url else { return nil }
        let (pageData, _) = try await URLSession.shared.data(from: lyricURL)
        let page = String(decoding: pageData, as: UTF8.self)
        let lyricPattern = #"<span[^>]*id=\"lrc_[^\"]*_lyrics\"[^>]*>([\s\S]*?)</span>"#
        guard let lyricRegex = try? NSRegularExpression(pattern: lyricPattern, options: [.caseInsensitive]),
              let lyricMatch = lyricRegex.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)),
              let lyricRange = Range(lyricMatch.range(at: 1), in: page) else { return nil }
        let raw = String(page[lyricRange]).replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
        let lines = parseLRC(raw)
        return lines.isEmpty ? nil : FetchedLyrics(lines: lines, plain: nil, provider: "Megalobiz")
    }

    nonisolated private static func firstRegexGroup(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    nonisolated private static func parseClockDuration(_ value: String) -> Double {
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }

    nonisolated private static func readAppleMusicArtwork() async -> NSImage? {
        await Task.detached(priority: .utility) {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("SubScreenStudio-AppleMusic-artwork").path
            let script = """
            tell application "Music"
                if player state is not stopped and (count of artworks of current track) > 0 then
                    set artworkData to data of artwork 1 of current track
                    set targetFile to POSIX file "\(path)"
                    try
                        set handle to open for access targetFile with write permission
                        set eof handle to 0
                        write artworkData to handle starting at 0
                        close access handle
                        return "\(path)"
                    on error
                        try
                            close access targetFile
                        end try
                    end try
                end if
            end tell
            return ""
            """
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0,
                  !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return NSImage(contentsOfFile: path)
        }.value
    }

    nonisolated private static func parseLRC(_ contents: String) -> [LyricLine] {
        contents.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            guard let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]"), close > open else { return nil }
            let stamp = line[line.index(after: open)..<close].split(separator: ":")
            guard stamp.count == 2, let minute = Double(stamp[0]), let second = Double(stamp[1]) else { return nil }
            let text = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : LyricLine(time: minute * 60 + second, text: text)
        }.sorted { $0.time < $1.time }
    }

    func clearTransientMedia() {
        artworkTask?.cancel()
        lyricsTask?.cancel()
        artwork = nil
        lyricLines = []
        plainLyrics = nil
    }
}

struct WeatherPlace: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let country: String?
    let admin1: String?

    var displayName: String {
        var values = [name]
        if let admin1, !admin1.isEmpty, !values.contains(admin1) { values.append(admin1) }
        if let country, !country.isEmpty, !values.contains(country) { values.append(country) }
        return values.joined(separator: ", ")
    }
}

enum WeatherSearchService {
    private struct Response: Decodable { let results: [WeatherPlace]? }

    static func search(_ query: String) async -> [WeatherPlace] {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return [] }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "8"),
            URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return decoded.results ?? []
    }
}

struct NewsHeadline: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let link: String
}

@MainActor
final class NewsFeedMonitor: ObservableObject {
    static let shared = NewsFeedMonitor()
    @Published private(set) var feeds: [String: [NewsHeadline]] = [:]
    @Published private(set) var errors: [String: String] = [:]
    private var loading = Set<String>()

    func headlines(for url: String) -> [NewsHeadline] { feeds[url] ?? [] }

    func refresh(_ urlString: String) {
        guard !loading.contains(urlString), let url = URL(string: urlString) else { return }
        loading.insert(urlString)
        Task {
            defer { loading.remove(urlString) }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 12
                request.setValue("SubScreenStudio/0.3", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { throw URLError(.badServerResponse) }
                let parser = FeedParser()
                guard XMLParser(data: data).parse(with: parser) else { throw URLError(.cannotParseResponse) }
                feeds[urlString] = Array(parser.items.prefix(12))
                errors[urlString] = nil
            } catch {
                errors[urlString] = "Feed unavailable"
            }
        }
    }
}

private final class FeedParser: NSObject, XMLParserDelegate {
    var items: [NewsHeadline] = []
    private var insideItem = false
    private var element = ""
    private var title = ""
    private var link = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        element = elementName.lowercased()
        if element == "item" || element == "entry" { insideItem = true; title = ""; link = "" }
        if insideItem && element == "link", let href = attributeDict["href"] { link = href }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideItem else { return }
        if element == "title" { title += string }
        if element == "link" { link += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if name == "item" || name == "entry" {
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { items.append(NewsHeadline(title: clean, link: link.trimmingCharacters(in: .whitespacesAndNewlines))) }
            insideItem = false
        }
        element = ""
    }
}

@MainActor
final class AudioLevelMonitor: ObservableObject {
    static let shared = AudioLevelMonitor()
    @Published private(set) var levels = Array(repeating: 0.08, count: 18)
    @Published private(set) var status = "Microphone is off"
    private let engine = AVAudioEngine()
    private var started = false

    func start() {
        guard !started else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: beginCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in granted ? self.beginCapture() : (self.status = "Microphone permission denied") }
            }
        default: status = "Enable Microphone in System Settings"
        }
    }

    func stop() {
        guard started else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        started = false
        status = "Microphone is off"
    }

    private func beginCapture() {
        guard !started else { return }
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { status = "No audio input available"; return }
        // About 20 visual updates per second is fluid on the small displays and
        // halves the sampling/redraw work versus the previous tap.
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var output = Array(repeating: 0.0, count: 18)
            let stride = max(1, count / output.count)
            for index in output.indices {
                let start = index * stride
                let end = min(count, start + stride)
                var total: Float = 0
                for sample in start..<end { total += abs(samples[sample]) }
                let average = Double(total) / Double(max(1, end - start))
                output[index] = min(1, max(0.04, pow(average * 6, 0.55)))
            }
            Task { @MainActor in self?.levels = output }
        }
        do {
            engine.prepare()
            try engine.start()
            started = true
            status = "Live microphone audio"
        } catch {
            node.removeTap(onBus: 0)
            status = "Audio input unavailable"
        }
    }
}

@MainActor
final class CodexBridgeMonitor: ObservableObject {
    static let shared = CodexBridgeMonitor()
    @Published private(set) var usedPercent: Double?
    @Published private(set) var resetDate: Date?
    @Published private(set) var pendingApproval: String?
    @Published private(set) var status = "Connecting to Codex…"
    @Published private(set) var connected = false

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var timer: Timer?

    private init() {
        start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    func start() {
        guard process == nil else { return }
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        guard let executable = candidates.first(where: FileManager.default.fileExists(atPath:)) else {
            status = "Codex CLI not found"
            return
        }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                self?.connected = false
                self?.status = "Codex bridge stopped"
            }
        }
        do {
            try process.run()
            self.process = process
            input = stdin.fileHandleForWriting
            send(["method": "initialize", "id": 1, "params": ["clientInfo": ["name": "subscreen_studio", "title": "SubScreen Studio", "version": "0.3.0"]]])
        } catch {
            status = "Could not start Codex bridge"
        }
    }

    func refresh() { send(["method": "account/rateLimits/read", "id": 2]) }

    func stop() {
        timer?.invalidate()
        timer = nil
        input?.closeFile()
        input = nil
        process?.terminate()
        process = nil
    }

    private func send(_ object: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var line = data
        line.append(0x0A)
        try? input.write(contentsOf: line)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func handle(_ object: [String: Any]) {
        if (object["id"] as? Int) == 1, object["result"] != nil {
            connected = true
            status = "Live Codex account"
            send(["method": "initialized", "params": [:]])
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            return
        }
        if let method = object["method"] as? String {
            if method == "account/rateLimits/updated", let params = object["params"] as? [String: Any] {
                parseRateLimits(params)
            }
            if method.localizedCaseInsensitiveContains("requestApproval") || method == "tool/requestUserInput" || method.localizedCaseInsensitiveContains("elicitation") {
                pendingApproval = method.contains("command") ? "Command approval needed" : "Codex needs your approval"
            }
        }
        if (object["id"] as? Int) == 2, let result = object["result"] as? [String: Any] { parseRateLimits(result) }
    }

    private func parseRateLimits(_ root: [String: Any]) {
        let rate = (root["rateLimits"] as? [String: Any]) ?? root
        guard let primary = rate["primary"] as? [String: Any] else { return }
        if let used = primary["usedPercent"] as? NSNumber { usedPercent = used.doubleValue }
        if let reset = primary["resetsAt"] as? NSNumber { resetDate = Date(timeIntervalSince1970: reset.doubleValue) }
    }
}

private extension XMLParser {
    func parse(with delegate: XMLParserDelegate) -> Bool {
        self.delegate = delegate
        return parse()
    }
}
