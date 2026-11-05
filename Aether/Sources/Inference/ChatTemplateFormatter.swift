import Foundation
import llama

/// Errors that can occur during chat template resolution and formatting.
public enum ChatTemplateError: LocalizedError, Equatable {
    case unsupportedTemplate(String)
    case formattingFailed(code: Int32)
    case emptyMessages

    public var errorDescription: String? {
        switch self {
        case .unsupportedTemplate(let msg):
            return "Chat template unsupported or invalid: \(msg)"
        case .formattingFailed(let code):
            return "Native chat template formatting failed with code \(code)."
        case .emptyMessages:
            return "Cannot format prompt from an empty message list."
        }
    }
}

/// Formatter that transforms structured conversation turns into model-specific prompt text
/// using native `llama.cpp` chat template routines.
///
/// Direct Reuse: Wraps `llama_chat_apply_template` from `llama.framework`.
public enum ChatTemplateFormatter {
    /// Standard ChatML Jinja template definition for models compatible with ChatML syntax (e.g. Qwen, Phi).
    /// Reused from standard ChatML specification.
    public static let chatMLFallback = "{% for message in messages %}{{'<|im_start|>' + message['role'] + '\\n' + message['content'] + '<|im_end|>' + '\\n'}}{% endfor %}{% if add_generation_prompt %}{{'<|im_start|>assistant\\n'}}{% endif %}"

    /// Applies a chat template to an array of messages using the embedded native `llama.cpp` API.
    ///
    /// - Parameters:
    ///   - template: Model-specific Jinja template string (or `nil` to attempt architecture fallback).
    ///   - messages: Chronologically ordered conversation messages.
    ///   - addAssistantPrompt: If `true`, appends assistant turn marker (e.g. `<|im_start|>assistant\n`).
    ///   - modelArchitecture: Optional model architecture name (e.g. "qwen2", "llama") for fallback decisions.
    /// - Returns: Fully formatted prompt text ready for tokenization.
    public static func apply(
        template: String?,
        messages: [PromptMessage],
        addAssistantPrompt: Bool = true,
        modelArchitecture: String? = nil
    ) throws -> String {
        guard !messages.isEmpty else {
            throw ChatTemplateError.emptyMessages
        }

        // 1. Resolve effective template string
        let resolvedTemplate: String
        if let template, !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedTemplate = template
        } else {
            // Validate whether fallback is appropriate for the architecture
            if let arch = modelArchitecture?.lowercased() {
                if arch.contains("qwen") || arch.contains("phi") || arch.contains("chatml") {
                    resolvedTemplate = chatMLFallback
                } else if arch.contains("llama") {
                    // Llama-3 style fallback template if none embedded
                    resolvedTemplate = "{% for message in messages %}{{'<|start_header_id|>' + message['role'] + '<|end_header_id|>\\n\\n' + message['content'] + '<|eot_id|>'}}{% endfor %}{% if add_generation_prompt %}{{'<|start_header_id|>assistant<|end_header_id|>\\n\\n'}}{% endif %}"
                } else {
                    throw ChatTemplateError.unsupportedTemplate("Model of architecture '\(arch)' lacks embedded chat template and has no verified fallback.")
                }
            } else {
                // Default to ChatML when no architecture is specified
                resolvedTemplate = chatMLFallback
            }
        }

        // 2. Allocate C message structures with strdup (safe C pointer lifetime)
        var cMessages = [llama_chat_message]()
        cMessages.reserveCapacity(messages.count)

        for msg in messages {
            guard let rolePtr = strdup(msg.role),
                  let contentPtr = strdup(msg.content) else {
                // Cleanup partial allocations on out-of-memory
                for allocated in cMessages {
                    free(UnsafeMutableRawPointer(mutating: allocated.role))
                    free(UnsafeMutableRawPointer(mutating: allocated.content))
                }
                throw ChatTemplateError.formattingFailed(code: -2)
            }
            cMessages.append(llama_chat_message(role: rolePtr, content: contentPtr))
        }

        defer {
            for allocated in cMessages {
                free(UnsafeMutableRawPointer(mutating: allocated.role))
                free(UnsafeMutableRawPointer(mutating: allocated.content))
            }
        }

        // 3. Two-pass formatting via llama_chat_apply_template
        // Pass 1: Query required buffer length (buf: nil, length: 0)
        let requiredLength: Int32 = resolvedTemplate.withCString { cTmpl in
            cMessages.withUnsafeBufferPointer { cMsgBuf in
                llama_chat_apply_template(cTmpl, cMsgBuf.baseAddress, cMsgBuf.count, addAssistantPrompt, nil, 0)
            }
        }

        guard requiredLength > 0 else {
            throw ChatTemplateError.formattingFailed(code: requiredLength)
        }

        // Pass 2: Allocate destination buffer and write formatted string
        var buffer = [CChar](repeating: 0, count: Int(requiredLength) + 1)
        let writtenLength: Int32 = resolvedTemplate.withCString { cTmpl in
            cMessages.withUnsafeBufferPointer { cMsgBuf in
                buffer.withUnsafeMutableBufferPointer { outBuf in
                    llama_chat_apply_template(cTmpl, cMsgBuf.baseAddress, cMsgBuf.count, addAssistantPrompt, outBuf.baseAddress, Int32(outBuf.count))
                }
            }
        }

        guard writtenLength >= 0 else {
            throw ChatTemplateError.formattingFailed(code: writtenLength)
        }

        return buffer.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return "" }
            return String(cString: base)
        }
    }
}
