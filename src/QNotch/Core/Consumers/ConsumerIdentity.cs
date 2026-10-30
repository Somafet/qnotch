using System.Security.Cryptography;
using System.Text;

namespace QNotch.Core.Consumers;

/// <summary>Installation-local pseudonyms, without storing a growing session/path mapping.</summary>
internal sealed class ConsumerIdentity
{
    public sealed class LocalSettings { public string Key { get; set; } = ""; }
    readonly byte[] _key;
    public ConsumerIdentity(SettingsStore store)
    {
        var settings = store.Get<LocalSettings>("consumer.identity");
        try { _key = Convert.FromBase64String(settings.Key); } catch (FormatException) { _key = []; }
        if (_key.Length != 32)
        {
            _key = RandomNumberGenerator.GetBytes(32);
            settings.Key = Convert.ToBase64String(_key);
            store.Save("consumer.identity", settings);
        }
    }
    internal ConsumerIdentity(byte[] key) => _key = key;
    public string Id(string scope, string value) => Convert.ToHexStringLower(HMACSHA256.HashData(_key, Encoding.UTF8.GetBytes(scope + "\0" + value)))[..32];
}
