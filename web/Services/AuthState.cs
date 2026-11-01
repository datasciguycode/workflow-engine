using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Components;
using Microsoft.JSInterop;

namespace WorkflowApp.Web.Services;

// Real Supabase Google OAuth (2026-10-31), replacing StubAuth's local-dev JWT stub. Uses GoTrue's
// implicit flow directly (no supabase-js, no PKCE): redirecting the browser to
// {ApiUrl}/auth/v1/authorize?provider=google&redirect_to=... lands back here with
// access_token/refresh_token/expires_in in the URL fragment, which InitializeAsync reads once on
// startup. The session is cached in localStorage so a reload doesn't force a fresh Google sign-in
// every time; GetValidAccessTokenAsync transparently refreshes the token when it's near expiry.
public class AuthState
{
    private const string StorageKey = "workflow-app.auth-session";

    private readonly NavigationManager _nav;
    private readonly IJSRuntime _js;
    private readonly HttpClient _http;

    private string? _accessToken;
    private string? _refreshToken;
    private long _expiresAtUnix;

    public bool IsReady { get; private set; }
    public bool IsSignedIn => _accessToken is not null;
    public string? Email { get; private set; }

    public AuthState(NavigationManager nav, IJSRuntime js)
    {
        _nav = nav;
        _js = js;
        _http = new HttpClient { BaseAddress = new Uri(SupabaseConfig.ApiUrl) };
    }

    public async Task InitializeAsync()
    {
        if (IsReady) return;

        if (TryParseFragmentTokens(out var accessToken, out var refreshToken, out var expiresIn))
        {
            await ApplySessionAsync(accessToken, refreshToken, expiresIn);
            StripFragment();
        }
        else
        {
            await RestoreFromStorageAsync();
        }

        IsReady = true;
    }

    public void SignInWithGoogle()
    {
        var redirectTo = _nav.BaseUri;
        var url = $"{SupabaseConfig.ApiUrl}/auth/v1/authorize?provider=google&redirect_to={Uri.EscapeDataString(redirectTo)}";
        _nav.NavigateTo(url, forceLoad: true);
    }

    public async Task SignOutAsync()
    {
        _accessToken = null;
        _refreshToken = null;
        _expiresAtUnix = 0;
        Email = null;
        await RemoveStorageAsync();
    }

    // Called by WorkflowApiClient before every request; refreshes proactively when the current
    // token is within a minute of expiring so callers never see a 401 from an expired JWT.
    public async Task<string> GetValidAccessTokenAsync()
    {
        if (_accessToken is null)
            throw new InvalidOperationException("Not signed in.");

        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        if (_expiresAtUnix - now < 60)
            await RefreshAsync();

        return _accessToken!;
    }

    private async Task RefreshAsync()
    {
        if (_refreshToken is null)
        {
            await SignOutAsync();
            throw new InvalidOperationException("Session expired; sign in again.");
        }

        var req = new HttpRequestMessage(HttpMethod.Post, "/auth/v1/token?grant_type=refresh_token");
        req.Headers.Add("apikey", SupabaseConfig.PublishableKey);
        req.Content = JsonContent.Create(new { refresh_token = _refreshToken });
        var res = await _http.SendAsync(req);
        if (!res.IsSuccessStatusCode)
        {
            await SignOutAsync();
            throw new InvalidOperationException("Session expired; sign in again.");
        }

        var json = await res.Content.ReadFromJsonAsync<JsonElement>();
        await ApplySessionAsync(
            json.GetProperty("access_token").GetString()!,
            json.GetProperty("refresh_token").GetString()!,
            json.GetProperty("expires_in").GetInt64());
    }

    private async Task ApplySessionAsync(string accessToken, string refreshToken, long expiresInSeconds)
    {
        _accessToken = accessToken;
        _refreshToken = refreshToken;
        _expiresAtUnix = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + expiresInSeconds;
        Email = ExtractEmailFromJwt(accessToken);

        var payload = JsonSerializer.Serialize(new
        {
            access_token = _accessToken,
            refresh_token = _refreshToken,
            expires_at = _expiresAtUnix,
            email = Email,
        });
        await _js.InvokeVoidAsync("localStorage.setItem", StorageKey, payload);
    }

    private async Task RestoreFromStorageAsync()
    {
        string? raw;
        try { raw = await _js.InvokeAsync<string?>("localStorage.getItem", StorageKey); }
        catch { raw = null; }

        if (raw is null) return;

        try
        {
            var stored = JsonSerializer.Deserialize<JsonElement>(raw);
            _accessToken = stored.GetProperty("access_token").GetString();
            _refreshToken = stored.GetProperty("refresh_token").GetString();
            _expiresAtUnix = stored.GetProperty("expires_at").GetInt64();
            Email = stored.TryGetProperty("email", out var e) ? e.GetString() : null;
        }
        catch
        {
            await RemoveStorageAsync();
        }
    }

    private async Task RemoveStorageAsync()
    {
        try { await _js.InvokeVoidAsync("localStorage.removeItem", StorageKey); }
        catch { /* private browsing / storage blocked */ }
    }

    private bool TryParseFragmentTokens(out string accessToken, out string refreshToken, out long expiresIn)
    {
        accessToken = "";
        refreshToken = "";
        expiresIn = 0;

        // e.g. "#access_token=...&refresh_token=...&expires_in=3600&token_type=bearer"
        var fragment = new Uri(_nav.Uri).Fragment;
        if (string.IsNullOrEmpty(fragment) || !fragment.Contains("access_token="))
            return false;

        var pairs = fragment.TrimStart('#').Split('&')
            .Select(p => p.Split('=', 2))
            .Where(p => p.Length == 2)
            .ToDictionary(p => p[0], p => Uri.UnescapeDataString(p[1]));

        if (!pairs.TryGetValue("access_token", out var at) || !pairs.TryGetValue("refresh_token", out var rt))
            return false;

        accessToken = at;
        refreshToken = rt;
        expiresIn = pairs.TryGetValue("expires_in", out var ei) && long.TryParse(ei, out var parsed) ? parsed : 3600;
        return true;
    }

    private void StripFragment()
    {
        var uri = new Uri(_nav.Uri);
        var clean = uri.GetLeftPart(UriPartial.Path) + uri.Query;
        _nav.NavigateTo(clean, replace: true);
    }

    private static string? ExtractEmailFromJwt(string jwt)
    {
        try
        {
            var payload = jwt.Split('.')[1];
            var padded = payload.Replace('-', '+').Replace('_', '/');
            padded += new string('=', (4 - padded.Length % 4) % 4);
            var bytes = Convert.FromBase64String(padded);
            var json = JsonSerializer.Deserialize<JsonElement>(bytes);
            return json.TryGetProperty("email", out var e) ? e.GetString() : null;
        }
        catch
        {
            return null;
        }
    }
}
