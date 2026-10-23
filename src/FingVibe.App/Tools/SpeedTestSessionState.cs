namespace FingVibe.App;

internal enum SpeedTestSessionStatus
{
    Idle,
    Running,
    Cancelling,
    Succeeded,
    Failed,
    Cancelled
}

internal sealed class SpeedTestSessionState
{
    public string? RunId { get; private set; }

    public SpeedTestSessionStatus Status { get; private set; }

    public bool IsActive => Status is SpeedTestSessionStatus.Running or SpeedTestSessionStatus.Cancelling;

    public bool CanStartEngine => Status == SpeedTestSessionStatus.Running;

    public bool TryStart(string runId)
    {
        if (IsActive || string.IsNullOrWhiteSpace(runId))
        {
            return false;
        }

        RunId = runId;
        Status = SpeedTestSessionStatus.Running;
        return true;
    }

    public bool TryReset()
    {
        if (IsActive)
        {
            return false;
        }

        RunId = null;
        Status = SpeedTestSessionStatus.Idle;
        return true;
    }

    public bool RequestCancellation(string runId)
    {
        if (Status != SpeedTestSessionStatus.Running
            || !string.Equals(RunId, runId, StringComparison.Ordinal))
        {
            return false;
        }

        Status = SpeedTestSessionStatus.Cancelling;
        return true;
    }

    public bool Apply(SpeedTestBridgeMessage message)
    {
        if (!IsActive || !string.Equals(RunId, message.RunId, StringComparison.Ordinal))
        {
            return false;
        }

        if (Status == SpeedTestSessionStatus.Cancelling)
        {
            if (message.Kind is "cancelled" or "error" or "result")
            {
                Status = SpeedTestSessionStatus.Cancelled;
                return true;
            }

            return false;
        }

        switch (message.Kind)
        {
            case "progress":
                return true;
            case "result":
                Status = SpeedTestSessionStatus.Succeeded;
                return true;
            case "error":
                Status = SpeedTestSessionStatus.Failed;
                return true;
            case "cancelled":
                Status = SpeedTestSessionStatus.Cancelled;
                return true;
            default:
                return false;
        }
    }
}
