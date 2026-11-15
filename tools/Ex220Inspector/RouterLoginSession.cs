namespace Ex220Inspector;

public enum LoginAction { None, Prompt, AutoLogin, Failed, Authenticated }

public sealed class RouterLoginSession
{
    private string? _password;
    private bool _prompted;
    private bool _automaticAttempted;
    private bool _authenticated;
    private DateTimeOffset? _submittedAt;

    public bool HasPassword => _password is not null;
    public bool IsPending => _submittedAt is not null;
    internal string? PasswordForLogin => _password;

    public void Remember(string? password) => _password = password;
    public void DismissPrompt() => _prompted = true;
    public void Forget() => _password = null;
    public void FailSubmission()
    {
        _password = null;
        _submittedAt = null;
        _automaticAttempted = true;
        _prompted = true;
    }

    public void Submitted(DateTimeOffset now)
    {
        _submittedAt = now;
        _automaticAttempted = true;
        _prompted = true;
    }

    public LoginAction Observe(string state, bool error, DateTimeOffset now)
    {
        if (state == "Authenticated")
        {
            var changed = !_authenticated;
            _authenticated = true;
            _prompted = false;
            _automaticAttempted = false;
            _submittedAt = null;
            return changed ? LoginAction.Authenticated : LoginAction.None;
        }
        if (_submittedAt is { } submitted && (now - submitted >= TimeSpan.FromSeconds(15)
            || state == "Login" && error && now - submitted >= TimeSpan.FromSeconds(1)))
        {
            _submittedAt = null;
            _password = null;
            return LoginAction.Failed;
        }
        if (state != "Login" || IsPending) return LoginAction.None;
        _authenticated = false;
        if (_password is not null && !_automaticAttempted)
        {
            _automaticAttempted = true;
            _prompted = true;
            return LoginAction.AutoLogin;
        }
        if (_prompted) return LoginAction.None;
        _prompted = true;
        return LoginAction.Prompt;
    }
}
