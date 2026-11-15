using Ex220Inspector;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class Ex220LoginSessionTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 15, 10, 0, 0, TimeSpan.Zero);

    [Fact]
    public void PromptIsShownOnceAndAutomaticLoginIsBoundedPerExpiredSession()
    {
        var session = new RouterLoginSession();
        Assert.Equal(LoginAction.Prompt, session.Observe("Login", false, Now));
        Assert.Equal(LoginAction.None, session.Observe("Login", false, Now));
        session.Remember("test-password");
        session.Submitted(Now);
        Assert.Equal(LoginAction.Authenticated, session.Observe("Authenticated", false, Now));
        Assert.True(session.HasPassword);
        Assert.Equal(LoginAction.AutoLogin, session.Observe("Login", false, Now));
        Assert.Equal(LoginAction.None, session.Observe("Login", false, Now));
        session.Submitted(Now);
        Assert.Equal(LoginAction.None, session.Observe("Login", false, Now.AddSeconds(5)));
        Assert.Equal(LoginAction.Authenticated, session.Observe("Authenticated", false, Now.AddSeconds(6)));
        Assert.Equal(LoginAction.AutoLogin, session.Observe("Login", false, Now.AddSeconds(7)));
    }

    [Fact]
    public void RejectedPasswordIsForgottenAndDoesNotLoop()
    {
        var session = new RouterLoginSession();
        session.Remember("test-password");
        session.Submitted(Now);
        Assert.Equal(LoginAction.Failed, session.Observe("Login", true, Now.AddSeconds(2)));
        Assert.False(session.HasPassword);
        Assert.False(session.IsPending);
        Assert.Equal(LoginAction.None, session.Observe("Login", true, Now.AddSeconds(3)));
    }

    [Fact]
    public void TimeoutDuringNavigationClearsPasswordAndExplicitRetryCanRecover()
    {
        var session = new RouterLoginSession();
        session.Remember("test-password");
        session.Submitted(Now);
        Assert.Equal(LoginAction.None, session.Observe("Other", false, Now.AddSeconds(14)));
        Assert.Equal(LoginAction.Failed, session.Observe("Other", false, Now.AddSeconds(15)));
        Assert.False(session.HasPassword);
        session.Remember("replacement");
        session.Submitted(Now.AddSeconds(16));
        Assert.Equal(LoginAction.Authenticated, session.Observe("Authenticated", false, Now.AddSeconds(17)));
        Assert.True(session.HasPassword);
        session.Forget();
        Assert.False(session.HasPassword);
        Assert.Equal(LoginAction.Prompt, session.Observe("Login", false, Now.AddSeconds(18)));
    }

    [Fact]
    public void LockedSetupAndUsernameFormsNeverTriggerAutomaticLogin()
    {
        var session = new RouterLoginSession();
        session.Remember("test-password");
        foreach (var state in new[] { "Locked", "UsernameRequired", "Other" })
            Assert.Equal(LoginAction.None, session.Observe(state, false, Now));
        session.FailSubmission();
        Assert.False(session.HasPassword);
        Assert.Equal(LoginAction.None, session.Observe("Login", false, Now));
    }
}
