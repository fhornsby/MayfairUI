module mayfair.code.language;

/*
    Programming and markup languages, as the highlighter reads them: what a comment is, what
    quotes a string, which words are keywords, types and constants -- and the editing a language
    wants: what comments out a line, whether it's indented with spaces, and how far.

        auto lang = languageFor("app.d");          // by the file's name, or null
        auto d = languageNamed("D");

    These are definitions, not grammars: a line scanner with a little state between lines (inside
    a block comment, or a string that runs on), as GtkSourceView's and most editors' highlighting
    is. It's quick, and right for nearly everything; what it can't know -- that an identifier
    names a type it hasn't been told of, say -- a language server can (see mayfair.code.lsp).
*/

import std.algorithm : canFind, endsWith;
import std.path : baseName, extension;
import std.string : toLower;

/// What a stretch of code is, as it's coloured.
enum Syntax : ubyte
{
    none,
    keyword,
    type,
    constant,       /// true, false, null, and the like
    number,
    string_,
    escape,         /// \n in a string
    comment,
    preprocessor,   /// #include, #define
    function_,      /// a name followed by "(": a call or a definition
    builtin,        /// a library's names the language treats as its own: print, len
    attribute,      /// @decorators, @property
    property,       /// a key: JSON's, YAML's, CSS's
    variable,       /// a shell's $name
    heading,        /// Markdown's
    emphasis,       /// Markdown's *emphasis*
    strong,         /// and its **strong**
    link,           /// Markdown's [text](url)
    tag,            /// HTML's and XML's element names
}

/// A kind of string: what opens and closes it, what escapes in it, whether it runs on to the next line.
struct Quote
{
    string open, close;
    char escape = '\\';     /// 0 for none: a raw string
    bool multiline;
}

/// How a language reads, and is edited.
final class Language
{
    string name;
    string[] extensions;     /// without dots: "d", "di"
    string[] fileNames;      /// whole names: "Makefile", "Dockerfile"
    string lineComment;      /// "//", "#", "--"
    string blockOpen, blockClose; /// "/*", "*/"
    bool nestedBlocks;       /// whether block comments nest, as D's /+ +/ and Rust's do
    string nestedOpen, nestedClose; /// a second, nesting, kind: D's "/+", "+/"
    Quote[] quotes;
    string[] keywords, types, constants, builtins;
    bool caseInsensitive;    /// keywords in any case: SQL's
    bool preprocessor;       /// a line starting "#" is a directive: C's
    bool decorators;         /// "@name" is an attribute: Python's, Java's, D's
    bool capitalisedTypes;   /// a name starting with a capital is a type: Java's, Rust's, Swift's convention
    bool variables;          /// "$name" and "${...}" are variables: shells', PHP's, Perl's
    bool keysBeforeColon;    /// "key:" names a property: YAML's, and JSON's keys (strings)
    bool keysBeforeEquals;   /// "key =" names a property: TOML's, INI's
    bool sectionHeaders;     /// a line "[name]" is a heading: TOML's, INI's
    bool markup;             /// HTML or XML: <tags attr="value">, &entities;
    bool markdown;           /// Markdown, read a line at a time
    bool css;                /// CSS: properties, selectors, #colours
    bool insertSpaces = true;/// indented with spaces, not tabs
    int tabWidth = 4;
    string indentAfter;      /// a line ending with one of these indents the next: Python's ":"

    bool hasKeyword(string w) const { return words(keywords, w); }
    bool hasType(string w) const { return words(types, w); }
    bool hasConstant(string w) const { return words(constants, w); }
    bool hasBuiltin(string w) const { return words(builtins, w); }

private:
    bool words(const string[] list, string w) const
    {
        if (!caseInsensitive)
            return list.canFind(w);
        const lower = w.toLower;
        foreach (k; list)
            if (k == lower)
                return true;
        return false;
    }
}

/// The language a file is in, by its name; null if it's none of these.
Language languageFor(string path)
{
    const name = baseName(path);
    const ext = extension(name).length ? extension(name)[1 .. $].toLower : null;
    foreach (l; languages)
    {
        if (l.fileNames.canFind(name))
            return l;
        if (ext.length && l.extensions.canFind(ext))
            return l;
    }
    return null;
}

/// The language called `name` (as listed: "D", "Python"), or null.
Language languageNamed(string name)
{
    foreach (l; languages)
        if (l.name.toLower == name.toLower)
            return l;
    return null;
}

/// Every language there's a definition of, in order.
Language[] languages()
{
    static Language[] all;
    if (!all.length)
        all = define();
    return all;
}

private:

Language lang(string name, string[] extensions, void delegate(Language) setUp)
{
    auto l = new Language;
    l.name = name;
    l.extensions = extensions;
    setUp(l);
    return l;
}

immutable cStrings = [Quote("\"", "\""), Quote("'", "'")];

immutable cKeywords = ["if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
                       "return", "goto", "sizeof", "typedef", "struct", "union", "enum", "static", "extern",
                       "const", "volatile", "inline", "register", "restrict", "auto", "_Alignas", "_Alignof",
                       "_Atomic", "_Generic", "_Noreturn", "_Static_assert", "_Thread_local"];
immutable cTypes = ["void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "bool",
                    "_Bool", "size_t", "ssize_t", "ptrdiff_t", "int8_t", "int16_t", "int32_t", "int64_t",
                    "uint8_t", "uint16_t", "uint32_t", "uint64_t", "intptr_t", "uintptr_t", "wchar_t", "FILE"];

Language[] define()
{
    Language[] all;
    all ~= lang("D", ["d", "di"], (l) {
        l.lineComment = "//";
        l.blockOpen = "/*"; l.blockClose = "*/";
        l.nestedOpen = "/+"; l.nestedClose = "+/";
        l.quotes = [Quote("r\"", "\"", 0, true), Quote("`", "`", 0, true),
                    Quote("\"", "\"", '\\', true), Quote("'", "'")];
        l.keywords = ["abstract", "alias", "align", "asm", "assert", "auto", "body", "break", "case", "cast",
                      "catch", "class", "const", "continue", "debug", "default", "delegate", "delete",
                      "deprecated", "do", "else", "enum", "export", "extern", "final", "finally", "for",
                      "foreach", "foreach_reverse", "function", "goto", "if", "immutable", "import", "in",
                      "inout", "interface", "invariant", "is", "lazy", "mixin", "module", "new", "nothrow",
                      "out", "override", "package", "pragma", "private", "protected", "public", "pure", "ref",
                      "return", "scope", "shared", "static", "struct", "super", "switch", "synchronized",
                      "template", "this", "throw", "try", "typeid", "typeof", "union", "unittest", "version",
                      "while", "with", "__gshared", "__traits", "__vector", "__parameters"];
        l.types = ["bool", "byte", "ubyte", "short", "ushort", "int", "uint", "long", "ulong", "cent", "ucent",
                   "char", "wchar", "dchar", "float", "double", "real", "ifloat", "idouble", "ireal", "cfloat",
                   "cdouble", "creal", "void", "string", "wstring", "dstring", "size_t", "ptrdiff_t", "Object"];
        l.constants = ["true", "false", "null", "__FILE__", "__LINE__", "__MODULE__", "__FUNCTION__",
                       "__PRETTY_FUNCTION__", "__FILE_FULL_PATH__"];
        l.decorators = true;
        l.capitalisedTypes = true;
        l.insertSpaces = true;
    });
    all ~= lang("C", ["c", "h"], (l) {
        l.lineComment = "//"; l.blockOpen = "/*"; l.blockClose = "*/";
        l.quotes = cStrings.dup;
        l.keywords = cKeywords.dup;
        l.types = cTypes.dup;
        l.constants = ["NULL", "true", "false", "EOF"];
        l.preprocessor = true;
    });
    all ~= lang("C++", ["cpp", "cc", "cxx", "hpp", "hh", "hxx", "ipp", "inl"], (l) {
        l.lineComment = "//"; l.blockOpen = "/*"; l.blockClose = "*/";
        l.quotes = [Quote("R\"(", ")\"", 0, true)] ~ cStrings.dup;
        l.keywords = cKeywords.dup ~ ["class", "namespace", "template", "typename", "public", "private",
                     "protected", "virtual", "override", "final", "new", "delete", "this", "operator", "friend",
                     "using", "try", "catch", "throw", "noexcept", "constexpr", "consteval", "constinit",
                     "decltype", "explicit", "mutable", "static_cast", "dynamic_cast", "const_cast",
                     "reinterpret_cast", "co_await", "co_return", "co_yield", "concept", "requires",
                     "export", "module", "import"];
        l.types = cTypes.dup ~ ["std", "string", "vector", "map", "unique_ptr", "shared_ptr", "char8_t",
                  "char16_t", "char32_t"];
        l.constants = ["nullptr", "true", "false", "NULL"];
        l.preprocessor = true;
    });
    all ~= lang("C#", ["cs"], (l) {
        l.lineComment = "//"; l.blockOpen = "/*"; l.blockClose = "*/";
        l.quotes = [Quote("@\"", "\"", 0, true), Quote("$\"", "\""), Quote("\"", "\""), Quote("'", "'")];
        l.keywords = ["abstract", "as", "base", "break", "case", "catch", "checked", "class", "const", "continue",
                      "default", "delegate", "do", "else", "enum", "event", "explicit", "extern", "finally",
                      "fixed", "for", "foreach", "goto", "if", "implicit", "in", "interface", "internal", "is",
                      "lock", "namespace", "new", "operator", "out", "override", "params", "private",
                      "protected", "public", "readonly", "record", "ref", "return", "sealed", "sizeof",
                      "stackalloc", "static", "struct", "switch", "this", "throw", "try", "typeof", "unchecked",
                      "unsafe", "using", "virtual", "volatile", "while", "async", "await", "var", "yield",
                      "get", "set", "init", "where", "when"];
        l.types = ["bool", "byte", "sbyte", "char", "decimal", "double", "float", "int", "uint", "long",
                   "ulong", "object", "short", "ushort", "string", "void", "dynamic", "nint", "nuint"];
        l.constants = ["true", "false", "null"];
        l.preprocessor = true;
        l.capitalisedTypes = true;
    });
    all ~= lang("Java", ["java"], (l) {
        l.lineComment = "//"; l.blockOpen = "/*"; l.blockClose = "*/";
        l.quotes = [Quote("\"\"\"", "\"\"\"", '\\', true)] ~ cStrings.dup;
        l.keywords = ["abstract", "assert", "break", "case", "catch", "class", "const", "continue", "default",
                      "do", "else", "enum", "extends", "final", "finally", "for", "goto", "if", "implements",
                      "import", "instanceof", "interface", "native", "new", "package", "private", "protected",
                      "public", "return", "static", "strictfp", "super", "switch", "synchronized", "this",
                      "throw", "throws", "transient", "try", "volatile", "while", "var", "record", "sealed",
                      "permits", "yield"];
        l.types = ["boolean", "byte", "char", "short", "int", "long", "float", "double", "void", "String"];
        l.constants = ["true", "false", "null"];
        l.decorators = true;
        l.capitalisedTypes = true;
    });
    auto jsKeywords = ["break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete",
                       "do", "else", "export", "extends", "finally", "for", "function", "if", "import", "in",
                       "instanceof", "let", "new", "return", "super", "switch", "this", "throw", "try",
                       "typeof", "var", "void", "while", "with", "yield", "async", "await", "of", "static",
                       "get", "set", "from", "as"];
    auto jsQuotes = [Quote("`", "`", '\\', true), Quote("\"", "\""), Quote("'", "'")];
    all ~= lang("JavaScript", ["js", "mjs", "cjs", "jsx"], (l) {
        l.lineComment = "//"; l.blockOpen = "/*"; l.blockClose = "*/";
        l.quotes = jsQuotes;
        l.keywords = jsKeywords;
        l.constants = ["true", "false", "null", "undefined", "NaN", "Infinity"];
        l.builtins = ["console", "window", "document", "Math", "JSON", "Object", "Array", "Promise", "require",
                      "module", "process"];
        l.capitalisedTypes = true;
        l.tabWidth = 2;
    });
    all ~= lang("TypeScript", ["ts", "tsx", "mts", "cts"], (l) {
        l.lineComment = "//"; l.blockOpen = "/*"; l.blockClose = "*/";
        l.quotes = jsQuotes;
        l.keywords = jsKeywords ~ ["interface", "type", "enum", "implements", "private", "protected", "public",
                     "readonly", "abstract", "declare", "namespace", "keyof", "infer", "is", "satisfies"];
        l.types = ["string", "number", "boolean", "any", "unknown", "never", "void", "object", "bigint", "symbol"];
        l.constants = ["true", "false", "null", "undefined", "NaN", "Infinity"];
        l.builtins = ["console", "window", "document", "Math", "JSON", "Object", "Array", "Promise"];
        l.decorators = true;
        l.capitalisedTypes = true;
        l.tabWidth = 2;
    });
    all ~= lang("Python", ["py", "pyw", "pyi"], (l) {
        l.lineComment = "#";
        string[] q;
        foreach (prefix; ["", "r", "f", "b", "rb", "br", "fr", "rf", "u"])
            foreach (t; ["\"\"\"", "'''"])
                q ~= prefix ~ t;
        foreach (open; q)
            l.quotes ~= Quote(open, open[$ - 3 .. $], open.canFind('r') ? 0 : '\\', true);
        foreach (prefix; ["r", "f", "b", "rb", "br", "fr", "rf", "u"])
            foreach (t; ["\"", "'"])
                l.quotes ~= Quote(prefix ~ t, t, prefix.canFind('r') ? 0 : '\\');
        l.quotes ~= [Quote("\"", "\""), Quote("'", "'")];
        l.keywords = ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
                      "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
                      "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
                      "match", "case"];
        l.types = ["int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes", "object", "type",
                   "complex", "frozenset", "bytearray"];
        l.constants = ["True", "False", "None", "self", "cls", "__name__", "__file__"];
        l.builtins = ["print", "len", "range", "open", "isinstance", "super", "enumerate", "zip", "map",
                      "filter", "sorted", "min", "max", "sum", "any", "all", "abs", "repr", "input", "iter",
                      "next", "getattr", "setattr", "hasattr"];
        l.decorators = true;
        l.indentAfter = ":";
    });
    all ~= lang("Rust", ["rs"], (l) {
        l.lineComment = "//"; l.blockOpen = "/*"; l.blockClose = "*/"; l.nestedBlocks = true;
        l.quotes = [Quote("r#\"", "\"#", 0, true), Quote("r\"", "\"", 0, true), Quote("b\"", "\"", '\\', true),
                    Quote("\"", "\"", '\\', true)];
        l.keywords = ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
                      "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut",
                      "pub", "ref", "return", "static", "struct", "super", "trait", "type", "unsafe", "use",
                      "where", "while", "macro_rules"];
        l.types = ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize",
                   "f32", "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box", "Self"];
        l.constants = ["true", "false", "None", "Some", "Ok", "Err", "self"];
        l.capitalisedTypes = true;
    });
    all ~= lang("Go", ["go"], (l) {
        l.lineComment = "//"; l.blockOpen = "/*"; l.blockClose = "*/";
        l.quotes = [Quote("`", "`", 0, true), Quote("\"", "\""), Quote("'", "'")];
        l.keywords = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
                      "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
                      "return", "select", "struct", "switch", "type", "var"];
        l.types = ["bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8",
                   "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64",
                   "uintptr", "any"];
        l.constants = ["true", "false", "nil", "iota"];
        l.builtins = ["append", "cap", "close", "copy", "delete", "len", "make", "new", "panic", "print",
                      "println", "recover"];
        l.insertSpaces = false;
    });
    all ~= lang("Ruby", ["rb", "rake", "gemspec"], (l) {
        l.lineComment = "#";
        l.quotes = [Quote("\"", "\"", '\\', true), Quote("'", "'", '\\', true)];
        l.keywords = ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else",
                      "elsif", "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo",
                      "rescue", "retry", "return", "self", "super", "then", "undef", "unless", "until", "when",
                      "while", "yield", "require", "attr_accessor", "attr_reader", "puts"];
        l.constants = ["true", "false", "nil"];
        l.capitalisedTypes = true;
        l.tabWidth = 2;
    });
    all ~= lang("Lua", ["lua"], (l) {
        l.lineComment = "--"; l.blockOpen = "--[["; l.blockClose = "]]";
        l.quotes = [Quote("[[", "]]", 0, true), Quote("\"", "\""), Quote("'", "'")];
        l.keywords = ["and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in",
                      "local", "not", "or", "repeat", "return", "then", "until", "while"];
        l.constants = ["true", "false", "nil"];
        l.builtins = ["print", "pairs", "ipairs", "require", "type", "tostring", "tonumber", "string", "table",
                      "math", "os", "io"];
    });
    all ~= lang("Shell", ["sh", "bash", "zsh", "ksh"], (l) {
        l.fileNames = [".bashrc", ".zshrc", ".profile", ".bash_profile"];
        l.lineComment = "#";
        l.quotes = [Quote("\"", "\"", '\\', true), Quote("'", "'", 0, true)];
        l.keywords = ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
                      "in", "function", "return", "select", "local", "export", "readonly", "declare", "set",
                      "unset", "shift", "exit", "source", "eval", "exec", "trap"];
        l.builtins = ["echo", "printf", "cd", "pwd", "read", "test", "true", "false"];
        l.variables = true;
        l.insertSpaces = true;
        l.tabWidth = 2;
    });
    all ~= lang("JSON", ["json", "jsonc", "geojson"], (l) {
        l.lineComment = "//"; l.blockOpen = "/*"; l.blockClose = "*/";
        l.quotes = [Quote("\"", "\"")];
        l.constants = ["true", "false", "null"];
        l.keysBeforeColon = true;
        l.tabWidth = 2;
    });
    all ~= lang("YAML", ["yaml", "yml"], (l) {
        l.lineComment = "#";
        l.quotes = [Quote("\"", "\""), Quote("'", "'", 0)];
        l.constants = ["true", "false", "null", "yes", "no", "on", "off", "~"];
        l.keysBeforeColon = true;
        l.tabWidth = 2;
    });
    all ~= lang("TOML", ["toml"], (l) {
        l.lineComment = "#";
        l.quotes = [Quote("\"\"\"", "\"\"\"", '\\', true), Quote("'''", "'''", 0, true), Quote("\"", "\""),
                    Quote("'", "'", 0)];
        l.constants = ["true", "false"];
        l.keysBeforeEquals = true;
        l.sectionHeaders = true;
    });
    all ~= lang("INI", ["ini", "cfg", "conf", "desktop", "service"], (l) {
        l.lineComment = "#";
        l.quotes = [Quote("\"", "\"")];
        l.keysBeforeEquals = true;
        l.sectionHeaders = true;
    });
    all ~= lang("CSS", ["css", "scss", "less"], (l) {
        l.blockOpen = "/*"; l.blockClose = "*/";
        l.quotes = [Quote("\"", "\""), Quote("'", "'")];
        l.keywords = ["@media", "@import", "@font-face", "@keyframes", "@supports", "!important"];
        l.constants = ["inherit", "initial", "unset", "none", "auto", "transparent"];
        l.css = true;
        l.tabWidth = 4;
    });
    all ~= lang("HTML", ["html", "htm", "xhtml", "vue", "svelte"], (l) {
        l.blockOpen = "<!--"; l.blockClose = "-->";
        l.quotes = [Quote("\"", "\"", 0), Quote("'", "'", 0)];
        l.markup = true;
        l.tabWidth = 2;
    });
    all ~= lang("XML", ["xml", "svg", "xsd", "xsl", "plist", "csproj", "fsproj", "xaml", "axaml"], (l) {
        l.blockOpen = "<!--"; l.blockClose = "-->";
        l.quotes = [Quote("\"", "\"", 0), Quote("'", "'", 0)];
        l.markup = true;
        l.tabWidth = 2;
    });
    all ~= lang("Markdown", ["md", "markdown", "mdown"], (l) {
        l.fileNames = ["README", "CHANGELOG"];
        l.markdown = true;
        l.tabWidth = 2;
    });
    all ~= lang("SQL", ["sql"], (l) {
        l.lineComment = "--"; l.blockOpen = "/*"; l.blockClose = "*/";
        l.quotes = [Quote("'", "'", 0), Quote("\"", "\"", 0)];
        l.caseInsensitive = true;
        l.keywords = ["select", "from", "where", "insert", "into", "values", "update", "set", "delete",
                      "create", "table", "drop", "alter", "add", "index", "view", "join", "left", "right",
                      "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "as",
                      "and", "or", "not", "in", "is", "like", "between", "distinct", "union", "all", "case",
                      "when", "then", "else", "end", "primary", "key", "foreign", "references", "default",
                      "begin", "commit", "rollback", "transaction", "with", "exists", "returning"];
        l.types = ["integer", "int", "bigint", "smallint", "text", "varchar", "char", "boolean", "real",
                   "double", "numeric", "decimal", "date", "time", "timestamp", "blob", "json", "uuid"];
        l.constants = ["null", "true", "false"];
        l.builtins = ["count", "sum", "avg", "min", "max", "coalesce", "now", "length", "lower", "upper"];
    });
    all ~= lang("Makefile", ["mk", "mak"], (l) {
        l.fileNames = ["Makefile", "makefile", "GNUmakefile"];
        l.lineComment = "#";
        l.quotes = [Quote("\"", "\""), Quote("'", "'")];
        l.keywords = ["ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "define", "endef",
                      "export", "override", ".PHONY"];
        l.variables = true;
        l.insertSpaces = false;
    });
    all ~= lang("Dockerfile", ["dockerfile"], (l) {
        l.fileNames = ["Dockerfile", "Containerfile"];
        l.lineComment = "#";
        l.quotes = [Quote("\"", "\""), Quote("'", "'")];
        l.caseInsensitive = true;
        l.keywords = ["from", "run", "cmd", "label", "expose", "env", "add", "copy", "entrypoint", "volume",
                      "user", "workdir", "arg", "onbuild", "stopsignal", "healthcheck", "shell", "as"];
        l.variables = true;
    });
    return all;
}

unittest
{
    assert(languageFor("src/app.d").name == "D");
    assert(languageFor("main.PY").name == "Python");
    assert(languageFor("Makefile").name == "Makefile");
    assert(languageFor("notes.txt") is null);
    assert(languageNamed("c++").name == "C++");
    assert(languageNamed("SQL").hasKeyword("SELECT"), "SQL's keywords in any case");
}
