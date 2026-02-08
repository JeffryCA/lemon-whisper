import os
import whisper
import Foundation


// Meet Whisper C++ constraint: Don't access from more than one thread at a time.
actor WhisperContext {
    static var shared: WhisperContext?
    private var context: OpaquePointer?
    private var languageCString: [CChar]?
    private var prompt: String?
    private var promptCString: [CChar]?
    private var vadModelPath: String?

    private init() {}

    init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        if let context = context {
            whisper_free(context)
        }
    }

    func fullTranscribe(
        samples: [Float],
        language: String = "en",
        prompt: String? = nil,
        isLiveMode: Bool = false
    ) -> Bool {
        guard let context = context else { return false }
        
        let maxThreads = 2
        var params = whisper_full_default_params(
            isLiveMode ? WHISPER_SAMPLING_GREEDY : WHISPER_SAMPLING_BEAM_SEARCH
        )
        

        languageCString = Array(language.utf8CString)
        params.language = languageCString!.withUnsafeBufferPointer { $0.baseAddress }

        if let prompt {
            promptCString = Array(prompt.utf8CString)
            params.initial_prompt = promptCString?.withUnsafeBufferPointer { ptr in
                ptr.baseAddress
            }
        } else {
            promptCString = nil
            params.initial_prompt = nil
        }
        
        params.print_realtime = true
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_timestamps = true
        params.n_threads = Int32(maxThreads)
        params.offset_ms = 0
        params.no_context = !isLiveMode
        params.single_segment = isLiveMode
        params.suppress_blank = true
        params.suppress_nst = true
        params.temperature = 0.0
        params.temperature_inc = 0.0
        params.entropy_thold = 2.0
        params.logprob_thold = -0.8
        params.no_speech_thold = 0.7
        params.max_len = isLiveMode ? 120 : 160
        params.split_on_word = true
        params.max_initial_ts = 1.0
        params.audio_ctx = 1000
        params.beam_search.beam_size = 5
        params.beam_search.patience = 1.0

        whisper_reset_timings(context)
        
        // Configure VAD if enabled by user and model is available
        if let vadModelPath = self.vadModelPath {
            params.vad = true
            params.vad_model_path = (vadModelPath as NSString).utf8String
            
            var vadParams = whisper_vad_default_params()
            vadParams.threshold = 0.6
            vadParams.min_speech_duration_ms = 250
            vadParams.min_silence_duration_ms = 100
            vadParams.max_speech_duration_s = Float.greatestFiniteMagnitude
            vadParams.speech_pad_ms = 30
            vadParams.samples_overlap = 0.1
            params.vad_params = vadParams
        } else {
            params.vad = false
        }
        
        var success = true
        samples.withUnsafeBufferPointer { samplesBuffer in
            if whisper_full(context, params, samplesBuffer.baseAddress, Int32(samplesBuffer.count)) != 0 {
                print("Failed to run whisper_full. VAD enabled: \(params.vad)")
                success = false
            }
        }
        
        languageCString = nil
        promptCString = nil
        
        return success
    }

    func getTranscription() -> String {
        guard let context = context else { return "" }
        var collected: [String] = []
        for i in 0..<whisper_full_n_segments(context) {
            let noSpeechProb = whisper_full_get_segment_no_speech_prob(context, i)
            if noSpeechProb >= 0.6 {
                continue
            }
            let segment = String(cString: whisper_full_get_segment_text(context, i)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                collected.append(segment)
            }
        }
        return collected.joined(separator: " ")
    }

    static func createContext(path: String) async throws -> WhisperContext {
        let whisperContext = WhisperContext()
        try await whisperContext.initializeModel(path: path)
        WhisperContext.shared = whisperContext
        return whisperContext
    }
    
    private func initializeModel(path: String) throws {
        var params = whisper_context_default_params()
        #if targetEnvironment(simulator)
        params.use_gpu = false
        #endif
        
        let context = whisper_init_from_file_with_params(path, params)
        if let context {
            self.context = context
        } else {
            print("Couldn't load model at \(path)")
            throw WhisperStateError.modelLoadFailed
        }
    }
    
    func setVADModelPath(_ path: String?) {
        self.vadModelPath = path
    }

    func releaseResources() {
        if let context = context {
            whisper_free(context)
            self.context = nil
        }
        languageCString = nil
    }

    func setPrompt(_ prompt: String?) {
        self.prompt = prompt
    }

    static func getShared() -> WhisperContext? {
        return WhisperContext.shared
    }
}

fileprivate func cpuCount() -> Int {
    ProcessInfo.processInfo.processorCount
}

enum WhisperStateError: Error {
    case modelLoadFailed
}
