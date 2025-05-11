//
//  AudioPCMPlayer.swift
//
//
//  Created by Lou Zell on 11/27/24.
//

import Foundation
import AVFoundation

/// # Warning
/// The order that you initialize `AudioPCMPlayer()` and `MicrophonePCMSampleVendor()` matters, unfortunately.
///
/// The voice processing audio unit on iOS has a volume bug that is not present on macOS.
/// The volume of playback depends on the initialization order of AVAudioEngine and the `kAudioUnitSubType_VoiceProcessingIO` Audio Unit.
/// We use AudioEngine for playback in this file, and the voice processing audio unit in MicrophonePCMSampleVendor.
///
/// I find the best result to be initializing `AudioPCMPlayer()` first. Otherwise, the playback volume is too quiet on iOS.
///
/// There are workaround here, but they don't yield good results when a user has headphones attached:
/// https://forums.developer.apple.com/forums/thread/721535
///
/// See the "Sidenote" section here for the unfortunate dependency on order:
/// https://stackoverflow.com/questions/57612695/avaudioplayer-volume-low-with-voiceprocessingio

public enum AudioPlayerEvent {
    case chunkScheduled(Int) // How many chunks are in queue
    case allAudioScheduled([Int16]) // All audio data collected
    case playbackFinished // All audio has been played
}

@RealtimeActor
open class AudioPCMPlayer {
    
    private let inputFormat: AVAudioFormat
    private let playableFormat: AVAudioFormat
    private let audioEngine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private let adjustGainOniOS = true
    
    private var scheduledBufferCount = 0
    private var completedBufferCount = 0
    
    private var continuation: AsyncStream<AudioPlayerEvent>.Continuation?
        
    private var audioChunks = [Int16]()
    private var isAllAudioReceived = false
    
    private let timePitchNode: AVAudioUnitTimePitch
    
    
    public init(playbackRate: Float = 1.0) throws {
        guard let _inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24000,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioPCMPlayerError.couldNotConfigureAudioEngine(
                "Could not create input format for AudioPCMPlayerError"
            )
        }
        
        guard let _playableFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioPCMPlayerError.couldNotConfigureAudioEngine(
                "Could not create playback format for AudioPCMPlayerError"
            )
        }
        
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        
        timePitch.rate = playbackRate
        
        engine.attach(node)
        engine.attach(timePitch)
        
        engine.connect(node, to: timePitch, format: _playableFormat)
        engine.connect(node, to: engine.mainMixerNode, format: _playableFormat)
        engine.prepare()
        
        self.audioEngine = engine
        self.playerNode = node
        self.timePitchNode = timePitch
        self.inputFormat = _inputFormat
        self.playableFormat = _playableFormat
        
#if !os(macOS)
        if self.adjustGainOniOS {
            // If you use this, and initialize the MicrophonePCMSampleVendor *after* AudioPCMPlayer,
            // then audio on iOS will be very loud. You can dial it down a bit by adjusting the gain
            // in `playPCM16Audio` below
            try? AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
        }
#endif
        
    }
    
    deinit {
        logIf(.debug)?.debug("AudioPCMPlayer is being freed")
        self.audioEngine.stop()
    }
    
    public var receiver: AsyncStream<AudioPlayerEvent> {
        return AsyncStream { continuation in
            self.continuation = continuation
        }
    }
    
    public func playPCM16Audio(from base64String: String) {
        guard let audioData = Data(base64Encoded: base64String) else {
            logIf(.error)?.error("Could not decode base64 string for audio playback")
            return
        }
        
        
        // Read Int16 samples from audioData
        let int16Samples: [Int16] = audioData.withUnsafeBytes { rawBufferPointer in
            let bufferPointer = rawBufferPointer.bindMemory(to: Int16.self)
            return Array(bufferPointer)
        }

        // **Convert mono to stereo by duplicating samples**
              var stereoSamples16 = [Int16]()
              stereoSamples16.reserveCapacity(int16Samples.count * 2)
              for sample in int16Samples {
                  stereoSamples16.append(sample) // Left channel
                  stereoSamples16.append(sample) // Right channel
              }
        
        
        
        // Store this chunk for WAV creation later
        audioChunks.append(contentsOf: stereoSamples16)
        
        
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: (
                AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(audioData.count),
                    mData: UnsafeMutableRawPointer(mutating: (audioData as NSData).bytes)
                )
            )
        )
        
        guard let inPCMBuf = AVAudioPCMBuffer(
            pcmFormat: self.inputFormat,
            bufferListNoCopy: &bufferList
        ) else {
            logIf(.error)?.error("Could not create input buffer for audio playback")
            return
        }
        
        guard let outPCMBuf = AVAudioPCMBuffer(
            pcmFormat: self.playableFormat,
            frameCapacity: AVAudioFrameCount(self.playableFormat.sampleRate * 2.0)
        ) else {
            logIf(.error)?.error("Could not create output buffer for audio playback")
            return
        }
        
        
        
        guard let converter = AVAudioConverter(from: self.inputFormat, to: self.playableFormat) else {
            logIf(.error)?.error("Could not create audio converter needed to map from pcm16int to pcm32float")
            return
        }
        
        do {
            try converter.convert(to: outPCMBuf, from: inPCMBuf)
        } catch {
            logIf(.error)?.error("Could not map from pcm16int to pcm32float: \(error.localizedDescription)")
            return
        }
        
        if !self.audioEngine.isRunning {
            do {
                try self.audioEngine.start()
            } catch {
                logIf(.error)?.error("Could not start audio engine: \(error.localizedDescription)")
                return
            }
        }
        
#if !os(macOS)
        if self.adjustGainOniOS {
            addGain(to: outPCMBuf, gain: 0.5)  // Adjust the gain to your taste. Note that this affects the headphone case too.
        }
#endif
        
        scheduledBufferCount += 1
        self.playerNode.scheduleBuffer(outPCMBuf, at: nil, options: [], completionHandler: {
            // send audio completed
            self.completedBufferCount += 1
            
            // Emit how many chunks are still in the queue
            self.continuation?.yield(.chunkScheduled(self.scheduledBufferCount-self.completedBufferCount))
            
            // If all audio is received and this was the last buffer, signal completion
            if self.isAllAudioReceived && self.scheduledBufferCount == self.completedBufferCount {
                self.continuation?.yield(.playbackFinished)
            }
        })
        self.playerNode.play()
        print ("play audio")
    }
    
    public func interruptPlayback() {
        logIf(.debug)?.debug("Interrupting playback")
        self.playerNode.stop()
        
    }

    public func signalAllAudioReceived() {
        self.isAllAudioReceived = true
        
        self.continuation?.yield(.allAudioScheduled(audioChunks))
        
        // Check if playback is already complete
        if self.scheduledBufferCount == self.completedBufferCount {
            self.continuation?.yield(.playbackFinished)
        }
    }
}


private func addGain(to buffer: AVAudioPCMBuffer, gain: Float) {
    guard let channelData = buffer.floatChannelData else {
        print("Buffer doesn't contain float32 audio data")
        return
    }

    let channelCount = Int(buffer.format.channelCount)
    let frameLength = Int(buffer.frameLength)

    for channel in 0..<channelCount {
        let samples = channelData[channel]
        for sampleIndex in 0..<frameLength {
            samples[sampleIndex] *= gain
        }
    }
}
