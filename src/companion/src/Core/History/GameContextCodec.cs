using System.Globalization;
using System.Text;

namespace ArtisanLogbook.History;

public static class GameContextCodec
{
    public static string Encode(GameContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        string project = ((int)context.Project).ToString(CultureInfo.InvariantCulture);
        if (context.ProgressionTrack is null)
            return project;

        StringBuilder identifier = new(project.Length + 1 + context.ProgressionTrack.Length);
        identifier.Append(project).Append('-');
        foreach (char character in context.ProgressionTrack)
        {
            if (IsUnescaped(character))
                identifier.Append(character);
            else
                identifier.Append('~').Append(((int)character).ToString("X4", CultureInfo.InvariantCulture));
        }
        return identifier.ToString();
    }

    public static bool TryDecode(string? value, out GameContext? context)
    {
        context = null;
        if (string.IsNullOrEmpty(value))
            return false;

        int separator = value.IndexOf('-');
        ReadOnlySpan<char> projectText = separator < 0 ? value.AsSpan() : value.AsSpan(0, separator);
        if (projectText.IsEmpty)
            return false;
        foreach (char character in projectText)
            if (character is < '0' or > '9')
                return false;
        if (!int.TryParse(projectText, NumberStyles.None, CultureInfo.InvariantCulture, out int projectId) ||
            projectId <= 0)
            return false;

        string? progressionTrack = null;
        if (separator >= 0)
        {
            ReadOnlySpan<char> encodedTrack = value.AsSpan(separator + 1);
            StringBuilder decodedTrack = new(encodedTrack.Length);
            for (int index = 0; index < encodedTrack.Length; index++)
            {
                char character = encodedTrack[index];
                if (character == '~')
                {
                    if (index + 4 >= encodedTrack.Length ||
                        !ushort.TryParse(encodedTrack.Slice(index + 1, 4), NumberStyles.AllowHexSpecifier,
                            CultureInfo.InvariantCulture, out ushort codeUnit))
                        return false;
                    decodedTrack.Append((char)codeUnit);
                    index += 4;
                }
                else if (IsUnescaped(character))
                {
                    decodedTrack.Append(character);
                }
                else
                {
                    return false;
                }
            }
            progressionTrack = decodedTrack.ToString();
            if (string.IsNullOrWhiteSpace(progressionTrack))
                return false;
        }

        GameContext decoded;
        try
        {
            decoded = new((GameProject)projectId, progressionTrack);
        }
        catch (ArgumentException)
        {
            return false;
        }

        if (!string.Equals(Encode(decoded), value, StringComparison.Ordinal))
            return false;

        context = decoded;
        return true;
    }

    private static bool IsUnescaped(char character) =>
        character is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '.' or '_' or '-';
}
