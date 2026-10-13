using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;

namespace QNotch.Core.Updates;

internal sealed class UpdateClient(HttpClient http)
{
    public async Task<UpdateRelease?> CheckAsync(Version installed, bool selfContained, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.github.com/repos/Somafet/qnotch/releases/latest");
        request.Headers.UserAgent.ParseAdd($"QNotch/{installed}");
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation).ConfigureAwait(false);
        if (response.StatusCode == HttpStatusCode.NotFound) return null; // no published releases yet
        if (response.StatusCode is HttpStatusCode.Forbidden or HttpStatusCode.TooManyRequests)
            throw new HttpRequestException("GitHub is limiting update checks. Try again later.");
        response.EnsureSuccessStatusCode();
        await response.Content.LoadIntoBufferAsync(1_048_576, cancellation).ConfigureAwait(false);
        return UpdateRelease.Read(await response.Content.ReadAsStringAsync(cancellation).ConfigureAwait(false), installed, selfContained);
    }

    /// <summary>Download and verify on a worker thread, without touching the installed executable.</summary>
    public async Task DownloadAsync(UpdateRelease release, string directory, IProgress<int>? progress, CancellationToken cancellation)
    {
        var download = Path.Combine(directory, "download");
        using (var request = new HttpRequestMessage(HttpMethod.Get, release.Download))
        {
            request.Headers.UserAgent.ParseAdd("QNotch-Updater");
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            if (response.RequestMessage?.RequestUri?.Scheme != Uri.UriSchemeHttps)
                throw new InvalidDataException("The update download did not use HTTPS.");
            if (response.Content.Headers.ContentLength is { } length && length != release.Size)
                throw new InvalidDataException("The update download size does not match the release.");
            await using var input = await response.Content.ReadAsStreamAsync(cancellation).ConfigureAwait(false);
            await using var output = new FileStream(download, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, true);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[81920];
            long total = 0;
            var lastPercent = -1;
            int read;
            while ((read = await input.ReadAsync(buffer, cancellation).ConfigureAwait(false)) > 0)
            {
                total += read;
                if (total > release.Size) throw new InvalidDataException("The update download is larger than expected.");
                hash.AppendData(buffer, 0, read);
                await output.WriteAsync(buffer.AsMemory(0, read), cancellation).ConfigureAwait(false);
                var percent = (int)(total * 100 / release.Size);
                if (percent != lastPercent) { progress?.Report(percent); lastPercent = percent; }
            }
            if (total != release.Size || !string.Equals(Convert.ToHexString(hash.GetHashAndReset()), release.Sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The update checksum did not match. Nothing was installed.");
        }

        var exe = Path.Combine(directory, "QNotch.exe");
        if (release.IsZip)
        {
            using var zip = ZipFile.OpenRead(download);
            // The release workflow packages a single exe. Never extract arbitrary paths from a downloaded archive.
            if (zip.Entries.Count != 1 || zip.Entries[0].FullName != "QNotch.exe"
                || zip.Entries[0].Length is <= 0 or > UpdateRelease.MaxDownloadSize)
                throw new InvalidDataException("The update archive is not a QNotch package.");
            zip.Entries[0].ExtractToFile(exe);
        }
        else File.Move(download, exe);
        ValidateExecutable(exe, release.Version);
    }

    internal static void ValidateExecutable(string path, Version expected)
    {
        using var file = File.OpenRead(path);
        using var reader = new BinaryReader(file);
        if (file.Length < 64 || reader.ReadUInt16() != 0x5A4D) throw new InvalidDataException("The update is not a Windows executable.");
        file.Position = 0x3C;
        var pe = reader.ReadInt32();
        if (pe < 64 || pe > file.Length - 6) throw new InvalidDataException("The update executable is invalid.");
        file.Position = pe;
        if (reader.ReadUInt32() != 0x00004550 || reader.ReadUInt16() != 0x8664)
            throw new InvalidDataException("The update is not a Windows x64 executable.");
        if (UpdateRelease.ParseVersion(FileVersionInfo.GetVersionInfo(path).FileVersion) != expected)
            throw new InvalidDataException("The update executable version does not match the release.");
    }
}
