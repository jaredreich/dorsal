import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import Combine
import SFBAudioEngine

actor EqualizerActor {
    private let equalizerNode: AVAudioUnitEQ
    nonisolated let node: AVAudioUnitEQ
    private let lock = OSAllocatedUnfairLock()

    init(frequencies: [Float], bandwidth: Float = 1.0) {
        let bandCount = frequencies.count
        let eq = AVAudioUnitEQ(numberOfBands: bandCount)
        for (i, freq) in frequencies.enumerated() {
            guard i < eq.bands.count else { break }
            let band = eq.bands[i]
            band.filterType = .parametric
            band.frequency = freq
            band.bandwidth = bandwidth
            band.bypass = false
        }
        self.equalizerNode = eq
        self.node = eq
    }

    func setGain(band: Int, gain: Float) {
        lock.lock()
        defer { lock.unlock() }
        guard band >= 0 && band < equalizerNode.bands.count else { return }
        equalizerNode.bands[band].gain = gain
    }

    func setGains(_ gains: [Float], enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<min(gains.count, equalizerNode.bands.count) {
            equalizerNode.bands[i].gain = enabled ? gains[i] : 0
        }
    }

    func setEnabled(_ enabled: Bool, gains: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<min(gains.count, equalizerNode.bands.count) {
            equalizerNode.bands[i].gain = enabled ? gains[i] : 0
        }
    }

    func getGains() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return equalizerNode.bands.map { $0.gain }
    }
}

@MainActor
class AudioPlayerManager: NSObject, ObservableObject {
    static let shared = AudioPlayerManager()

    private let playbackQueue = PlaybackQueue()

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isPlaybackPrepared: Bool = false
    @Published var isLoading: Bool = false
    var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var currentSong: Song?
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
    private let equalizerActor = EqualizerActor(frequencies: EqualizerPreset.bandFrequencies)
    private var timeTracker: Timer?
    private var pendingSeekTime: TimeInterval?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var nowPlayingArtworkKey: String?
    private var loadingArtworkKey: String?
    private var audioSessionActive = false

    private struct PersistedPlaybackState: Codable {
        let albumId: String
        let songId: String
        let currentTime: TimeInterval
        // Optional for backward compatibility; paused restores ignore it.
        let wasPlaying: Bool?
    }
    private var hasTriggeredPrefetch: Bool = false
    private var nextEnqueuedSongId: String?
    private var pendingPlaybackSongId: String?
    private var preparingSongId: String?
    private(set) var desiredPlaying = false
    private var loadGeneration = 0
    // Suppresses play while a paused restore is loading.
    private var isPausedRestoreInProgress = false
    private var preservedPlaybackIntent: Bool?

    private var isPreparingPlayback: Bool { preparingSongId != nil }


    private let downloadManager: any DownloadManaging
    private let searchManager: any SearchManaging
    private let imageCache: any ImageCaching

    init(downloadManager: (any DownloadManaging)? = nil,
         searchManager: (any SearchManaging)? = nil,
         imageCache: (any ImageCaching)? = nil) {
        self.downloadManager = downloadManager ?? DownloadManager.shared
        self.searchManager = searchManager ?? SearchManager.shared
        self.imageCache = imageCache ?? ImageCacheManager.shared
        super.init()
        audioPlayer.delegate = self
        loadEqualizerState()
        setupAudioSession()
        setupEqualizer()
        setupRemoteTransportControls()
        updateRemoteCommandAvailability()
        setupNotifications()
        startTimeTracking()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            // Don't activate at launch; an idle active session makes iOS treat
            // the app as playing. Activation happens on play/prepare.
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }

    @discardableResult
    func activateAudioSession() -> Bool {
        guard (try? AVAudioSession.sharedInstance().setActive(true)) != nil else {
            return false
        }
        audioSessionActive = true
        return true
    }

    // `AudioPlayer.pause()` leaves AVAudioEngine running, so iOS still treats
    // the app as playing. Stop the engine instead; keep the session active so
    // Now Playing and remote commands stay with this app.
    private func suspendEngineIfPaused(keepEngineRunning: Bool = false) {
        guard currentSong != nil, !isPlaying, !isPreparingPlayback else { return }

        if keepEngineRunning {
            // Keep the first play after a paused restore instant.
            updateNowPlayingInfo()
            return
        }

        if audioPlayer.engineIsRunning {
            if let time = audioPlayer.time?.current, time.isFinite {
                currentTime = time
            }
            audioPlayer.stop()
            nextEnqueuedSongId = nil
            isPlaybackPrepared = false
        }

        updateNowPlayingInfo()
    }

    private func deactivateAudioSession() {
        guard audioSessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false)
        audioSessionActive = false
    }

    private func setupEqualizer() {
        let eq = equalizerActor.node
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
            Task { await equalizerActor.setGain(band: band, gain: gain) }
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
        Task { await equalizerActor.setGains(equalizerGains, enabled: isEqualizerEnabled) }
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
              downloadManager.isCached(songId: nextSong.id) else { return }

        guard let url = downloadManager.existingStorageUrl(for: nextSong.id) else { return }
        do {
            try audioPlayer.enqueue(makeDecoder(for: url))
            nextEnqueuedSongId = nextSong.id
        } catch {}
    }

    func play(song: Song, autoPlay: Bool = true) {
        pendingSeekTime = nil
        isPausedRestoreInProgress = false
        prepare(song: song, shouldPlayWhenReady: autoPlay)
    }

    func play(queue: [Song], startIndex: Int = 0, autoPlay: Bool = true) {
        isPausedRestoreInProgress = false
        startPlayback(queue: queue, startIndex: startIndex, shouldPlayWhenReady: autoPlay)
    }

    private func startPlayback(queue: [Song], startIndex: Int, shouldPlayWhenReady: Bool, seekTime: TimeInterval? = nil) {
        playbackQueue.setQueue(queue, startIndex: startIndex)
        guard let song = playbackQueue.currentSong else { return }
        pendingSeekTime = seekTime
        prepare(song: song, shouldPlayWhenReady: shouldPlayWhenReady)
    }

    private func prepare(song: Song, shouldPlayWhenReady: Bool) {
        loadGeneration += 1
        let generation = loadGeneration

        preparingSongId = song.id
        isPlaybackPrepared = false
        desiredPlaying = shouldPlayWhenReady
        pendingPlaybackSongId = nil
        activateAudioSession()
        updateRemoteCommandAvailability()

        let isCached = downloadManager.isCached(songId: song.id)

        if isCached {
            isLoading = false
            audioPlayer.stop()
            audioPlayer.clearQueue()
            nextEnqueuedSongId = nil
            pendingPlaybackSongId = nil
            hasTriggeredPrefetch = false
        } else {
            isLoading = true
            hasTriggeredPrefetch = false
        }

        let songId = song.id

        Task {
            do {
                let cachedUrl = try await downloadManager.downloadAndCache(song)
                guard self.loadGeneration == generation else { return }

                if !isCached {
                    self.audioPlayer.stop()
                    self.audioPlayer.clearQueue()
                    self.nextEnqueuedSongId = nil
                    self.pendingPlaybackSongId = nil
                }

                self.isLoading = false
                self.currentSong = song

                self.pendingPlaybackSongId = songId
                try self.audioPlayer.play(self.makeDecoder(for: cachedUrl))

                self.duration = self.audioPlayer.time?.total ?? song.duration ?? 0

                if let seekTime = self.pendingSeekTime {
                    self.audioPlayer.seek(time: seekTime)
                    self.currentTime = seekTime
                    self.pendingSeekTime = nil
                } else {
                    self.currentTime = 0
                }

                if !self.desiredPlaying {
                    self.audioPlayer.pause()
                } else {
                    self.preservedPlaybackIntent = nil
                }

                self.isPlaybackPrepared = true
                if self.preparingSongId == songId { self.preparingSongId = nil }
                let keepEngineRunning = self.isPausedRestoreInProgress
                self.isPausedRestoreInProgress = false
                self.syncPlaybackStateFromEngine()
                self.savePlaybackState()
                self.suspendEngineIfPaused(keepEngineRunning: keepEngineRunning)
                self.downloadManager.addToRecentlyPlayed(albumId: song.albumId)
            } catch {
                guard self.loadGeneration == generation else { return }
                self.isLoading = false
                self.isPlaybackPrepared = false
                self.pendingPlaybackSongId = nil
                if self.preparingSongId == songId { self.preparingSongId = nil }
                self.isPausedRestoreInProgress = false
                self.syncPlaybackStateFromEngine()
            }
        }
    }

    func updateQueue(_ songs: [Song]) {
        playbackQueue.updateQueue(songs)
        objectWillChange.send()
    }

    func togglePlayPause() {
        if audioPlayer.isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func pause() {
        desiredPlaying = false
        isPausedRestoreInProgress = false
        preservedPlaybackIntent = nil
        audioPlayer.pause()
        if let time = audioPlayer.time?.current, time.isFinite {
            currentTime = time
        }
        syncPlaybackStateFromEngine()
        savePlaybackState()
        suspendEngineIfPaused()
    }

    @discardableResult
    func resume() -> Bool {
        guard let song = currentSong else {
            return false
        }

        if isPreparingPlayback {
            if isPausedRestoreInProgress {
                return false
            }
            desiredPlaying = true
            preservedPlaybackIntent = nil
            return true
        }

        activateAudioSession()

        let engineAlive = audioPlayer.engineIsRunning && audioPlayer.time?.current != nil

        isPausedRestoreInProgress = false
        preservedPlaybackIntent = nil
        desiredPlaying = true

        if engineAlive {
            audioPlayer.resume()
            syncPlaybackStateFromEngine()
            if isPlaying {
                savePlaybackState()
            } else {
                pendingSeekTime = currentTime > 0 ? currentTime : nil
                prepare(song: song, shouldPlayWhenReady: true)
            }
        } else {
            pendingSeekTime = currentTime > 0 ? currentTime : nil
            prepare(song: song, shouldPlayWhenReady: true)
        }
        return true
    }

    func verifyAndRestorePlaybackState() {
        guard desiredPlaying, currentSong != nil, !isPreparingPlayback else { return }

        let engineAlive = audioPlayer.engineIsRunning && audioPlayer.time?.current != nil
        if engineAlive {
            syncPlaybackStateFromEngine()
            return
        }

        let savedCurrentTime = currentTime
        let savedDuration = duration
        let index = playbackQueue.currentIndex
        let queue = playbackQueue.queue

        guard !queue.isEmpty, index < queue.count else {
            syncPlaybackStateFromEngine()
            return
        }

        isPausedRestoreInProgress = false
        pendingSeekTime = savedCurrentTime > 0 ? savedCurrentTime : nil
        prepare(song: queue[index], shouldPlayWhenReady: true)

        if savedDuration > 0 && duration == 0 {
            duration = savedDuration
        }
    }

    // MARK: - Audio Route

    private var isCarAudioRouteActive: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
    }

    @objc private func handleRouteChange(_ notification: Notification) {

        if isCarAudioRouteActive {
            activateAudioSession()
            syncPlaybackStateFromEngine()
        } else if !isPlaying {
            suspendEngineIfPaused()
        }
    }

    func seek(to time: TimeInterval, completion: (() -> Void)? = nil) {
        let clamped = max(0, time)
        if let currentPos = audioPlayer.time?.current, abs(currentPos - clamped) < 0.1 {
            currentTime = clamped
            syncPlaybackStateFromEngine()
            completion?()
            return
        }
        currentTime = clamped
        // No decoder while stopped/loading; apply this on resume.
        if isPreparingPlayback || !audioPlayer.engineIsRunning {
            pendingSeekTime = clamped
        }
        audioPlayer.seek(time: clamped)
        syncPlaybackStateFromEngine()
        savePlaybackState()
        completion?()
    }

    func playNext() {
        guard hasNext else { return }
        if let nextSong = playbackQueue.next() {
            play(song: nextSong, autoPlay: desiredPlaying)
        }
    }

    func playPrevious() {
        if currentTime < 2 {
            if let previousSong = playbackQueue.previous() {
                play(song: previousSong, autoPlay: desiredPlaying)
            } else {
                seek(to: 0)
            }
        } else {
            seek(to: 0)
        }
    }

    func stop() {
        loadGeneration += 1
        preparingSongId = nil
        desiredPlaying = false
        audioPlayer.stop()
        audioPlayer.clearQueue()
        nextEnqueuedSongId = nil
        pendingPlaybackSongId = nil
        pendingSeekTime = nil
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        currentSong = nil
        nowPlayingArtwork = nil
        nowPlayingArtworkKey = nil
        loadingArtworkKey = nil
        isPlaybackPrepared = false
        isPausedRestoreInProgress = false
        preservedPlaybackIntent = nil
        playbackQueue.clear()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateRemoteCommandAvailability()
        if !isCarAudioRouteActive {
            deactivateAudioSession()
        }
        UserDefaults.standard.removeObject(forKey: "playbackState")
    }

    private func savePlaybackState() {
        guard let song = currentSong else {
            UserDefaults.standard.removeObject(forKey: "playbackState")
            return
        }
        let state = PersistedPlaybackState(
            albumId: song.albumId,
            songId: song.id,
            currentTime: currentTime,
            wasPlaying: isPlaying || (preservedPlaybackIntent ?? false)
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: "playbackState")
        }
    }

    func restorePersistedState(resumeAfterLoad: Bool = false, suppressAutomaticPlay: Bool = false, preservePlaybackIntent: Bool = false) {
        guard currentSong == nil else {
            return
        }
        guard let data = UserDefaults.standard.data(forKey: "playbackState"),
              let state = try? JSONDecoder().decode(PersistedPlaybackState.self, from: data) else {
            return
        }

        let songs = searchManager.getSongsForAlbum(state.albumId).sortedByTrack()
        guard let index = songs.firstIndex(where: { $0.id == state.songId }) else {
            return
        }


        // Publish metadata before loading so Now Playing isn't blank.
        let song = songs[index]
        currentSong = song
        currentTime = state.currentTime
        if let songDuration = song.duration, songDuration > 0 { duration = songDuration }
        activateAudioSession()
        updateNowPlayingInfo()

        isPausedRestoreInProgress = suppressAutomaticPlay && !resumeAfterLoad
        if resumeAfterLoad {
            preservedPlaybackIntent = nil
        } else if preservePlaybackIntent {
            preservedPlaybackIntent = state.wasPlaying ?? false
        } else {
            preservedPlaybackIntent = nil
        }
        startPlayback(
            queue: songs,
            startIndex: index,
            shouldPlayWhenReady: resumeAfterLoad,
            seekTime: state.currentTime > 0 ? state.currentTime : nil
        )
    }

    func persistPlaybackState() {
        guard currentSong != nil else { return }
        savePlaybackState()
    }

    func preparePausedPlayback() {
        preservedPlaybackIntent = nil
        desiredPlaying = false

        if isPreparingPlayback {
            isPausedRestoreInProgress = true
            return
        }

        guard let song = currentSong else {
            restorePersistedState(resumeAfterLoad: false, suppressAutomaticPlay: true)
            return
        }

        if audioPlayer.engineIsRunning, audioPlayer.time?.current != nil {
            audioPlayer.pause()
            isPlaybackPrepared = true
            syncPlaybackStateFromEngine()
            savePlaybackState()
            return
        }

        let savedCurrentTime = currentTime
        let savedDuration = duration

        isPausedRestoreInProgress = true
        pendingSeekTime = savedCurrentTime > 0 ? savedCurrentTime : nil
        prepare(song: song, shouldPlayWhenReady: false)

        if savedDuration > 0 { duration = savedDuration }
    }

    private func startTimeTracking() {
        timeTracker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                guard self.audioPlayer.isPlaying || self.isPlaying else { return }

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

        if downloadManager.isCached(songId: nextSong.id) {
            enqueueNextSong()
        } else {
            Task {
                _ = try? await downloadManager.downloadAndCache(nextSong)
                self.enqueueNextSong()
            }
        }
    }

    private func syncPlaybackStateFromEngine() {
        let engineIsPlaying = audioPlayer.isPlaying

        if isPlaying != engineIsPlaying {
            isPlaying = engineIsPlaying
        }

        if !isPreparingPlayback, currentSong != nil {
            isPlaybackPrepared = audioPlayer.engineIsRunning
        }

        updateNowPlayingInfo()
        updateRemoteCommandAvailability()
    }

    private func updateRemoteCommandAvailability() {
        let commandCenter = MPRemoteCommandCenter.shared()
        let hasSong = currentSong != nil
        // Keep scrub enabled while paused; seek is applied when playback resumes.
        let canSeek = hasSong && !isPreparingPlayback

        commandCenter.playCommand.isEnabled = hasSong
        commandCenter.pauseCommand.isEnabled = hasSong
        commandCenter.togglePlayPauseCommand.isEnabled = hasSong
        commandCenter.nextTrackCommand.isEnabled = hasSong && hasNext
        commandCenter.previousTrackCommand.isEnabled = hasSong
        commandCenter.changePlaybackPositionCommand.isEnabled = canSeek
    }

    private func updateNowPlayingInfo() {
        guard let song = currentSong else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let albumArtUrl = downloadManager.getAlbumArtUrl(for: song.albumId)
        let localImageUrl = FileManager.default.fileExists(atPath: albumArtUrl.path) ? albumArtUrl : nil
        let artworkKey = localImageUrl?.absoluteString ?? song.imageUrl

        if artworkKey != nowPlayingArtworkKey {
            nowPlayingArtwork = nil
            nowPlayingArtworkKey = nil
        }

        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        let safeCurrentTime = currentTime.isFinite ? max(0, currentTime) : 0

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.name,
            MPMediaItemPropertyArtist: song.artistName,
            MPMediaItemPropertyAlbumTitle: song.albumName,
            MPMediaItemPropertyAlbumArtist: song.artistName,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: safeCurrentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            // Resume rate, not current rate. Leaving this at 1.0 keeps paused
            // items playable in system media controls.
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]

        if safeDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = safeDuration
        }
        if let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }

        // iOS derives play/pause from playbackRate; playbackState is ignored.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtworkIfNeeded(for: song, key: artworkKey, localImageUrl: localImageUrl)
    }

    private func loadArtworkIfNeeded(for song: Song, key: String?, localImageUrl: URL?) {
        if key == nowPlayingArtworkKey { return }
        if key == loadingArtworkKey { return }
        guard let key else { return }

        loadingArtworkKey = key

        let songId = song.id
        Task {
            let image = await imageCache.loadImage(
                localUrl: localImageUrl,
                remoteUrlString: song.imageUrl,
                saveToUrl: nil
            )

            guard self.loadingArtworkKey == key else { return }
            self.loadingArtworkKey = nil

            guard let image, self.currentSong?.id == songId else { return }

            self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.nowPlayingArtworkKey = key
            self.updateNowPlayingInfo()
        }
    }

    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            let status: MPRemoteCommandHandlerStatus = self.resume() ? .success : .noActionableNowPlayingItem
            return status
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.currentSong != nil else { return .noActionableNowPlayingItem }
            self.pause()
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.currentSong != nil else { return .noActionableNowPlayingItem }
            let handled: Bool
            if self.audioPlayer.isPlaying {
                self.pause()
                handled = true
            } else {
                handled = self.resume()
            }
            let status: MPRemoteCommandHandlerStatus = handled ? .success : .noActionableNowPlayingItem
            return status
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.currentSong != nil, self.hasNext else { return .noActionableNowPlayingItem }
            Task { @MainActor [weak self] in self?.playNext() }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.currentSong != nil else { return .noActionableNowPlayingItem }
            Task { @MainActor [weak self] in self?.playPrevious() }
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, self.currentSong != nil else { return .noActionableNowPlayingItem }
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                self.seek(to: event.positionTime)
                return .success
            }
            return .commandFailed
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppForeground),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func handleAppBackground() {
        if let time = audioPlayer.time?.current, time.isFinite {
            currentTime = time
        }
        syncPlaybackStateFromEngine()
        savePlaybackState()
        suspendEngineIfPaused()
    }

    @objc private func handleAppForeground() {
        if let time = audioPlayer.time?.current, time.isFinite {
            currentTime = time
        }
        syncPlaybackStateFromEngine()
        suspendEngineIfPaused()
    }

    @objc private func handleMediaServicesReset() {
        // The reset invalidates the engine/session and can clear Now Playing.
        setupAudioSession()
        syncPlaybackStateFromEngine()
        suspendEngineIfPaused()
        if desiredPlaying, currentSong != nil {
            Task { @MainActor in
                self.verifyAndRestorePlaybackState()
            }
        }
    }

    deinit {
        timeTracker?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}

extension AudioPlayerManager: AudioPlayer.Delegate {
    nonisolated func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState) {
        Task { @MainActor in
            let engineIsPlaying = self.audioPlayer.isPlaying

            if engineIsPlaying && !self.desiredPlaying {
                // SFBAudioEngine can resume after an interruption; respect the
                // user's pause instead of publishing a false playing state.
                self.audioPlayer.pause()
                if let time = self.audioPlayer.time?.current, time.isFinite {
                    self.currentTime = time
                }
                self.syncPlaybackStateFromEngine()
                self.savePlaybackState()
            } else {
                self.syncPlaybackStateFromEngine()
                if engineIsPlaying {
                    self.savePlaybackState()
                }
            }
        }
    }

    nonisolated func audioPlayer(_ audioPlayer: AudioPlayer, audioSessionInterruption userInfo: [AnyHashable: Any]?) {
        Task { @MainActor in
            self.syncPlaybackStateFromEngine()
        }
    }

    nonisolated func audioPlayer(_ audioPlayer: AudioPlayer, audioEngineConfigurationChange userInfo: [AnyHashable: Any]?) {
        Task { @MainActor in
            self.syncPlaybackStateFromEngine()
        }
    }

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
                self.pendingSeekTime = nil
                self.duration = self.audioPlayer.time?.total ?? song.duration ?? 0
                self.hasTriggeredPrefetch = false
                self.isPlaybackPrepared = true
                self.desiredPlaying = self.audioPlayer.isPlaying
                self.syncPlaybackStateFromEngine()
                self.savePlaybackState()
                self.enqueueNextSong()
                downloadManager.addToRecentlyPlayed(albumId: song.albumId)
            }
        }
    }

    nonisolated func audioPlayer(_ audioPlayer: AudioPlayer, reconfigureProcessingGraph engine: AVAudioEngine, with format: AVAudioFormat) -> AVAudioNode {
        let eq = equalizerActor.node
        engine.connect(eq, to: audioPlayer.mainMixerNode, format: format)
        return eq
    }

    nonisolated func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        Task { @MainActor in
            self.nextEnqueuedSongId = nil
            self.hasTriggeredPrefetch = false

            if self.hasNext {
                self.playNext()
            } else if let firstSong = self.playbackQueue.jumpTo(index: 0) {
                self.play(song: firstSong, autoPlay: false)
            } else {
                self.syncPlaybackStateFromEngine()
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
