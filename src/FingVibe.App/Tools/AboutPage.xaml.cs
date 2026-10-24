using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class AboutPage : UserControl
{
    public event EventHandler? BackRequested;

    public AboutPage()
    {
        InitializeComponent();
        var build = BuildIdentity.Current;
        VersionText.Text = build.Version;
        BuildKindText.Text = build.Label;
        CommitText.Text = build.Commit is null ? "Commit not recorded for this build." : $"Commit: {build.Commit}";
        PullRequestLink.NavigateUri = build.PullRequestUri;
        PullRequestLink.Visibility = build.PullRequestUri is null ? Visibility.Collapsed : Visibility.Visible;
        BuildLink.NavigateUri = build.BuildUri;
        BuildLink.Visibility = build.BuildUri is null ? Visibility.Collapsed : Visibility.Visible;
    }

    public void FocusHeading() => PageHeading.Focus(FocusState.Programmatic);

    private void Back_Click(object sender, RoutedEventArgs e) => BackRequested?.Invoke(this, EventArgs.Empty);
}
