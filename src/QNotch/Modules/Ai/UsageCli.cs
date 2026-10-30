using QNotch.Core.Consumers;

namespace QNotch.Modules.Ai;

internal static class UsageCli
{
    public static int Run(string[] args) => ConsumerCli.Run("usage", args,
        "QNotch.exe usage [--json] [--details] [--provider claude|codex] [--account ID]", Validate);
    public static void Validate(ConsumerRequest request)
    {
        if (request.Provider is not (null or "claude" or "codex")) throw new ConsumerException("invalid_arguments", "Unknown provider.");
    }
}
