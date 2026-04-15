import Foundation
import AVFoundation
import MediaPlayer
import Combine
import SFBAudioEngine

@MainActor
class AudioPlayerManager: NSObject, ObservableObject {
    static let shared = AudioPlayerManager()

    private let playbackQueue = PlaybackQueue()

    @Published var isPlaying: Bool = false
    @Published var isLoading: Bool = false
    var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var currentSong: Song?
    @Published var recentlyPlayedAlbumIds: [String] = []
    @Published var isEqualizerEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEqualizerEnabled, forKey: "isEqualizerEnabled")
            applyCurrentGains()
        }
    }
    @Published var selectedPreset: EqualizerPreset = .custom {
        didSet { UserDefaults.standard.set(selectedPreset.id, forKey: "equalizerPresetId") }
    }
    @Published var equalizerGains: [Float] = EqualizerPreset.custom.gains {
        didSet { saveEqualizerGains() }
    }

    var queue: [Song] { playbackQueue.queue }
    var currentIndex: Int { playbackQueue.currentIndex }
    var hasNext: Bool { playbackQueue.hasNext }

    private let audioPlayer = AudioPlayer()
    nonisolated(unsafe) private let equalizerNode = AVAudioUnitEQ(numberOfBands: 10)
    private var timeTracker: Timer?
    private var lastArtworkUrl: String?
    private var hasTriggeredPrefetch: Bool = false
    private var nextEnqueuedSongId: String?
    private var pendingPlaybackSongId: String?

    override private init() {
        super.init()
        audioPlayer.delegate = self
        loadRecentlyPlayedAlbums()
        loadEqualizerState()
        setupAudioSession()
        setupEqualizer()
        setupRemoteTransportControls()
        setupInterruptionHandling()
        startTimeTracking()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}
    }

    private func setupEqualizer() {
        for (i, freq) in EqualizerPreset.bandFrequencies.enumerated() {
            let band = equalizerNode.bands[i]
            band.filterType = .parametric
            band.frequency = freq
            band.bandwidth = 1.0
            band.bypass = false
            band.gain = isEqualizerEnabled ? equalizerGains[i] : 0
        }

        let eq = equalizerNode
        audioPlayer.modifyProcessingGraph { engine in
            engine.attach(eq)
            let format = self.audioPlayer.sourceNode.outputFormat(forBus: 0)
            engine.connect(self.audioPlayer.sourceNode, to: eq, format: format)
            engine.connect(eq, to: self.audioPlayer.mainMixerNode, format: format)
        }
    }

    func setEqualizerBandGain(band: Int, gain: Float) {
        guard band >= 0 && band < 10 else { return }
        equalizerGains[band] = gain
        if isEqualizerEnabled {
            equalizerNode.bands[band].gain = gain
        }
    }

    func applyPreset(_ preset: EqualizerPreset) {
        selectedPreset = preset
        if preset == .custom {
            if let data = UserDefaults.standard.data(forKey: "equalizerGains"),
               let saved = try? JSONDecoder().decode([Float].self, from: data),
               saved.count == 10 {
                equalizerGains = saved
            }
        } else {
            equalizerGains = preset.gains
        }
        applyCurrentGains()
    }

    func resetCustomEqualizer() {
        equalizerGains = EqualizerPreset.custom.gains
        applyCurrentGains()
        saveEqualizerGains()
    }

    private func applyCurrentGains() {
        for i in 0..<10 {
            equalizerNode.bands[i].gain = isEqualizerEnabled ? equalizerGains[i] : 0
        }
    }

    private func loadEqualizerState() {
        isEqualizerEnabled = UserDefaults.standard.bool(forKey: "isEqualizerEnabled")
        if let presetId = UserDefaults.standard.string(forKey: "equalizerPresetId"),
           let preset = EqualizerPreset.allPresets.first(where: { $0.id == presetId }) {
            selectedPreset = preset
            if preset == .custom,
               let data = UserDefaults.standard.data(forKey: "equalizerGains"),
               let gains = try? JSONDecoder().decode([Float].self, from: data),
               gains.count == 10 {
                equalizerGains = gains
            } else {
                equalizerGains = preset.gains
            }
        }
    }

    private func saveEqualizerGains() {
        guard selectedPreset == .custom else { return }
        if let data = try? JSONEncoder().encode(equalizerGains) {
            UserDefaults.standard.set(data, forKey: "equalizerGains")
        }
    }

    private func makeDecoder(for url: URL) throws -> AudioDecoder {
        try AudioDecoder(url: url, decoderName: .coreAudio)
    }

    private func enqueueNextSong() {
        guard nextEnqueuedSongId == nil,
              playbackQueue.hasNext,
              let nextSong = playbackQueue.peekNext(),
              DownloadManager.shared.isCached(songId: nextSong.id) else { return }

        guard let url = DownloadManager.shared.existingStorageUrl(for: nextSong.id) else { return }
        do {
            try audioPlayer.enqueue(makeDecoder(for: url))
            nextEnqueuedSongId = nextSong.id
        } catch {}
    }

    func play(song: Song, autoPlay: Bool = true) {
        audioPlayer.stop()
        audioPlayer.clearQueue()
        nextEnqueuedSongId = nil
        pendingPlaybackSongId = nil
        hasTriggeredPrefetch = false
        if !autoPlay { isPlaying = false }
        currentTime = 0
        duration = 0
        isLoading = !DownloadManager.shared.isCached(songId: song.id)

        let songId = song.id

        Task {
            do {
                let cachedUrl = try await DownloadManager.shared.downloadAndCache(song)
                guard self.playbackQueue.currentSong?.id == songId else { return }

                self.isLoading = false
                self.currentSong = song

                self.pendingPlaybackSongId = songId
                try self.audioPlayer.play(self.makeDecoder(for: cachedUrl))

                self.duration = self.audioPlayer.time?.total ?? song.duration ?? 0

                if autoPlay {
                    self.isPlaying = true
                } else {
                    self.audioPlayer.pause()
                    self.isPlaying = false
                }

                self.updateNowPlayingInfo()
                self.addToRecentlyPlayed(albumId: song.albumId)
            } catch {
                self.isLoading = false
            }
        }
    }

    func play(queue: [Song], startIndex: Int = 0) {
        playbackQueue.setQueue(queue, startIndex: startIndex)
        if let song = playbackQueue.currentSong {
            play(song: song)
        }
    }

    func updateQueue(_ songs: [Song]) {
        playbackQueue.updateQueue(songs)
        objectWillChange.send()
    }

    func togglePlayPause() {
        try? audioPlayer.togglePlayPause()
        isPlaying = audioPlayer.isPlaying
        updateNowPlayingInfo()
    }

    func pause() {
        audioPlayer.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func resume() {
        audioPlayer.resume()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func seek(to time: TimeInterval, completion: (() -> Void)? = nil) {
        if let currentPos = audioPlayer.time?.current, abs(currentPos - time) < 0.1 {
            completion?()
            return
        }
        currentTime = time
        audioPlayer.seek(time: time)
        updateNowPlayingInfo()
        completion?()
    }

    func playNext() {
        if let nextSong = playbackQueue.next() {
            play(song: nextSong, autoPlay: isPlaying)
        }
    }

    func playPrevious() {
        if currentTime < 2 {
            if let previousSong = playbackQueue.previous() {
                play(song: previousSong, autoPlay: isPlaying)
            } else {
                seek(to: 0)
            }
        } else {
            seek(to: 0)
        }
    }

    func stop() {
        audioPlayer.stop()
        audioPlayer.clearQueue()
        nextEnqueuedSongId = nil
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        currentSong = nil
        lastArtworkUrl = nil
        playbackQueue.clear()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func startTimeTracking() {
        timeTracker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }

                if let time = self.audioPlayer.time {
                    if let current = time.current { self.currentTime = current }
                    if let total = time.total, total != self.duration { self.duration = total }
                }
                self.checkAndPrefetchNextSong()
            }
        }
    }

    private func checkAndPrefetchNextSong() {
        let prefetchEnabled = UserDefaults.standard.object(forKey: "prefetchNextSong") as? Bool ?? true
        guard prefetchEnabled, !hasTriggeredPrefetch else { return }
        guard duration > 0, (duration - currentTime) <= 60 else { return }
        guard hasNext, let nextSong = playbackQueue.queue[safe: currentIndex + 1] else { return }

        hasTriggeredPrefetch = true

        if DownloadManager.shared.isCached(songId: nextSong.id) {
            enqueueNextSong()
        } else {
            Task {
                _ = try? await DownloadManager.shared.downloadAndCache(nextSong)
                self.enqueueNextSong()
            }
        }
    }

    private func loadRecentlyPlayedAlbums() {
        if let data = UserDefaults.standard.data(forKey: "recentlyPlayedAlbumIds"),
           let albumIds = try? JSONDecoder().decode([String].self, from: data) {
            recentlyPlayedAlbumIds = albumIds
        }
    }

    private func saveRecentlyPlayedAlbums() {
        if let data = try? JSONEncoder().encode(recentlyPlayedAlbumIds) {
            UserDefaults.standard.set(data, forKey: "recentlyPlayedAlbumIds")
        }
    }

    private func addToRecentlyPlayed(albumId: String) {
        recentlyPlayedAlbumIds.removeAll { $0 == albumId }
        recentlyPlayedAlbumIds.insert(albumId, at: 0)
        if recentlyPlayedAlbumIds.count > 100 {
            recentlyPlayedAlbumIds = Array(recentlyPlayedAlbumIds.prefix(100))
        }
        saveRecentlyPlayedAlbums()
    }

    func clearRecentlyPlayed() {
        recentlyPlayedAlbumIds = []
        saveRecentlyPlayedAlbums()
    }

    func removeFromRecentlyPlayed(albumId: String) {
        recentlyPlayedAlbumIds.removeAll { $0 == albumId }
        saveRecentlyPlayedAlbums()
    }

    func reorderRecentlyPlayed(newOrder: [String]) {
        recentlyPlayedAlbumIds = newOrder
        saveRecentlyPlayedAlbums()
    }

    private func updateNowPlayingInfo() {
        guard let song = currentSong else { return }

        let albumArtUrl = DownloadManager.shared.getAlbumArtUrl(for: song.albumId)
        let localImageUrl = FileManager.default.fileExists(atPath: albumArtUrl.path) ? albumArtUrl : nil
        let currentArtworkUrl = localImageUrl?.absoluteString ?? song.imageUrl
        let artworkChanged = currentArtworkUrl != lastArtworkUrl

        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = song.name
        nowPlayingInfo[MPMediaItemPropertyArtist] = song.artistName
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = song.albumName
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo

        if artworkChanged {
            let songId = song.id
            Task {
                let image = await ImageCacheManager.shared.loadImage(
                    localUrl: localImageUrl,
                    remoteUrlString: song.imageUrl
                )
                guard self.currentSong?.id == songId, let image else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                // Re-read current info to avoid overwriting newer metadata
                var latestInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
                latestInfo[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = latestInfo
                self.lastArtworkUrl = currentArtworkUrl
            }
        }
    }

    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.playNext() }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.playPrevious() }
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: event.positionTime)
                return .success
            }
            return .commandFailed
        }
    }

    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            pause()
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            if AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
                resume()
            }
        @unknown default:
            break
        }
    }

    deinit {
        timeTracker?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}

extension AudioPlayerManager: AudioPlayer.Delegate {
    nonisolated func audioPlayer(_ audioPlayer: AudioPlayer, nowPlayingChanged nowPlaying: (any PCMDecoding)?) {
        Task { @MainActor in
            if self.pendingPlaybackSongId != nil {
                self.pendingPlaybackSongId = nil
                return
            }

            guard let nextId = self.nextEnqueuedSongId else { return }
            self.nextEnqueuedSongId = nil

            if let index = self.playbackQueue.queue.firstIndex(where: { $0.id == nextId }),
               let song = self.playbackQueue.jumpTo(index: index) {
                self.currentSong = song
                self.currentTime = 0
                self.duration = self.audioPlayer.time?.total ?? song.duration ?? 0
                self.hasTriggeredPrefetch = false
                self.updateNowPlayingInfo()
                self.addToRecentlyPlayed(albumId: song.albumId)
                self.enqueueNextSong()
            }
        }
    }

    nonisolated func audioPlayer(_ audioPlayer: AudioPlayer, reconfigureProcessingGraph engine: AVAudioEngine, with format: AVAudioFormat) -> AVAudioNode {
        engine.connect(equalizerNode, to: audioPlayer.mainMixerNode, format: format)
        return equalizerNode
    }

    nonisolated func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        Task { @MainActor in
            self.nextEnqueuedSongId = nil
            self.hasTriggeredPrefetch = false

            if self.hasNext {
                self.playNext()
            } else if let firstSong = self.playbackQueue.jumpTo(index: 0) {
                self.play(song: firstSong, autoPlay: false)
            }
        }
    }
}

class PlaybackQueue: ObservableObject {
    @Published private(set) var currentSong: Song?
    @Published private(set) var queue: [Song] = []
    @Published private(set) var currentIndex: Int = 0

    var hasNext: Bool { !queue.isEmpty && currentIndex < queue.count - 1 }
    var hasPrevious: Bool { !queue.isEmpty && currentIndex > 0 }

    func peekNext() -> Song? {
        guard hasNext else { return nil }
        return queue[safe: currentIndex + 1]
    }

    func setQueue(_ songs: [Song], startIndex: Int = 0) {
        queue = songs
        currentIndex = startIndex
        if !queue.isEmpty && startIndex < queue.count {
            currentSong = queue[startIndex]
        }
    }

    @discardableResult
    func next() -> Song? {
        guard hasNext else { return nil }
        currentIndex += 1
        currentSong = queue[currentIndex]
        return currentSong
    }

    @discardableResult
    func previous() -> Song? {
        guard hasPrevious else { return nil }
        currentIndex -= 1
        currentSong = queue[currentIndex]
        return currentSong
    }

    @discardableResult
    func jumpTo(index: Int) -> Song? {
        guard index >= 0 && index < queue.count else { return nil }
        currentIndex = index
        currentSong = queue[currentIndex]
        return currentSong
    }

    func updateQueue(_ songs: [Song]) {
        guard let currentSong = currentSong else { return }
        queue = songs
        if let newIndex = songs.firstIndex(where: { $0.id == currentSong.id }) {
            currentIndex = newIndex
        }
    }

    func clear() {
        queue = []
        currentIndex = 0
        currentSong = nil
    }
}

extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
