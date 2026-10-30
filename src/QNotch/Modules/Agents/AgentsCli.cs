using QNotch.Core.Consumers;

namespace QNotch.Modules.Agents;

internal static class AgentsCli
{
    public static int Run(string[] args) => ConsumerCli.Run("agents", args, "QNotch.exe agents [--json] [--details]", Validate);
    public static void Validate(ConsumerRequest request)
    {
        if (request.Provider is not null || request.Account is not null) throw new ConsumerException("invalid_arguments", "Provider and account filters apply only to usage.");
    }
}
