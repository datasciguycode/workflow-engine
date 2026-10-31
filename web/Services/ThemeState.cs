namespace WorkflowApp.Web.Services;

// Singleton so the toggle's current mode survives page navigation (each page would otherwise
// re-mount ThemeToggleButton and lose track of whether the user had already picked Dark).
// 2026-10-31: replaced an attempt at the Sections API (SectionContent/SectionOutlet) here -- that
// rendered nothing visible after three rounds of fixes with no devtools access to diagnose why,
// so this plain injected-singleton approach was used instead: simpler and directly verifiable.
public class ThemeState
{
    public bool Initialized { get; set; }
    public bool IsDark { get; set; }
}
