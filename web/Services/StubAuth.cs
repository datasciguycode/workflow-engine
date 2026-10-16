using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace WorkflowApp.Web.Services;

// Stubbed auth for Phase 4b UI development (decided 2026-10-15): mints the same kind of JWT
// scripts/phase4a_agent_loop_test.py mints by hand, using local Supabase's well-known dev
// JWT_SECRET. Real sign-in (SPEC.md §6 step 0, Google OAuth) is deliberately deferred until
// after the workflow picker/item list/chat UI exists to wire it into.
public static class StubAuth
{
    private const string JwtSecret = "super-secret-jwt-token-with-at-least-32-characters-long";

    public static string MintJwt(string userId, string email)
    {
        var header = new { alg = "HS256", typ = "JWT" };
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var payload = new
        {
            aud = "authenticated",
            role = "authenticated",
            sub = userId,
            email,
            iss = "supabase-demo",
            iat = now,
            exp = now + 3600,
        };

        var headerJson = JsonSerializer.Serialize(header);
        var payloadJson = JsonSerializer.Serialize(payload);
        var signingInput = $"{Base64UrlEncode(headerJson)}.{Base64UrlEncode(payloadJson)}";

        using var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(JwtSecret));
        var signature = hmac.ComputeHash(Encoding.UTF8.GetBytes(signingInput));
        return $"{signingInput}.{Base64UrlEncode(signature)}";
    }

    private static string Base64UrlEncode(string s) => Base64UrlEncode(Encoding.UTF8.GetBytes(s));

    private static string Base64UrlEncode(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
