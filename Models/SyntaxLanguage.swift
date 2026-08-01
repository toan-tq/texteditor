import Foundation

/// Language definitions ported from Java SyntaxHighlighter.java.
/// Each case carries its own keyword set, type set, and comment-style flags.
enum SyntaxLanguage: String, CaseIterable {
    case cCpp
    case java
    case python
    case javascript
    case typescript
    case go
    case rust
    case bash
    case markdown
    case plain

    // MARK: - Detection

    /// Detect language from a file name (including extension).
    /// Port of Java `SyntaxHighlighter.detectLanguage()`.
    static func detect(fileName: String) -> SyntaxLanguage {
        let name = fileName.lowercased()

        if name.hasSuffix(".c") || name.hasSuffix(".h")
            || name.hasSuffix(".cpp") || name.hasSuffix(".cc")
            || name.hasSuffix(".cxx") || name.hasSuffix(".hpp") || name.hasSuffix(".hxx")
            || name.hasSuffix(".m") || name.hasSuffix(".mm") {
            return .cCpp
        }
        if name.hasSuffix(".java") { return .java }
        if name.hasSuffix(".py") || name.hasSuffix(".pyw") || name.hasSuffix(".pyi") { return .python }
        if name.hasSuffix(".js") || name.hasSuffix(".jsx")
            || name.hasSuffix(".mjs") || name.hasSuffix(".cjs") {
            return .javascript
        }
        if name.hasSuffix(".ts") || name.hasSuffix(".tsx")
            || name.hasSuffix(".mts") || name.hasSuffix(".cts") {
            return .typescript
        }
        if name.hasSuffix(".go") { return .go }
        if name.hasSuffix(".rs") { return .rust }
        if name.hasSuffix(".sh") || name.hasSuffix(".bash") || name.hasSuffix(".zsh")
            || name.hasSuffix(".ksh") || name.hasSuffix(".fish") {
            return .bash
        }
        if name.hasSuffix(".md") || name.hasSuffix(".markdown") { return .markdown }

        // Common config / data files -- no syntax highlighting
        if name.hasSuffix(".json") || name.hasSuffix(".xml") || name.hasSuffix(".html")
            || name.hasSuffix(".css") || name.hasSuffix(".yml") || name.hasSuffix(".yaml")
            || name.hasSuffix(".toml") || name.hasSuffix(".ini") || name.hasSuffix(".cfg")
            || name.hasSuffix(".conf") || name.hasSuffix(".properties") {
            return .plain
        }

        return .plain
    }

    // MARK: - Comment Style Flags

    /// Python and Bash use `#` for line comments.
    var usesHashComments: Bool {
        self == .python || self == .bash
    }

    /// C-family languages use `//` and `/* */` comments.
    var usesCStyleComments: Bool {
        switch self {
        case .cCpp, .java, .javascript, .typescript, .go, .rust:
            return true
        default:
            return false
        }
    }

    /// Same set of languages that support `/* */` block comments.
    var hasBlockComments: Bool {
        usesCStyleComments
    }

    /// Only Python has `"""` / `'''` triple-quoted strings.
    var hasPythonTripleQuotes: Bool {
        self == .python
    }

    // MARK: - Keywords

    /// Language-specific keyword set (ported verbatim from Java per-language sets).
    var keywords: Set<String> {
        switch self {
        case .cCpp:
            return Self.cCppKeywords
        case .java:
            return Self.javaKeywords
        case .python:
            return Self.pythonKeywords
        case .javascript:
            return Self.javascriptKeywords
        case .typescript:
            return Self.typescriptKeywords
        case .go:
            return Self.goKeywords
        case .rust:
            return Self.rustKeywords
        case .bash:
            return Self.bashKeywords
        case .markdown, .plain:
            return []
        }
    }

    // MARK: - Types

    /// Language-specific built-in type set (ported verbatim from Java).
    var types: Set<String> {
        switch self {
        case .cCpp:
            return Self.cCppTypes
        case .java:
            return Self.javaTypes
        case .python:
            return Self.pythonTypes
        case .javascript:
            return Self.javascriptTypes
        case .typescript:
            return Self.typescriptTypes
        case .go:
            return Self.goTypes
        case .rust:
            return Self.rustTypes
        case .bash:
            return Self.bashTypes
        case .markdown, .plain:
            return []
        }
    }

    // MARK: - Per-Language Keyword Sets

    private static let cCppKeywords: Set<String> = [
        "auto", "break", "case", "catch", "class", "const", "constexpr", "continue",
        "default", "delete", "do", "else", "enum", "explicit", "extern",
        "false", "for", "friend", "goto", "if", "inline", "namespace",
        "new", "noexcept", "nullptr", "operator", "override", "private", "protected", "public",
        "return", "sizeof", "static", "static_cast", "dynamic_cast", "reinterpret_cast", "const_cast",
        "struct", "switch", "template", "this", "throw", "true", "try",
        "typedef", "typeid", "typename", "union", "using", "virtual", "volatile", "while", "final"
    ]

    private static let javaKeywords: Set<String> = [
        "abstract", "assert", "break", "case", "catch", "class", "const", "continue",
        "default", "do", "else", "enum", "extends", "false", "final", "finally",
        "for", "goto", "if", "implements", "import", "instanceof", "interface",
        "native", "new", "null", "package", "private", "protected", "public",
        "return", "static", "strictfp", "super", "switch", "synchronized",
        "this", "throw", "throws", "transient", "true", "try", "volatile", "while",
        "yield", "record", "sealed", "permits", "var"
    ]

    private static let pythonKeywords: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await",
        "break", "class", "continue", "def", "del", "elif", "else", "except",
        "finally", "for", "from", "global", "if", "import", "in", "is",
        "lambda", "nonlocal", "not", "or", "pass", "raise", "return",
        "try", "while", "with", "yield", "match", "case"
    ]

    private static let javascriptKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue",
        "debugger", "default", "delete", "do", "else", "export", "extends",
        "false", "finally", "for", "function", "if", "import", "in",
        "instanceof", "let", "new", "null", "of", "return", "static",
        "switch", "this", "throw", "true", "try", "typeof", "undefined",
        "var", "void", "while", "with", "yield"
    ]

    private static let typescriptKeywords: Set<String> = {
        var ts = javascriptKeywords
        ts.formUnion([
            "abstract", "as", "declare", "enum", "implements", "interface",
            "keyof", "namespace", "never", "readonly", "type", "unknown", "any",
            "infer", "is", "module", "require", "asserts", "override"
        ])
        return ts
    }()

    private static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer",
        "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
        "interface", "map", "package", "range", "return", "select", "struct",
        "switch", "type", "var"
    ]

    private static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn",
        "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
        "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
        "self", "Self", "static", "struct", "super", "trait", "true", "type",
        "unsafe", "use", "where", "while", "macro_rules"
    ]

    private static let bashKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "select",
        "while", "until", "do", "done", "in", "function", "time",
        "break", "continue", "return", "exit", "export", "readonly",
        "declare", "local", "typeset", "unset", "shift", "trap",
        "eval", "exec", "source"
    ]

    // MARK: - Per-Language Type Sets

    private static let cCppTypes: Set<String> = [
        "void", "int", "char", "short", "long", "float", "double",
        "unsigned", "signed", "bool", "string", "wstring",
        "vector", "map", "set", "list", "array", "deque", "stack", "queue",
        "pair", "tuple", "size_t", "ptrdiff_t",
        "uint8_t", "uint16_t", "uint32_t", "uint64_t",
        "int8_t", "int16_t", "int32_t", "int64_t", "nullptr_t", "FILE"
    ]

    private static let javaTypes: Set<String> = [
        "void", "boolean", "byte", "char", "short", "int", "long", "float", "double",
        "String", "Integer", "Long", "Double", "Float", "Boolean", "Character", "Byte", "Short",
        "Object", "Class", "List", "Map", "Set", "ArrayList", "HashMap", "HashSet",
        "LinkedList", "TreeMap", "Optional", "Stream", "Collection", "Iterable",
        "Iterator", "Comparable", "Runnable", "Thread", "Exception", "Error"
    ]

    private static let pythonTypes: Set<String> = [
        "int", "float", "str", "bool", "list", "dict", "tuple", "set",
        "bytes", "bytearray", "complex", "frozenset", "range", "type", "object",
        "super", "print", "len", "isinstance", "issubclass", "property",
        "staticmethod", "classmethod", "enumerate", "zip", "map", "filter",
        "sorted", "reversed", "any", "all", "open", "input",
        "Exception", "ValueError", "TypeError", "KeyError", "IndexError",
        "AttributeError", "RuntimeError", "StopIteration", "NotImplementedError"
    ]

    private static let javascriptTypes: Set<String> = [
        "Array", "Boolean", "Date", "Error", "Function", "JSON", "Map", "Math",
        "Number", "Object", "Promise", "Proxy", "RegExp", "Set", "String",
        "Symbol", "WeakMap", "WeakSet", "BigInt", "Infinity", "NaN",
        "console", "window", "document", "globalThis"
    ]

    // TypeScript shares the same built-in type set as JavaScript.
    private static let typescriptTypes: Set<String> = javascriptTypes

    private static let goTypes: Set<String> = [
        "bool", "byte", "complex64", "complex128", "error",
        "float32", "float64", "int", "int8", "int16", "int32", "int64",
        "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
        "nil", "true", "false", "iota", "any",
        "append", "cap", "close", "copy", "delete", "imag",
        "len", "make", "new", "panic", "print", "println", "real", "recover"
    ]

    private static let rustTypes: Set<String> = [
        "i8", "i16", "i32", "i64", "i128", "isize",
        "u8", "u16", "u32", "u64", "u128", "usize",
        "f32", "f64", "bool", "char", "str",
        "String", "Vec", "Box", "Option", "Result", "Some", "None", "Ok", "Err",
        "HashMap", "HashSet", "Rc", "Arc", "Cell", "RefCell", "Mutex", "Pin", "Future"
    ]

    private static let bashTypes: Set<String> = [
        "echo", "printf", "read", "test", "cd", "pwd", "let",
        "true", "false", "alias", "type", "command", "builtin",
        "getopts", "wait", "kill", "bg", "fg", "jobs", "umask"
    ]
}
