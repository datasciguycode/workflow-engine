using System.Net.Http.Json;
using System.Text.Json.Nodes;

namespace WorkflowApp.Web.Services;

public record WorkflowSummary(string Id, string Name, string ItemLabel);
public record StageSummary(string Id, string Title, int? SequenceOrder, bool IsInitial, bool IsTerminal, List<string> Checklist, List<string> OptionalChecklist);
public record ItemSummary(string Id, string StageId, JsonObject Data, DateTimeOffset CreatedAt);
// search_items RPC result (2026-11-08) -- same shape as ItemSummary plus the job number computed
// server-side (1-based position among the workflow's items ordered by created_at), so the Jobs
// list's search results don't need the full unfiltered item list just to label "Job #N".
public record ItemSearchResult(string Id, string StageId, JsonObject Data, DateTimeOffset CreatedAt, long JobNumber);
public record ChatMessage(string Who, string Body, string? ItemId, string? StageId);
public record ItemEventRow(string EventType, string? StageId, JsonObject? Data);
// add_note's event data is a plain JSON string (to_jsonb(p_note)), not an object like
// item.created/item.data_changed -- ItemEventRow.Data (typed JsonObject?) can't hold that
// shape, so notes get their own fetch/record rather than forcing a cast that would silently
// come back null (2026-11-07).
public record ItemNote(string Text, string? StageId, DateTimeOffset CreatedAt);

// Cloud project config (workflow-engine-test, pointed here 2026-10-31 replacing local dev).
// PublishableKey is the new sb_publishable_... format (replaces the legacy JWT anon key) --
// goes in the same `apikey` header either way.
public static class SupabaseConfig
{
    public const string ApiUrl = "https://utwyvtbzesswpoihmlic.supabase.co";
    public const string PublishableKey = "sb_publishable_Ec1_eTAJtWMb2AaC1ULE7w_8f0BvYsk";
}

public class WorkflowApiClient
{
    private readonly HttpClient _http;
    private readonly AuthState _auth;

    public WorkflowApiClient(HttpClient http, AuthState auth)
    {
        _http = http;
        _http.BaseAddress = new Uri(SupabaseConfig.ApiUrl);
        _auth = auth;
    }

    private async Task<HttpRequestMessage> NewRequestAsync(HttpMethod method, string path)
    {
        var jwt = await _auth.GetValidAccessTokenAsync();
        var req = new HttpRequestMessage(method, path);
        req.Headers.Add("apikey", SupabaseConfig.PublishableKey);
        req.Headers.Add("Authorization", $"Bearer {jwt}");
        return req;
    }

    public async Task<List<WorkflowSummary>> GetWorkflowsAsync()
    {
        var req = await NewRequestAsync(HttpMethod.Get, "/rest/v1/workflows?select=id,name,item_label&order=name.asc");
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
        var req = await NewRequestAsync(HttpMethod.Get, $"/rest/v1/workflows?id=eq.{workflowId}&select=id,name,item_label");
        var res = await _http.SendAsync(req);
        res.EnsureSuccessStatusCode();
        var rows = await res.Content.ReadFromJsonAsync<List<JsonObject>>() ?? [];
        var r = rows.FirstOrDefault();
        return r is null ? null : new WorkflowSummary(
            r["id"]!.GetValue<string>(), r["name"]!.GetValue<string>(), r["item_label"]!.GetValue<string>());
    }

    public async Task<List<StageSummary>> GetStagesAsync(string workflowId)
    {
        var req = await NewRequestAsync(HttpMethod.Get,
            $"/rest/v1/stages?workflow_id=eq.{workflowId}&select=id,title,sequence_order,is_initial,is_terminal,checklist,optional_checklist&order=sequence_order.asc.nullslast");
        var res = await _http.SendAsync(req);
        res.EnsureSuccessStatusCode();
        var rows = await res.Content.ReadFromJsonAsync<List<JsonObject>>() ?? [];
        return rows.Select(r => new StageSummary(
            r["id"]!.GetValue<string>(),
            r["title"]!.GetValue<string>(),
            r["sequence_order"]?.GetValue<int?>(),
            r["is_initial"]!.GetValue<bool>(),
            r["is_terminal"]!.GetValue<bool>(),
            r["checklist"] is JsonArray arr
                ? arr.Select(v => v!.GetValue<string>()).ToList()
                : [],
            r["optional_checklist"] is JsonArray optArr
                ? optArr.Select(v => v!.GetValue<string>()).ToList()
                : []
        )).ToList();
    }

    public async Task<List<ItemSummary>> GetItemsAsync(string workflowId)
    {
        var req = await NewRequestAsync(HttpMethod.Get,
            $"/rest/v1/items?workflow_id=eq.{workflowId}&select=id,stage_id,data,created_at&order=updated_at.desc");
        var res = await _http.SendAsync(req);
        res.EnsureSuccessStatusCode();
        var rows = await res.Content.ReadFromJsonAsync<List<JsonObject>>() ?? [];
        return rows.Select(r => new ItemSummary(
            r["id"]!.GetValue<string>(),
            r["stage_id"]!.GetValue<string>(),
            r["data"]!.AsObject(),
            r["created_at"]!.GetValue<DateTimeOffset>()
        )).ToList();
    }

    // Tap-to-search on the Jobs list (2026-11-08) -- runs server-side via the search_items RPC
    // instead of loading every item and filtering client-side, so the Jobs list itself can stay
    // on a cheap default fetch (or, later, a paged one) regardless of search volume. See
    // supabase/migrations/20261108030000_add_search_items.sql for what it matches against.
    public async Task<List<ItemSearchResult>> SearchItemsAsync(string workflowId, string query)
    {
        var req = await NewRequestAsync(HttpMethod.Post, "/rest/v1/rpc/search_items");
        req.Content = JsonContent.Create(new JsonObject
        {
            ["p_workflow_id"] = workflowId,
            ["p_query"] = query,
        });
        var res = await _http.SendAsync(req);
        res.EnsureSuccessStatusCode();
        var rows = await res.Content.ReadFromJsonAsync<List<JsonObject>>() ?? [];
        return rows.Select(r => new ItemSearchResult(
            r["id"]!.GetValue<string>(),
            r["stage_id"]!.GetValue<string>(),
            r["data"]!.AsObject(),
            r["created_at"]!.GetValue<DateTimeOffset>(),
            r["job_number"]!.GetValue<long>()
        )).ToList();
    }

    // Not for display (there's no structured log in the UI -- see WorkflowDetail.razor) but for
    // deriving which stage a data field belongs to: item.created/item.data_changed events already
    // carry stage_id (fixed 2026-10-20) and the data/patch that was written, so replaying them in
    // order gives "this key was last written while at stage X" (2026-10-25).
    public async Task<List<ItemEventRow>> GetItemEventsAsync(string itemId)
    {
        var req = await NewRequestAsync(HttpMethod.Get,
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

    // For display (see WorkflowDetail.razor's Notes section, added 2026-11-07): every add_note
    // call for this item, most recent first. Kept separate from GetItemEventsAsync because a
    // note's data is a plain JSON string (to_jsonb(p_note)), not an object.
    public async Task<List<ItemNote>> GetNotesAsync(string itemId)
    {
        var req = await NewRequestAsync(HttpMethod.Get,
            $"/rest/v1/item_events?item_id=eq.{itemId}&event_type=eq.item.note_added&select=data,stage_id,created_at&order=created_at.desc");
        var res = await _http.SendAsync(req);
        res.EnsureSuccessStatusCode();
        var rows = await res.Content.ReadFromJsonAsync<List<JsonObject>>() ?? [];
        return rows.Select(r => new ItemNote(
            r["data"]!.GetValue<string>(),
            r["stage_id"]?.GetValue<string>(),
            r["created_at"]!.GetValue<DateTimeOffset>()
        )).ToList();
    }

    // Same RPC the agent's move_stage tool calls (supabase/functions/agent-loop/index.ts) --
    // used directly by the UI's "Done" button so advancing a stage doesn't require going through
    // chat once its checklist is already complete (2026-11-05).
    public async Task MoveStageAsync(string itemId, string toStageId)
    {
        var req = await NewRequestAsync(HttpMethod.Post, "/rest/v1/rpc/move_stage");
        req.Content = JsonContent.Create(new JsonObject
        {
            ["p_item_id"] = itemId,
            ["p_to_stage_id"] = toStageId,
        });
        var res = await _http.SendAsync(req);
        if (!res.IsSuccessStatusCode)
            throw new HttpRequestException($"move_stage failed ({(int)res.StatusCode}): {await res.Content.ReadAsStringAsync()}");
    }

    // Same RPC the agent's update_data tool calls -- used directly by the VIN-scan button so
    // writing the extracted value is deterministic and doesn't need a model round trip at all,
    // same reasoning as AddNoteAsync below (2026-11-11).
    public async Task UpdateDataAsync(string itemId, JsonObject patch)
    {
        var req = await NewRequestAsync(HttpMethod.Post, "/rest/v1/rpc/update_data");
        req.Content = JsonContent.Create(new JsonObject
        {
            ["p_item_id"] = itemId,
            ["p_patch"] = patch,
        });
        var res = await _http.SendAsync(req);
        if (!res.IsSuccessStatusCode)
            throw new HttpRequestException($"update_data failed ({(int)res.StatusCode}): {await res.Content.ReadAsStringAsync()}");
    }

    // One-shot image read, not part of the chat/tool-use loop -- the photo is never stored or
    // added to any conversation history, it's read once here and discarded (2026-11-11).
    public async Task<string?> ScanVinAsync(string imageBase64, string mediaType)
    {
        var req = await NewRequestAsync(HttpMethod.Post, "/functions/v1/scan-vin");
        req.Content = JsonContent.Create(new JsonObject
        {
            ["image_base64"] = imageBase64,
            ["media_type"] = mediaType,
        });
        var res = await _http.SendAsync(req);
        var text = await res.Content.ReadAsStringAsync();
        if (!res.IsSuccessStatusCode)
            throw new HttpRequestException($"scan-vin failed ({(int)res.StatusCode}): {text}");
        var json = JsonNode.Parse(text)!.AsObject();
        return json["vin"]?.GetValue<string>();
    }

    // Same RPC the agent's add_note tool calls -- used directly by the chat box's "Save as
    // note" checkbox so logging a note is deterministic and doesn't require an AI round trip
    // at all (2026-11-08). stageId is the stage page the note was saved from, or null when saved
    // from the job overview page -- that's what makes it a job-level vs. stage-level note.
    public async Task AddNoteAsync(string itemId, string note, string? stageId)
    {
        var req = await NewRequestAsync(HttpMethod.Post, "/rest/v1/rpc/add_note");
        req.Content = JsonContent.Create(new JsonObject
        {
            ["p_item_id"] = itemId,
            ["p_note"] = note,
            ["p_stage_id"] = stageId,
        });
        var res = await _http.SendAsync(req);
        if (!res.IsSuccessStatusCode)
            throw new HttpRequestException($"add_note failed ({(int)res.StatusCode}): {await res.Content.ReadAsStringAsync()}");
    }

    // messages is the running Anthropic-shaped message array, passed through opaquely (text,
    // tool_use, and tool_result blocks all round-trip through here -- see agent-loop/index.ts).
    public async Task<(string Reply, JsonArray Messages)> SendAgentMessageAsync(
        string workflowId, JsonArray queue, JsonArray messages,
        string? selectedItemId = null, string? selectedItemLabel = null, string? selectedStageTitle = null,
        string? selectedStageId = null, int? selectedJobNumber = null, int? selectedStageMessageCount = null)
    {
        var body = new JsonObject
        {
            ["workflow_id"] = workflowId,
            ["queue"] = queue.DeepClone(),
            ["messages"] = messages.DeepClone(),
            ["selected_item_id"] = selectedItemId,
            ["selected_item_label"] = selectedItemLabel,
            ["selected_stage_title"] = selectedStageTitle,
            ["selected_stage_id"] = selectedStageId,
            ["selected_job_number"] = selectedJobNumber,
            ["selected_stage_message_count"] = selectedStageMessageCount,
        };
        var req = await NewRequestAsync(HttpMethod.Post, "/functions/v1/agent-loop");
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
        var req = await NewRequestAsync(HttpMethod.Get,
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
        var req = await NewRequestAsync(HttpMethod.Post, "/rest/v1/chat_messages");
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
