import Foundation

// MARK: - MCP Protocol Constants

public enum MCPConstants {
    public static let jsonrpcVersion = "2.0"
    public static let defaultProtocolVersion = "2024-11-05"
    public static let supportedProtocolVersions = ["2024-11-05"]
}

// MARK: - Dynamic Sendable AnyCodable Representation

/// A Sendable, Codable, Equatable representation of dynamic JSON values for MCP schemas and payloads.
public enum AnyCodableSendable: Sendable, Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case dictionary([String: AnyCodableSendable])
    case array([AnyCodableSendable])
    case null

    public init(_ value: Any?) {
        #if canImport(Foundation)
        if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                self = .bool(num.boolValue)
                return
            } else if CFNumberIsFloatType(num) {
                self = .double(num.doubleValue)
                return
            } else {
                self = .int(num.intValue)
                return
            }
        }
        #endif

        switch value {
        case let str as String:
            self = .string(str)
        case let bool as Bool:
            self = .bool(bool)
        case let int as Int:
            self = .int(int)
        case let dbl as Double:
            self = .double(dbl)
        case let flt as Float:
            self = .double(Double(flt))
        case let dict as [String: Any]:
            self = .dictionary(dict.mapValues { AnyCodableSendable($0) })
        case let dict as [String: String]:
            self = .dictionary(dict.mapValues { .string($0) })
        case let arr as [Any]:
            self = .array(arr.map { AnyCodableSendable($0) })
        case let codable as AnyCodableSendable:
            self = codable
        default:
            self = .null
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .string(let s): return Int(s)
        case .double(let d): return Int(d)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s):
            let lower = s.lowercased()
            if lower == "true" || lower == "1" { return true }
            if lower == "false" || lower == "0" { return false }
            return nil
        case .int(let i): return i != 0
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var rawObject: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .dictionary(let d): return d.mapValues { $0.rawObject }
        case .array(let a): return a.map { $0.rawObject }
        case .null: return NSNull()
        }
    }

    public var dictionaryValue: [String: AnyCodableSendable]? {
        if case .dictionary(let dict) = self { return dict }
        return nil
    }

    public var arrayValue: [AnyCodableSendable]? {
        if case .array(let arr) = self { return arr }
        return nil
    }

    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = "\(intValue)"
            self.intValue = intValue
        }
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: AnyCodingKey.self) {
            var dict: [String: AnyCodableSendable] = [:]
            for key in container.allKeys {
                if let val = try? container.decode(AnyCodableSendable.self, forKey: key) {
                    dict[key.stringValue] = val
                }
            }
            self = .dictionary(dict)
            return
        }
        if var container = try? decoder.unkeyedContainer() {
            var arr: [AnyCodableSendable] = []
            while !container.isAtEnd {
                if let val = try? container.decode(AnyCodableSendable.self) {
                    arr.append(val)
                }
            }
            self = .array(arr)
            return
        }
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() {
                self = .null
            } else if let b = try? container.decode(Bool.self) {
                self = .bool(b)
            } else if let i = try? container.decode(Int.self) {
                self = .int(i)
            } else if let d = try? container.decode(Double.self) {
                self = .double(d)
            } else if let s = try? container.decode(String.self) {
                self = .string(s)
            } else {
                self = .null
            }
            return
        }
        self = .null
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s):
            try container.encode(s)
        case .int(let i):
            try container.encode(i)
        case .double(let d):
            try container.encode(d)
        case .bool(let b):
            try container.encode(b)
        case .dictionary(let d):
            try container.encode(d)
        case .array(let a):
            try container.encode(a)
        case .null:
            try container.encodeNil()
        }
    }
}

// MARK: - JSON-RPC 2.0 Base Protocol

public enum JSONRPCID: Sendable, Codable, Equatable, Hashable {
    case string(String)
    case int(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON-RPC ID")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str):
            try container.encode(str)
        case .int(let int):
            try container.encode(int)
        }
    }
}

public struct JSONRPCRequest: Sendable, Codable, Equatable {
    public let jsonrpc: String
    public let id: JSONRPCID
    public let method: String
    public let params: AnyCodableSendable?

    public init(id: JSONRPCID, method: String, params: AnyCodableSendable? = nil) {
        self.jsonrpc = MCPConstants.jsonrpcVersion
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCNotification: Sendable, Codable, Equatable {
    public let jsonrpc: String
    public let method: String
    public let params: AnyCodableSendable?

    public init(method: String, params: AnyCodableSendable? = nil) {
        self.jsonrpc = MCPConstants.jsonrpcVersion
        self.method = method
        self.params = params
    }
}

public struct JSONRPCError: Sendable, Codable, Equatable, Error {
    public let code: Int
    public let message: String
    public let data: AnyCodableSendable?

    public init(code: Int, message: String, data: AnyCodableSendable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Standard JSON-RPC 2.0 error codes
    public static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    public static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid Request")
    public static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
    public static let invalidParams = JSONRPCError(code: -32602, message: "Invalid params")
    public static let internalError = JSONRPCError(code: -32603, message: "Internal error")
}

public struct JSONRPCResponse: Sendable, Codable, Equatable {
    public let jsonrpc: String
    public let id: JSONRPCID
    public let result: AnyCodableSendable?
    public let error: JSONRPCError?

    public init(id: JSONRPCID, result: AnyCodableSendable? = nil, error: JSONRPCError? = nil) {
        self.jsonrpc = MCPConstants.jsonrpcVersion
        self.id = id
        self.result = result
        self.error = error
    }

    public static func success(id: JSONRPCID, result: AnyCodableSendable) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }

    public static func failure(id: JSONRPCID, error: JSONRPCError) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: nil, error: error)
    }
}

// MARK: - MCP Initialization Models

public struct MCPImplementation: Sendable, Codable, Equatable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct MCPClientCapabilities: Sendable, Codable, Equatable {
    public let roots: RootsCapability?
    public let experimental: [String: AnyCodableSendable]?

    public struct RootsCapability: Sendable, Codable, Equatable {
        public let listChanged: Bool?

        public init(listChanged: Bool? = nil) {
            self.listChanged = listChanged
        }
    }

    public init(roots: RootsCapability? = nil, experimental: [String: AnyCodableSendable]? = nil) {
        self.roots = roots
        self.experimental = experimental
    }
}

public struct MCPServerCapabilities: Sendable, Codable, Equatable {
    public let tools: ToolsCapability?
    public let logging: [String: AnyCodableSendable]?
    public let experimental: [String: AnyCodableSendable]?

    public struct ToolsCapability: Sendable, Codable, Equatable {
        public let listChanged: Bool?

        public init(listChanged: Bool? = nil) {
            self.listChanged = listChanged
        }
    }

    public init(tools: ToolsCapability? = ToolsCapability(listChanged: false), logging: [String: AnyCodableSendable]? = nil, experimental: [String: AnyCodableSendable]? = nil) {
        self.tools = tools
        self.logging = logging
        self.experimental = experimental
    }
}

public struct MCPInitializeParams: Sendable, Codable, Equatable {
    public let protocolVersion: String
    public let capabilities: MCPClientCapabilities
    public let clientInfo: MCPImplementation

    public init(protocolVersion: String = MCPConstants.defaultProtocolVersion, capabilities: MCPClientCapabilities = MCPClientCapabilities(), clientInfo: MCPImplementation) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.clientInfo = clientInfo
    }
}

public struct MCPInitializeResult: Sendable, Codable, Equatable {
    public let protocolVersion: String
    public let capabilities: MCPServerCapabilities
    public let serverInfo: MCPImplementation

    public init(protocolVersion: String = MCPConstants.defaultProtocolVersion, capabilities: MCPServerCapabilities = MCPServerCapabilities(), serverInfo: MCPImplementation) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
    }
}

// MARK: - MCP Tool Definitions & Schema

public struct MCPToolProperty: Sendable, Codable, Equatable {
    public let type: String
    public let description: String?
    public let `enum`: [String]?
    public let `default`: String?

    public init(type: String, description: String? = nil, enum: [String]? = nil, default: String? = nil) {
        self.type = type
        self.description = description
        self.enum = `enum`
        self.default = `default`
    }
}

public struct MCPToolInputSchema: Sendable, Codable, Equatable {
    public let type: String
    public let properties: [String: MCPToolProperty]
    public let required: [String]?

    public init(type: String = "object", properties: [String: MCPToolProperty] = [:], required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

public struct MCPTool: Sendable, Codable, Equatable {
    public let name: String
    public let description: String?
    public let inputSchema: MCPToolInputSchema

    public init(name: String, description: String? = nil, inputSchema: MCPToolInputSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct MCPListToolsResult: Sendable, Codable, Equatable {
    public let tools: [MCPTool]

    public init(tools: [MCPTool]) {
        self.tools = tools
    }
}

// MARK: - MCP Tool Execution Models

public struct MCPCallToolParams: Sendable, Codable, Equatable {
    public let name: String
    public let arguments: [String: AnyCodableSendable]?

    public init(name: String, arguments: [String: AnyCodableSendable]? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

public struct MCPContent: Sendable, Codable, Equatable {
    public let type: String
    public let text: String?
    public let data: String?
    public let mimeType: String?

    public init(type: String = "text", text: String? = nil, data: String? = nil, mimeType: String? = nil) {
        self.type = type
        self.text = text
        self.data = data
        self.mimeType = mimeType
    }

    public static func text(_ text: String) -> MCPContent {
        MCPContent(type: "text", text: text)
    }
}

public struct MCPCallToolResult: Sendable, Codable, Equatable {
    public let content: [MCPContent]
    public let isError: Bool?

    public init(content: [MCPContent], isError: Bool? = nil) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String, isError: Bool = false) -> MCPCallToolResult {
        MCPCallToolResult(content: [.text(text)], isError: isError)
    }
}
