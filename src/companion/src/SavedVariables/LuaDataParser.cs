using System.Diagnostics.CodeAnalysis;
using System.Globalization;
using System.Text;

namespace ArtisanLogbook.SavedVariables;

/// <summary>A data-only Lua table. Keys are strings, finite numbers, or booleans.</summary>
public sealed class LuaTable : Dictionary<object, object?>
{
    public LuaTable() : base(LuaKeyComparer.Instance) { }

    public bool TryGetValue(string key, out object? value) => base.TryGetValue(key, out value);

    public object? Get(string key) => TryGetValue(key, out object? value) ? value : null;
    public object? Get(double key) => TryGetValue(key, out object? value) ? value : null;
}

internal sealed class LuaKeyComparer : IComparer<object>, IEqualityComparer<object>
{
    public static LuaKeyComparer Instance { get; } = new();

    public new bool Equals(object? left, object? right)
    {
        if (left is null || right is null) return left is null && right is null;
        if (IsNumber(left) && IsNumber(right))
            return Convert.ToDouble(left, CultureInfo.InvariantCulture).Equals(Convert.ToDouble(right, CultureInfo.InvariantCulture));
        return left.Equals(right);
    }

    public int GetHashCode(object value) => IsNumber(value)
        ? Convert.ToDouble(value, CultureInfo.InvariantCulture).GetHashCode()
        : value.GetHashCode();

    public int Compare(object? left, object? right)
    {
        if (ReferenceEquals(left, right)) return 0;
        if (left is null) return -1;
        if (right is null) return 1;
        int leftKind = Kind(left);
        int rightKind = Kind(right);
        if (leftKind != rightKind) return leftKind.CompareTo(rightKind);
        return leftKind switch
        {
            0 => Convert.ToDouble(left, CultureInfo.InvariantCulture).CompareTo(Convert.ToDouble(right, CultureInfo.InvariantCulture)),
            1 => string.Compare((string)left, (string)right, StringComparison.Ordinal),
            _ => Convert.ToBoolean(left, CultureInfo.InvariantCulture).CompareTo(Convert.ToBoolean(right, CultureInfo.InvariantCulture))
        };
    }

    private static int Kind(object value) => IsNumber(value) ? 0 : value is string ? 1 : 2;
    private static bool IsNumber(object value) => value is double or int or long;
}

public sealed record LuaDocument(IReadOnlyDictionary<string, object?> Assignments, object? ReturnedValue);

public sealed class LuaSyntaxException(string message, int line, int column)
    : FormatException($"{message} (line {line}, column {column})")
{
    public int Line { get; } = line;
    public int Column { get; } = column;
}

/// <summary>
/// Parses only table constructors and literal assignments. No Lua code is executed.
/// </summary>
public static class LuaDataParser
{
    private const int MaximumCharacters = 16 * 1024 * 1024;
    private const int MaximumEntries = 500_000;
    private const int MaximumDepth = 128;

    public static LuaDocument Parse(string source)
    {
        ArgumentNullException.ThrowIfNull(source);
        if (source.Length > MaximumCharacters)
            throw new ArgumentException($"Lua input exceeds the {MaximumCharacters} character limit.", nameof(source));

        return new Parser(source).ParseDocument();
    }

    private sealed class Parser(string source)
    {
        private int _position;
        private int _entries;
        private int _line = 1;
        private int _column = 1;

        public LuaDocument ParseDocument()
        {
            Dictionary<string, object?> assignments = new(StringComparer.Ordinal);
            object? returned = null;
            bool hasReturn = false;
            SkipTrivia();
            while (!AtEnd)
            {
                int line = _line;
                int column = _column;
                string name = ReadIdentifier();
                if (name == "return")
                {
                    if (assignments.Count != 0 || hasReturn)
                        Fail("A return value cannot be combined with other top-level statements", line, column);
                    returned = ParseValue(0);
                    hasReturn = true;
                    SkipTrivia();
                    if (!AtEnd && Current == ';')
                    {
                        Advance();
                        SkipTrivia();
                    }
                    if (!AtEnd) Fail("Only one top-level return value is supported");
                    break;
                }

                if (hasReturn || !Take('='))
                    Fail("Expected a SavedVariables assignment or return table", line, column);
                if (assignments.ContainsKey(name))
                    Fail($"Duplicate top-level assignment '{name}'", line, column);
                assignments.Add(name, ParseValue(0));
                SkipTrivia();
                Take(';');
                SkipTrivia();
            }
            return new(assignments, returned);
        }

        private object? ParseValue(int depth)
        {
            SkipTrivia();
            if (AtEnd) Fail("Expected a Lua literal");
            return Current switch
            {
                '{' => ParseTable(depth + 1),
                '"' or '\'' => ParseString(),
                _ when IsNumberStart(Current) => ParseNumber(),
                _ when IsIdentifierStart(Current) => ParseKeyword(),
                _ => FailValue("Unsupported Lua expression")
            };
        }

        private LuaTable ParseTable(int depth)
        {
            if (depth > MaximumDepth) Fail("Lua table nesting limit exceeded");
            Expect('{');
            LuaTable table = new();
            double nextIndex = 1;
            SkipTrivia();
            while (!Take('}'))
            {
                if (AtEnd) Fail("Unterminated table constructor");
                object key;
                object? value;
                if (Take('['))
                {
                    object? parsedKey = ParseValue(depth);
                    if (parsedKey is null || parsedKey is LuaTable)
                        Fail("Table keys must be non-nil scalar values");
                    key = parsedKey;
                    Expect(']');
                    Expect('=');
                    value = ParseValue(depth);
                }
                else if (IsIdentifierStart(Current))
                {
                    string identifier = ReadIdentifier();
                    SkipTrivia();
                    if (Take('='))
                    {
                        key = identifier;
                        value = ParseValue(depth);
                    }
                    else
                    {
                        value = ParseLiteralIdentifier(identifier);
                        key = nextIndex++;
                    }
                }
                else
                {
                    value = ParseValue(depth);
                    key = nextIndex++;
                }

                if (++_entries > MaximumEntries) Fail("Lua table entry limit exceeded");
                table[key] = value;
                SkipTrivia();
                if (Take(',') || Take(';'))
                    SkipTrivia();
                else if (!AtEnd && Current != '}')
                    Fail("Expected ',' ';' or '}' after table entry");
            }
            return table;
        }

        private object? ParseKeyword()
        {
            string identifier = ReadIdentifier();
            return ParseLiteralIdentifier(identifier);
        }

        private object? ParseLiteralIdentifier(string identifier)
        {
            if (identifier == "true") return true;
            if (identifier == "false") return false;
            if (identifier == "nil") return null;
            return FailValue($"Unsupported Lua identifier '{identifier}'");
        }

        private string ParseString()
        {
            char quote = Current;
            Advance();
            StringBuilder result = new();
            while (!AtEnd && Current != quote)
            {
                char character = Current;
                Advance();
                if (character != '\\')
                {
                    if (character is '\r' or '\n') Fail("Unescaped newline in Lua string");
                    result.Append(character);
                    continue;
                }

                if (AtEnd) Fail("Incomplete escape sequence");
                char escaped = Current;
                Advance();
                switch (escaped)
                {
                    case 'a': result.Append('\a'); break;
                    case 'b': result.Append('\b'); break;
                    case 'f': result.Append('\f'); break;
                    case 'n': result.Append('\n'); break;
                    case 'r': result.Append('\r'); break;
                    case 't': result.Append('\t'); break;
                    case 'v': result.Append('\v'); break;
                    case '\\': result.Append('\\'); break;
                    case '"': result.Append('"'); break;
                    case '\'': result.Append('\''); break;
                    case '\n': break;
                    case '\r':
                        if (Current == '\n') Advance();
                        break;
                    case 'z':
                        while (!AtEnd && char.IsWhiteSpace(Current)) Advance();
                        break;
                    default:
                        if (escaped is >= '0' and <= '9')
                        {
                            int number = escaped - '0';
                            int digits = 1;
                            while (digits < 3 && !AtEnd && Current is >= '0' and <= '9')
                            {
                                number = number * 10 + Current - '0';
                                Advance();
                                digits++;
                            }
                            if (number > 255) Fail("Decimal string escape exceeds 255");
                            result.Append((char)number);
                        }
                        else
                        {
                            Fail($"Unsupported string escape '\\{escaped}'");
                        }
                        break;
                }
            }
            if (AtEnd) Fail("Unterminated Lua string");
            Advance();
            return result.ToString();
        }

        private double ParseNumber()
        {
            int start = _position;
            if (Current is '+' or '-') Advance();
            bool digits = false;
            while (!AtEnd && char.IsAsciiDigit(Current))
            {
                digits = true;
                Advance();
            }
            if (!AtEnd && Current == '.')
            {
                Advance();
                while (!AtEnd && char.IsAsciiDigit(Current))
                {
                    digits = true;
                    Advance();
                }
            }
            if (!AtEnd && Current is 'e' or 'E')
            {
                Advance();
                if (!AtEnd && Current is '+' or '-') Advance();
                int exponentStart = _position;
                while (!AtEnd && char.IsAsciiDigit(Current)) Advance();
                if (_position == exponentStart) Fail("Malformed number exponent");
            }
            double result = 0;
            if (!digits || !double.TryParse(source.AsSpan(start, _position - start),
                NumberStyles.Float, CultureInfo.InvariantCulture, out result))
                Fail("Invalid number");
            if (!double.IsFinite(result)) Fail("Non-finite numbers are unsupported");
            return result;
        }

        private void SkipTrivia()
        {
            while (!AtEnd)
            {
                if (char.IsWhiteSpace(Current))
                {
                    Advance();
                    continue;
                }
                if (Current != '-' || Peek(1) != '-') return;
                Advance();
                Advance();
                if (Current == '[' && Peek(1) == '[')
                {
                    Advance();
                    Advance();
                    while (!AtEnd && !(Current == ']' && Peek(1) == ']')) Advance();
                    if (AtEnd) Fail("Unterminated long comment");
                    Advance();
                    Advance();
                }
                else
                {
                    while (!AtEnd && Current is not '\r' and not '\n') Advance();
                }
            }
        }

        private string ReadIdentifier()
        {
            if (AtEnd || !IsIdentifierStart(Current)) Fail("Expected identifier");
            int start = _position;
            Advance();
            while (!AtEnd && IsIdentifierPart(Current)) Advance();
            return source[start.._position];
        }

        private bool Take(char expected)
        {
            SkipTrivia();
            if (AtEnd || Current != expected) return false;
            Advance();
            return true;
        }

        private void Expect(char expected)
        {
            if (!Take(expected)) Fail($"Expected '{expected}'");
        }

        private void Advance()
        {
            if (AtEnd) return;
            if (Current == '\n')
            {
                _line++;
                _column = 1;
            }
            else
            {
                _column++;
            }
            _position++;
        }

        private char Peek(int offset) => _position + offset < source.Length ? source[_position + offset] : '\0';
        private char Current => source[_position];
        private bool AtEnd => _position >= source.Length;

        [DoesNotReturn]
        private void Fail(string message) => Fail(message, _line, _column);

        [DoesNotReturn]
        private static void Fail(string message, int line, int column) =>
            throw new LuaSyntaxException(message, line, column);

        [DoesNotReturn]
        private object? FailValue(string message)
        {
            throw new LuaSyntaxException(message, _line, _column);
        }

        private static bool IsIdentifierStart(char value) => value is '_' or >= 'a' and <= 'z' or >= 'A' and <= 'Z';
        private static bool IsIdentifierPart(char value) => IsIdentifierStart(value) || char.IsAsciiDigit(value);
        private bool IsNumberStart(char value) =>
            char.IsAsciiDigit(value) || value is '+' or '-' || value == '.' && char.IsAsciiDigit(Peek(1));
    }

    public static string Serialize(LuaDocument document)
    {
        ArgumentNullException.ThrowIfNull(document);
        StringBuilder output = new();
        foreach ((string name, object? value) in document.Assignments.OrderBy(x => x.Key, StringComparer.Ordinal))
        {
            ValidateIdentifier(name);
            output.Append(name).Append(" = ").Append(SerializeValue(value, 0)).AppendLine();
        }
        if (document.ReturnedValue is not null)
            output.Append("return ").Append(SerializeValue(document.ReturnedValue, 0)).AppendLine();
        return output.ToString();
    }

    private static string SerializeValue(object? value, int depth)
    {
        if (depth > MaximumDepth) throw new ArgumentException("Lua value nesting limit exceeded.");
        return value switch
        {
            null => "nil",
            bool boolean => boolean ? "true" : "false",
            string text => SerializeString(text),
            double number when double.IsFinite(number) => number.ToString("G17", CultureInfo.InvariantCulture),
            decimal number => number.ToString(CultureInfo.InvariantCulture),
            int integer => integer.ToString(CultureInfo.InvariantCulture),
            long integer => integer.ToString(CultureInfo.InvariantCulture),
            LuaTable table => SerializeTable(table, depth + 1),
            _ => throw new ArgumentException($"Unsupported Lua value type: {value.GetType().Name}.")
        };
    }

    private static string SerializeTable(LuaTable table, int depth)
    {
        StringBuilder output = new("{");
        bool first = true;
        foreach ((object key, object? value) in table.OrderBy(x => x.Key, LuaKeyComparer.Instance))
        {
            if (key is not string and not bool and not double and not int and not long)
                throw new ArgumentException("Lua table key must be a string, number, or boolean.");
            if (key is double number && !double.IsFinite(number))
                throw new ArgumentException("Lua table key must be finite.");
            if (!first) output.Append(',');
            first = false;
            output.Append('[').Append(SerializeValue(key, depth)).Append("]=")
                .Append(SerializeValue(value, depth));
        }
        return output.Append('}').ToString();
    }

    private static string SerializeString(string value)
    {
        StringBuilder output = new("\"");
        foreach (char character in value)
        {
            switch (character)
            {
                case '"': output.Append("\\\""); break;
                case '\\': output.Append("\\\\"); break;
                case '\a': output.Append("\\a"); break;
                case '\b': output.Append("\\b"); break;
                case '\f': output.Append("\\f"); break;
                case '\n': output.Append("\\n"); break;
                case '\r': output.Append("\\r"); break;
                case '\t': output.Append("\\t"); break;
                case '\v': output.Append("\\v"); break;
                default:
                    if (character < ' ' || character == '\u007f')
                        output.Append('\\').Append(((int)character).ToString("D3", CultureInfo.InvariantCulture));
                    else
                        output.Append(character);
                    break;
            }
        }
        return output.Append('"').ToString();
    }

    private static void ValidateIdentifier(string name)
    {
        if (string.IsNullOrEmpty(name) || !IsIdentifierStart(name[0]) || name.Any(c => !IsIdentifierPart(c)))
            throw new ArgumentException($"Invalid Lua assignment name '{name}'.", nameof(name));
    }

    private static bool IsIdentifierStart(char value) => value is '_' or >= 'a' and <= 'z' or >= 'A' and <= 'Z';
    private static bool IsIdentifierPart(char value) => IsIdentifierStart(value) || char.IsAsciiDigit(value);

}
