using Microsoft.UI.Windowing;

namespace FingVibe.App;

internal static class AppWindowState
{
    public static bool IsMinimized(this AppWindow window) =>
        window.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized };
}
