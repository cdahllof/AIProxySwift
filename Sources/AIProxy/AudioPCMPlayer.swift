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
@RealtimeActor
open class AudioPCMPlayer {

    private let inputFormat: AVAudioFormat
    private let playableFormat: AVAudioFormat
    private let audioEngine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private let adjustGainOniOS = true

    public init() throws {
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

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: _playableFormat)
        engine.prepare()

        self.audioEngine = engine
        self.playerNode = node
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

    public func playPCM16Audio(from base64String: String) {
        guard let audioData = Data(base64Encoded: base64String) else {
            logIf(.error)?.error("Could not decode base64 string for audio playback")
            return
        }

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

        
        self.playerNode.scheduleBuffer(outPCMBuf, at: nil, options: [], completionHandler: {})
        self.playerNode.play()
        print ("play audio")
    }

    public func interruptPlayback() {
        logIf(.debug)?.debug("Interrupting playback")
        self.playerNode.stop()
    }
    
    // Function to create WAV data from samples
    static func createWAVData(from int16Samples: [Int16], sampleRate: Int, channels: Int) -> Data {
        let bitsPerSample: Int = 16
        let bytesPerSample: Int = bitsPerSample / 8
        let subchunk1Size: Int32 = 16
        let audioFormat: Int16 = 1 // PCM
        let blockAlign: Int16 = Int16(channels * bytesPerSample)
        let byteRate: Int32 = Int32(sampleRate * channels * bytesPerSample)
        let subchunk2Size: Int32 = Int32(int16Samples.count * bytesPerSample)
        let chunkSize: Int32 = 4 + (8 + subchunk1Size) + (8 + subchunk2Size)
        
        var wavData = Data()
        // RIFF header
        wavData.append("RIFF".data(using: .ascii)!)
        wavData.append(chunkSize.littleEndianData)
        wavData.append("WAVE".data(using: .ascii)!)
        // fmt subchunk
        wavData.append("fmt ".data(using: .ascii)!)
        wavData.append(subchunk1Size.littleEndianData)
        wavData.append(audioFormat.littleEndianData)
        wavData.append(Int16(channels).littleEndianData)
        wavData.append(Int32(sampleRate).littleEndianData)
        wavData.append(byteRate.littleEndianData)
        wavData.append(blockAlign.littleEndianData)
        wavData.append(Int16(bitsPerSample).littleEndianData)
        // data subchunk
        wavData.append("data".data(using: .ascii)!)
        wavData.append(subchunk2Size.littleEndianData)
        // Append the audio data
        for sample in int16Samples {
            wavData.append(sample.littleEndianData)
        }
        return wavData
    }
}

// Extensions to convert integers to Data with little-endian representation
extension Int16 {
    var littleEndianData: Data {
        var source = self.littleEndian
        return Data(bytes: &source, count: MemoryLayout<Int16>.size)
    }
}

extension Int32 {
    var littleEndianData: Data {
        var source = self.littleEndian
        return Data(bytes: &source, count: MemoryLayout<Int32>.size)
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
