import Foundation

/// A minimal tokenizer for languages without a bundled tree-sitter grammar (every grammar costs
/// megabytes of binary). It knows comments, quoted strings, numbers and word lists: no nesting,
/// no regex literals, no heredocs. Such languages are only used when a fence names them explicitly;
/// there are no detection hints, since without a parser there's no way to verify a guess.
struct LightweightSyntax: Sendable {
    var lineComments: [String] = []
    var blockComments: [(open: String, close: String)] = []
    var quotes = "'\"`"
    var backslashEscapes = false
    /// `''` inside a `'…'` string stands for a quote (SQL, MATLAB).
    var doubledQuotes = false
    /// A `'` right after a word, `)`, `]`, `}`, `.` or `'` is MATLAB's transpose, not a string.
    var transposeQuote = false
    var caseInsensitive = false
    /// `is.na`, `.libPaths` (R).
    var dotInIdentifiers = false
    /// `Foo::Bar` is one identifier, colored as a type unless called (Perl).
    var scopeOperator = false
    /// `.and.`, `.true.` (Fortran): keywords, except the boolean constants.
    var dotOperators = false
    /// Variable prefixes (`$x`, `@xs`, `%h`) that make the word after them a plain variable.
    var sigils = ""
    /// A word directly followed by `(` is a function call.
    var highlightCalls = false
    var keywords: Set<String> = []
    var constants: Set<String> = []
    var types: Set<String> = []
    /// Builtins colored as functions wherever they appear.
    var functions: Set<String> = []
    /// Keywords whose following word is a declaration: `sub name`, `package Name`.
    var declarations: [String: SyntaxToken] = [:]

    func highlight(_ code: String) -> [SyntaxSpan] {
        let u = Array(code.utf16)
        let n = u.count
        var spans: [SyntaxSpan] = []
        let lineMarkers = lineComments.map { Array($0.utf16) }
        let blockMarkers = blockComments.map { (open: Array($0.open.utf16), close: Array($0.close.utf16)) }
        let quoteSet = Set(quotes.utf16)
        let sigilSet = Set(sigils.utf16)
        var declared: SyntaxToken?

        func starts(_ s: [UInt16], at i: Int) -> Bool {
            guard !s.isEmpty, i + s.count <= n else { return false }
            for k in 0..<s.count where u[i + k] != s[k] { return false }
            return true
        }
        func add(_ from: Int, _ to: Int, _ token: SyntaxToken) {
            spans.append(SyntaxSpan(range: NSRange(location: from, length: to - from), token: token))
        }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        func isWord(_ c: UInt16) -> Bool { isLetter(c) || isDigit(c) }
        func isNewline(_ c: UInt16) -> Bool { c == 10 || c == 13 }

        func identStart(_ i: Int) -> Bool {
            if isLetter(u[i]) { return true }
            return dotInIdentifiers && u[i] == 46 && i + 1 < n && (isLetter(u[i + 1]) || u[i + 1] == 46)
        }
        func identChar(_ c: UInt16) -> Bool { isWord(c) || (dotInIdentifiers && c == 46) }
        /// The index after the closing dot of a `.word.` starting at `i`.
        func dotOperatorEnd(_ i: Int) -> Int? {
            guard dotOperators, u[i] == 46, i + 1 < n, isLetter(u[i + 1]) else { return nil }
            var j = i + 1
            while j < n, isLetter(u[j]) { j += 1 }
            return j < n && u[j] == 46 ? j + 1 : nil
        }
        func scanWord(from start: Int) -> Int {
            var j = start
            while j < n, identChar(u[j]) { j += 1 }
            return j
        }

        var i = 0
        while i < n {
            let c = u[i]
            if c == 32 || c == 9 || isNewline(c) {
                if isNewline(c) { declared = nil }
                i += 1
                continue
            }
            let pending = declared
            declared = nil

            if let block = blockMarkers.first(where: { starts($0.open, at: i) }) {
                var j = i + block.open.count
                while j < n, !starts(block.close, at: j) { j += 1 }
                j = min(n, j + block.close.count)
                add(i, j, .comment)
                i = j
                continue
            }
            if lineMarkers.contains(where: { starts($0, at: i) }) {
                var j = i
                while j < n, !isNewline(u[j]) { j += 1 }
                add(i, j, .comment)
                i = j
                continue
            }

            if sigilSet.contains(c) {
                var j = i + 1
                if c == 36, j < n, u[j] == 35 { j += 1 }  // `$#array`
                if j < n, c == 36 ? isWord(u[j]) : isLetter(u[j]) {
                    j = scanWord(from: j)
                    while scopeOperator, j + 2 < n, u[j] == 58, u[j + 1] == 58, isLetter(u[j + 2]) {
                        j = scanWord(from: j + 2)
                    }
                    i = j
                } else {
                    i += 1
                }
                continue
            }

            if quoteSet.contains(c) {
                if transposeQuote, c == 39, i > 0 {
                    let p = u[i - 1]
                    if isWord(p) || p == 41 || p == 93 || p == 125 || p == 46 || p == 39 {
                        i += 1
                        continue
                    }
                }
                var j = i + 1
                while j < n {
                    let d = u[j]
                    if backslashEscapes, d == 92 {
                        j += 2
                        continue
                    }
                    if d == c {
                        if doubledQuotes, j + 1 < n, u[j + 1] == c {
                            j += 2
                            continue
                        }
                        j += 1
                        break
                    }
                    j += 1
                }
                j = min(j, n)
                add(i, j, .string)
                i = j
                continue
            }

            if isDigit(c) || (c == 46 && i + 1 < n && isDigit(u[i + 1])) {
                var j = i + 1
                while j < n {
                    let d = u[j]
                    if isWord(d) {
                        if d == 101 || d == 69, j + 1 < n, u[j + 1] == 43 || u[j + 1] == 45 { j += 1 }
                        j += 1
                    } else if d == 46, !(j + 1 < n && u[j + 1] == 46), dotOperatorEnd(j) == nil {
                        j += 1
                    } else {
                        break
                    }
                }
                add(i, j, .constant)
                i = j
                continue
            }

            if let end = dotOperatorEnd(i) {
                let word = String(decoding: u[(i + 1)..<(end - 1)], as: UTF16.self).lowercased()
                add(i, end, word == "true" || word == "false" ? .constant : .keyword)
                i = end
                continue
            }

            if identStart(i) {
                var j = scanWord(from: i + 1)
                var scoped = false
                while scopeOperator, j + 2 < n, u[j] == 58, u[j + 1] == 58, isLetter(u[j + 2]) {
                    j = scanWord(from: j + 2)
                    scoped = true
                }
                let word = String(decoding: u[i..<j], as: UTF16.self)
                let key = caseInsensitive ? word.lowercased() : word
                let token: SyntaxToken?
                if let pending {
                    token = pending
                } else if keywords.contains(key) {
                    token = .keyword
                    declared = declarations[key]
                } else if constants.contains(key) {
                    token = .constant
                } else if types.contains(key) {
                    token = .type
                } else if functions.contains(key) || (highlightCalls && j < n && u[j] == 40) {
                    token = .function
                } else if scoped {
                    token = .type
                } else {
                    token = nil
                }
                if let token { add(i, j, token) }
                i = j
                continue
            }

            i += 1
        }
        return spans
    }
}

extension SyntaxLanguage {
    /// Set for the languages highlighted by `LightweightSyntax` instead of a tree-sitter grammar.
    var lightweight: LightweightSyntax? {
        switch self {
        case .sql: Self.sqlSyntax
        case .matlab: Self.matlabSyntax
        case .perl: Self.perlSyntax
        case .r: Self.rSyntax
        case .vb: Self.vbSyntax
        case .fortran: Self.fortranSyntax
        case .pascal: Self.pascalSyntax
        default: nil
        }
    }

    private static func words(_ list: String) -> Set<String> {
        Set(list.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    private static let sqlSyntax = LightweightSyntax(
        lineComments: ["--"],
        blockComments: [("/*", "*/")],
        doubledQuotes: true,
        caseInsensitive: true,
        highlightCalls: true,
        keywords: words(
            """
            add all alter analyze and any as asc begin between by cascade case check column commit constraint \
            create cross database default delete desc distinct drop else end except exists explain fetch first \
            for foreign from full grant group having if ilike in index inner insert intersect into is join key \
            last left like limit materialized natural next not nulls offset on only or order outer over \
            partition primary recursive references replace returning revoke right rollback row rows schema \
            select set show table temp temporary then to top transaction truncate union unique update use \
            using values view when where window with
            """),
        constants: words("true false null unknown"),
        types: words(
            """
            bigint bigserial binary bit blob bool boolean char date datetime decimal double float int integer \
            interval json jsonb money numeric real serial smallint text time timestamp tinyint uuid varbinary \
            varchar
            """)
    )

    private static let matlabSyntax = LightweightSyntax(
        lineComments: ["%", "#"],
        blockComments: [("%{", "%}")],
        quotes: "'\"",
        doubledQuotes: true,
        transposeQuote: true,
        keywords: words(
            """
            arguments break case catch classdef continue else elseif end enumeration events for function global \
            if import methods otherwise parfor persistent properties return spmd switch try while
            """),
        constants: words("true false pi Inf NaN eps"),
        functions: words(
            """
            abs all any arrayfun cat cellfun cos cumsum disp error exp eye figure find fprintf hold isempty \
            length linspace log max mean min norm numel ones plot printf rand randn reshape round size sort \
            sprintf sqrt strcat sum tic toc warning xlabel ylabel zeros
            """)
    )

    private static let perlSyntax = LightweightSyntax(
        lineComments: ["#"],
        backslashEscapes: true,
        scopeOperator: true,
        sigils: "$@%",
        highlightCalls: true,
        keywords: words(
            """
            and BEGIN cmp continue do else elsif END eq eval for foreach ge goto gt if last le local lt my ne \
            next no not or our package redo require return sub unless until use while xor
            """),
        constants: words("__PACKAGE__ __FILE__ __LINE__ __END__ __DATA__ STDIN STDOUT STDERR undef"),
        functions: words(
            """
            bless chomp chop close defined delete die each exists exit grep index join keys lc lcfirst length \
            map open pop print printf push ref reverse say scalar shift sort splice split sprintf substr uc \
            ucfirst unshift values wantarray warn
            """),
        declarations: ["sub": .function, "package": .type]
    )

    private static let rSyntax = LightweightSyntax(
        lineComments: ["#"],
        quotes: "'\"",
        backslashEscapes: true,
        dotInIdentifiers: true,
        highlightCalls: true,
        keywords: words("break else for function if in next repeat return while"),
        constants: words("TRUE FALSE NULL NA NA_integer_ NA_real_ NA_character_ Inf NaN")
    )

    // Visual Basic 6, VBA, VBScript and VB.NET share one definition.
    private static let vbSyntax = LightweightSyntax(
        lineComments: ["'"],
        quotes: "\"",
        doubledQuotes: true,
        caseInsensitive: true,
        keywords: words(
            """
            addhandler addressof alias and andalso as await byref byval call case catch class const continue \
            declare default delegate dim directcast do each else elseif end enum erase error event exit \
            finally for friend function get global gosub goto handles if implements imports in inherits \
            interface is isnot let lib like loop me module mod mustinherit mustoverride mybase myclass \
            namespace narrowing new next not notinheritable notoverridable of on operator option optional or \
            orelse overloads overridable overrides paramarray partial preserve private property protected \
            public raiseevent redim rem removehandler resume return select set shadows shared static step stop \
            structure sub synclock then throw to try typeof until using wend when while widening with \
            withevents writeonly xor yield
            """),
        constants: words("true false nothing null empty"),
        types: words(
            """
            boolean byte char date decimal double integer long object sbyte short single string uinteger \
            ulong ushort variant
            """),
        declarations: [
            "sub": .function, "function": .function, "class": .type, "module": .type,
            "structure": .type, "interface": .type, "enum": .type,
        ]
    )

    private static let fortranSyntax = LightweightSyntax(
        lineComments: ["!"],
        quotes: "'\"",
        doubledQuotes: true,
        caseInsensitive: true,
        dotOperators: true,
        keywords: words(
            """
            allocatable allocate assign associate block call case character common contains continue cycle \
            data deallocate default do else elseif elsewhere end enddo endif endprogram entry equivalence \
            exit external forall format function go goto if implicit import in include inout intent interface \
            intrinsic module namelist none nullify only open optional out parameter pointer print private \
            procedure program public pure read recursive result return rewind save select sequence stop \
            subroutine target then to type use value where while write close elemental abstract class \
            extends submodule
            """),
        types: words("integer real double precision complex logical character"),
        functions: words(
            """
            abs acos asin atan atan2 ceiling cos cosh exp floor int len log log10 max maxval merge min minval \
            mod modulo nint product reshape selected_int_kind selected_real_kind shape sign sin sinh size sqrt \
            sum tan tanh trim transpose
            """),
        declarations: [
            "subroutine": .function, "function": .function, "program": .type, "module": .type,
        ]
    )

    // Pascal, Object Pascal, Delphi and Free Pascal.
    private static let pascalSyntax = LightweightSyntax(
        lineComments: ["//"],
        blockComments: [("{", "}"), ("(*", "*)")],
        quotes: "'",
        doubledQuotes: true,
        caseInsensitive: true,
        keywords: words(
            """
            absolute abstract and array as asm begin break case class const constructor continue destructor \
            div do downto else end except exit explicit export external file finalization finally for forward \
            function goto if implementation implicit in inherited initialization inline interface is label \
            library mod nil not object of on operator or out overload override packed private procedure \
            program property protected public published raise record register reintroduce repeat resourcestring \
            set shl shr static then threadvar to try type unit until uses var virtual while with xor
            """),
        constants: words("true false nil"),
        types: words(
            """
            ansichar ansistring boolean byte cardinal char comp currency double extended int64 integer \
            longint longword pchar pointer real shortint single smallint string tobject variant widestring \
            word
            """),
        declarations: [
            "function": .function, "procedure": .function, "constructor": .function,
            "destructor": .function, "unit": .type, "program": .type,
        ]
    )
}
