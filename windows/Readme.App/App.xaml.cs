using Microsoft.UI.Xaml;

namespace Readme.App;

public partial class App : Application
{
    AppCoordinator? _coordinator;

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _coordinator = new AppCoordinator(Environment.GetCommandLineArgs().Skip(1).ToArray(), Exit);
        _coordinator.Launch();
    }
}
