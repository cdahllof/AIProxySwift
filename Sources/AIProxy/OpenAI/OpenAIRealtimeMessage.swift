//
//  OpenAIRealtimeMessage.swift
//  AIProxy
//
//  Created by Lou Zell on 12/29/24.
//

public enum OpenAIRealtimeMessage {
    case error(String?)
    case sessionCreated // "session.created"
    case sessionUpdated // "session.updated"
    case responseCreated // "response.created"
    case responseAudioDelta(String) // "response.audio.delta"
    case inputAudioBufferSpeechStarted // "input_audio_buffer.speech_started"
    case responseDone // "response.done"
    case responseAudioDone // "response.audio.done"
    case responseTranscriptDone(String) // "response.audio_transcript.done"
    case responseFunctionCallArgumentsDone(String, String) // "response.function_call_arguments.done"
}
