using System.Net;
using System.Net.Sockets;

namespace ArtisanLogbook.Runtime;

/// <summary>The loopback endpoint the host asked for and the address it actually obtained.</summary>
public sealed class CompanionHttpEndpoint(int preferredPort, bool fallbackUsed)
{
    private volatile string? _listeningUrl;

    public int PreferredPort { get; } = preferredPort;

    /// <summary>True when the preferred port was owned by another process and an OS-assigned port was requested.</summary>
    public bool FallbackUsed { get; } = fallbackUsed;

    /// <summary>The resolved base URL; null until the server is listening.</summary>
    public string? ListeningUrl => _listeningUrl;

    internal void Resolved(string url) => _listeningUrl = url;

    /// <summary>Chooses the preferred loopback port, or port 0 (OS-assigned) only when it is owned by another process.</summary>
    internal static CompanionHttpEndpoint Select(int preferredPort)
    {
        try
        {
            using TcpListener probe = new(IPAddress.Loopback, preferredPort) { ExclusiveAddressUse = true };
            probe.Start();
            probe.Stop();
            return new(preferredPort, fallbackUsed: false);
        }
        catch (SocketException exception) when (exception.SocketErrorCode == SocketError.AddressAlreadyInUse)
        {
            return new(preferredPort, fallbackUsed: true);
        }
    }

    internal string RequestedUrl => FormattableString.Invariant($"http://127.0.0.1:{(FallbackUsed ? 0 : PreferredPort)}");
}
