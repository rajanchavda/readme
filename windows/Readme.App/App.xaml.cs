using Microsoft.UI.Xaml;

namespace Readme.App;

public partial class App : Application
{
    readonly IReadOnlyList<string> _arguments;
    AppCoordinator? _coordinator;

    /// <summary><paramref name="arguments"/>: the command line, or the files Windows opened the app with.</summary>
    public App(IReadOnlyList<string> arguments)
    {
        _arguments = arguments;
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _coordinator = new AppCoordinator(_arguments.ToArray(), Exit);
        _coordinator.Launch();
    }
}
