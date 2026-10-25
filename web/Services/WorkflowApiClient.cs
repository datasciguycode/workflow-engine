using System.Net.Http.Json;
using System.Text.Json.Nodes;

namespace WorkflowApp.Web.Services;

public record WorkflowSummary(string Id, string Name, string ItemLabel);
public record StageSummary(string Id, string Title, int? SequenceOrder, bool IsInitial, bool IsTerminal);
public record ItemSummary(string Id, string StageId, JsonObject Data);
public record ChatMessage(string Who, string Body, string? ItemId, string? StageId);
public record ItemEventRow(string EventType, string? StageId, JsonObject? Data);

// Local-dev-only config (Phase 4b, stubbed auth per 2026-10-15 decision). ApiUrl points at the
// machine's LAN IP, not 127.0.0.1/localhost, so this also works when the app is opened from a
// phone on the same wifi (confirmed reachable 2026-10-15 -- local Supabase's Kong gateway binds
// 0.0.0.0:54321). Swap for the real cloud project URL/anon key once that exists (GOAL.md).
public static class SupabaseConfig
{
    public const string ApiUrl = "http://192.168.9.196:54321";
    public const string AnonKey =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAi" +
        "OjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0";
    public const string DispatcherId = "8f3a0d26-5d86-4b18-8068-dae74693d42f";
    public const string DispatcherEmail = "dispatcher@acct1.test";
}

public class WorkflowApiClient
{
    private readonly HttpClient _http;

    public WorkflowApiClient(HttpClient http)
    {
        _http = http;
        _http.BaseAddress = new Uri(SupabaseConfig.ApiUrl);
    }

    private string Jwt => StubAuth.MintJwt(SupabaseConfig.DispatcherId, SupabaseConfig.DispatcherEmail);

    private HttpRequestMessage NewRequest(HttpMethod method, string path)
    {
        var req = new HttpRequestMessage(method, path);
        req.Headers.Add("apikey", SupabaseConfig.AnonKey);
        req.Headers.Add("Authorization", $"Bearer {Jwt}");
        return req;
    }

    public async Task<List<WorkflowSummary>> GetWorkflowsAsync()
    {
        var req = NewRequest(HttpMethod.Get, "/rest/v1/workflows?select=id,name,item_label&order=name.asc");
        var res = await _http.SendAsync(req);
        res.EnsureSuccessStatusCode();
        var rows = await res.Content.ReadFromJsonAsync<List<JsonObject>>() ?? [];
        return rows.Select(r => new WorkflowSummary(
            r["id"]!.GetValue<string>(),
            r["name"]!.GetValue<string>(),
            r["item_label"]!.GetValue<string>()
        )).ToList();
    }

    public async Task<WorkflowSummary?> GetWorkflowAsync(string workflowId)
    {
        var req = NewRequest(HttpMethod.Get, $"/rest/v1/workflows?id=eq.{workflowId}&select=id,name,item_label");
        var res = await _http.SendAsync(req);
        res.EnsureSuccessStatusCode();
        var rows = await res.Content.ReadFromJsonAsync<List<JsonObject>>() ?? [];
        var r = rows.FirstOrDefault();
        return r is null ? null : new WorkflowSummary(
            r["id"]!.GetValue<string>(), r["name"]!.GetValue<string>(), r["item_label"]!.GetValue<string>());
    }

    public async Task<List<StageSummary>> GetStagesAsync(string workflowId)
    {
        var req = NewRequest(HttpMethod.Get,
            $"/rest/v1/stages?workflow_id=eq.{workflowId}&select=id,title,sequence_order,is_initial,is_terminal&order=sequence_order.asc.nullslast");
        var res = await _http.SendAsync(req);
        res.EnsureSuccessStatusCode();
        var rows = await res.Content.ReadFromJsonAsync<List<JsonObject>>() ?? [];
        return rows.Select(r => new StageSummary(
            r["id"]!.GetValue<string>(),
            r["title"]!.GetValue<string>(),
            r["sequence_order"]?.GetValue<int?>(),
            r["is_initial"]!.GetValue<bool>(),
            r["is_terminal"]!.GetValue<bool>()
        )).ToList();
    }

    public async Task<List<ItemSummary>> GetItemsAsync(string workflowId)
    {
        var req = NewRequest(HttpMethod.Get,
            $"/rest/v1/items?workflow_id=eq.{workflowId}&select=id,stage_id,data&order=updated_at.desc");
        var res = await _http.SendAsync(req);
        res.EnsureSuccessStatusCode();
        var rows = await res.Content.ReadFromJsonAsync<List<JsonObject>>() ?? [];
        return rows.Select(r => new ItemSummary(
            r["id"]!.GetValue<string>(),
            r["stage_id"]!.GetValue<string>(),
            r["data"]!.AsObject()
        )).ToList();
    }

    // Not for display (there's no structured log in the UI -- see WorkflowDetail.razor) but for
    // deriving which stage a data field belongs to: item.created/item.data_changed events already
    // carry stage_id (fixed 2026-10-20) and the data/patch that was written, so replaying them in
    // order gives "this key was last written while at stage X" (2026-10-25).
    public async Task<List<ItemEventRow>> GetItemEventsAsync(string itemId)
    {
        var req = NewRequest(HttpMethod.Get,
            $"/rest/v1/item_events?item_id=eq.{itemId}&select=event_type,stage_id,data&order=created_at.asc");
        var res = await _http.SendAsync(req);
        res.EnsureSuccessStatusCode();
        var rows = await res.Content.ReadFromJsonAsync<List<JsonObject>>() ?? [];
        return rows.Select(r => new ItemEventRow(
            r["event_type"]!.GetValue<string>(),
            r["stage_id"]?.GetValue<string>(),
            r["data"] as JsonObject
        )).ToList();
    }

    // messages is the running Anthropic-shaped message array, passed through opaquely (text,
    // tool_use, and tool_result blocks all round-trip through here -- see agent-loop/index.ts).
    public async Task<(string Reply, JsonArray Messages)> SendAgentMessageAsync(
        string workflowId, JsonArray queue, JsonArray messages,
        string? selectedItemId = null, string? selectedItemLabel = null, string? selectedStageTitle = null)
    {
        var body = new JsonObject
        {
            ["workflow_id"] = workflowId,
            ["queue"] = queue.DeepClone(),
            ["messages"] = messages.DeepClone(),
            ["selected_item_id"] = selectedItemId,
            ["selected_item_label"] = selectedItemLabel,
            ["selected_stage_title"] = selectedStageTitle,
        };
        var req = NewRequest(HttpMethod.Post, "/functions/v1/agent-loop");
        req.Content = JsonContent.Create(body);
        var res = await _http.SendAsync(req);
        var text = await res.Content.ReadAsStringAsync();
        if (!res.IsSuccessStatusCode)
            throw new HttpRequestException($"agent-loop failed ({(int)res.StatusCode}): {text}");
        var json = JsonNode.Parse(text)!.AsObject();
        return (json["reply"]!.GetValue<string>(), json["messages"]!.AsArray());
    }

    // Persists chat as the only history record (2026-10-21 UI redesign). Ordered by created_at so
    // callers can just render them top-to-bottom as they come back.
    public async Task<List<ChatMessage>> GetChatMessagesAsync(string workflowId)
    {
        var req = NewRequest(HttpMethod.Get,
            $"/rest/v1/chat_messages?workflow_id=eq.{workflowId}&select=who,body,item_id,stage_id&order=created_at.asc");
        var res = await _http.SendAsync(req);
        res.EnsureSuccessStatusCode();
        var rows = await res.Content.ReadFromJsonAsync<List<JsonObject>>() ?? [];
        return rows.Select(r => new ChatMessage(
            r["who"]!.GetValue<string>(),
            r["body"]!.GetValue<string>(),
            r["item_id"]?.GetValue<string>(),
            r["stage_id"]?.GetValue<string>()
        )).ToList();
    }

    public async Task AddChatMessageAsync(string workflowId, string who, string body, string? itemId, string? stageId)
    {
        var req = NewRequest(HttpMethod.Post, "/rest/v1/chat_messages");
        req.Content = JsonContent.Create(new JsonObject
        {
            ["workflow_id"] = workflowId,
            ["item_id"] = itemId,
            ["stage_id"] = stageId,
            ["who"] = who,
            ["body"] = body,
        });
        var res = await _http.SendAsync(req);
        res.EnsureSuccessStatusCode();
    }
}
