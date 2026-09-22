// replay2json — parse a Fortnite .replay and emit a normalized match JSON.
using System.Collections;
using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;
using FortniteReplayReader;
using Unreal.Core.Models.Enums;

var path = args.Length > 0 ? args[0] : throw new ArgumentException("usage: replay2json <file.replay>");
var fileName = Path.GetFileName(path);

static object G(object o, string n) { try { return o?.GetType().GetProperty(n)?.GetValue(o); } catch { return null; } }
static int? I(object o, string n) { var v = G(o, n); return v == null ? null : Convert.ToInt32(v); }
static string S(object o, string n) { var v = G(o, n); return v?.ToString(); }
static bool? B(object o, string n) { var v = G(o, n); return v == null ? null : (bool?)Convert.ToBoolean(v); }
static double? F(object o, string n) { var v = G(o, n); return v == null ? null : Convert.ToDouble(v); }
static Dictionary<string, object> Vec(object o, string n) {
    var v = G(o, n); if (v == null) return null;
    return new Dictionary<string, object> { ["x"] = F(v, "X"), ["y"] = F(v, "Y"), ["z"] = F(v, "Z") };
}
static List<object> L(object o, string n) {
    if (G(o, n) is IEnumerable e && e is not string) { var r = new List<object>(); foreach (var x in e) r.Add(x); return r; }
    return new List<object>();
}
static string Humanize(string p) {
    if (string.IsNullOrEmpty(p)) return "Battle Royale";
    var nb = p.Contains("NoBuild") ? "No Build " : "";
    var m = p.Contains("Solo") ? "Solo" : p.Contains("Duo") ? "Duos" : p.Contains("Trio") ? "Trios"
          : p.Contains("Squad") ? "Squads" : "Battle Royale";
    return nb + m;
}
static int NonNullCount(Dictionary<string, object> p) => p.Values.Count(v => v != null && !(v is bool b && b == false));

try
{
    var replay = new ReplayReader(null, ParseMode.Normal).ReadReplay(path);
    var info = G(replay, "Info");
    var gd = G(replay, "GameData");
    var ts = G(replay, "TeamStats");
    var st = G(replay, "Stats");
    var map = G(replay, "MapData");

    int? teamPosition = I(ts, "Position");
    int? totalPlayers = I(ts, "TotalPlayers");
    int? myElims = I(st, "Eliminations");
    int? lengthMs = I(info, "LengthInMs");
    string playlistRaw = S(gd, "CurrentPlaylist");

    var tsRaw = G(info, "Timestamp");
    string playedAt = tsRaw is DateTime dt ? dt.ToString("yyyy-MM-ddTHH:mm:ss") : null;
    if (playedAt == null)
    {
        var m0 = Regex.Match(fileName, @"(\d{4})\.(\d{2})\.(\d{2})-(\d{2})\.(\d{2})\.(\d{2})");
        if (m0.Success) playedAt = $"{m0.Groups[1]}.{m0.Groups[2]}.{m0.Groups[3]}T{m0.Groups[4]}:{m0.Groups[5]}:{m0.Groups[6]}";
    }

    var players = L(replay, "PlayerData").Select(p => new Dictionary<string, object>
    {
        ["id"] = I(p, "Id"),
        ["name"] = S(p, "PlayerName"),
        ["team"] = I(p, "TeamIndex"),
        ["kills"] = I(p, "Kills"),
        ["isBot"] = B(p, "IsBot") ?? false,
        ["level"] = I(p, "Level"),
        ["platform"] = S(p, "Platform"),
        ["isReplayOwner"] = B(p, "IsReplayOwner") ?? false,
        ["isPartyLeader"] = B(p, "IsPartyLeader") ?? false,
    }).ToList();

    var teams = L(replay, "TeamData").Select(t => new Dictionary<string, object>
    {
        ["teamIndex"] = I(t, "TeamIndex"),
        ["placement"] = I(t, "Placement"),
        ["teamKills"] = I(t, "TeamKills"),
        ["players"] = L(t, "PlayerNames").Select(x => x?.ToString()).Where(x => !string.IsNullOrEmpty(x)).ToList(),
    }).ToList();

    // ---- kill feed (resolved to display names via the integer player ids) ----
    var idToName = new Dictionary<int, string>();
    foreach (var p in players) {
        var pid = (int?)p["id"];
        if (pid != null && p["name"] != null && !idToName.ContainsKey(pid.Value)) idToName[pid.Value] = (string)p["name"];
    }
    var killFeed = L(replay, "KillFeed").Select(k => {
        var vid = I(k, "PlayerId"); var kid = I(k, "FinisherOrDowner");
        bool? downed = B(k, "IsDowned"), revived = B(k, "IsRevived");
        string kind = (revived == true) ? "revived" : (downed == true) ? "knocked" : "eliminated";
        return new Dictionary<string, object> {
            ["time"] = F(k, "ReplicatedWorldTimeSeconds"),
            ["victim"] = (vid != null && idToName.ContainsKey(vid.Value)) ? idToName[vid.Value] : "?",
            ["victimBot"] = B(k, "PlayerIsBot") ?? false,
            ["killer"] = (kid != null && idToName.ContainsKey(kid.Value)) ? idToName[kid.Value] : "?",
            ["killerBot"] = B(k, "FinisherOrDownerIsBot") ?? false,
            ["kind"] = kind,
            ["distance"] = F(k, "Distance"),
            ["cause"] = I(k, "DeathCause"),
            ["loc"] = Vec(k, "DeathLocation"),
        };
    }).ToList();

    // ---- storm / safe-zone phases (for the map animation) ----
    var safeZones = L(map, "SafeZones").Select(z => new Dictionary<string, object>
    {
        ["radius"] = F(z, "Radius"),
        ["startShrink"] = F(z, "StartShrinkTime"),
        ["finishShrink"] = F(z, "FinishShrinkTime"),
        ["lastRadius"] = F(z, "LastRadius"),
        ["lastCenter"] = Vec(z, "LastCenter"),
        ["nextRadius"] = F(z, "NextRadius"),
        ["nextCenter"] = Vec(z, "NextCenter"),
        ["nextNextRadius"] = F(z, "NextNextRadius"),
        ["nextNextCenter"] = Vec(z, "NextNextCenter"),
    }).ToList();

    var worldGrid = new Dictionary<string, object>
    {
        ["start"] = Vec(map, "WorldGridStart"),
        ["end"] = Vec(map, "WorldGridEnd"),
        ["spacing"] = Vec(map, "WorldGridSpacing"),
        ["countX"] = I(map, "GridCountX"),
        ["countY"] = I(map, "GridCountY"),
        ["total"] = Vec(map, "WorldGridTotalSize"),
    };

    var bus = L(map, "BattleBusFlightPaths").Select(b => new Dictionary<string, object>
    {
        ["start"] = Vec(b, "FlightStartLocation"),
        ["speed"] = F(b, "FlightSpeed"),
        ["flightEnd"] = F(b, "TimeTillFlightEnd"),
        ["dropStart"] = F(b, "TimeTillDropStart"),
        ["dropEnd"] = F(b, "TimeTillDropEnd"),
    }).ToList();

    // ---- identify "me" ----
    int? myTeam = null;
    var tt = teams.FirstOrDefault(t => teamPosition != null && Equals((int?)t["placement"], teamPosition));
    if (tt != null) myTeam = (int?)tt["teamIndex"];

    var candidates = myTeam != null ? players.Where(p => (int?)p["team"] == myTeam).ToList() : players.ToList();
    var meArg = Environment.GetEnvironmentVariable("ME_NAME");

    Dictionary<string, object> me =
        candidates.FirstOrDefault(p => (bool)p["isReplayOwner"])
     ?? (meArg != null ? players.FirstOrDefault(p => string.Equals((string)p["name"], meArg, StringComparison.OrdinalIgnoreCase)) : null)
     ?? (myElims != null ? candidates.FirstOrDefault(p => Equals((int?)p["kills"], myElims)) : null)
     ?? candidates.FirstOrDefault(p => (bool)p["isPartyLeader"])
     ?? candidates.OrderByDescending(NonNullCount).FirstOrDefault();

    if (me != null && myTeam == null) myTeam = (int?)me["team"];
    var teammates = myTeam != null ? players.Where(p => (int?)p["team"] == myTeam).ToList() : new List<Dictionary<string, object>>();

    var result = new Dictionary<string, object>
    {
        ["file"] = fileName,
        ["playedAt"] = playedAt,
        ["mode"] = Humanize(playlistRaw),
        ["playlistRaw"] = playlistRaw,
        ["me"] = me,
        ["myTeam"] = myTeam,
        ["placement"] = teamPosition,
        ["totalPlayers"] = totalPlayers,
        ["myEliminations"] = myElims,
        ["lengthMs"] = lengthMs,
        ["teammates"] = teammates,
        ["players"] = players,
        ["teams"] = teams,
        ["playerCount"] = players.Count,
        ["killFeed"] = killFeed,
        ["safeZonesStartTime"] = F(gd, "SafeZonesStartTime"),
        ["aircraftStartTime"] = F(gd, "AircraftStartTime"),
        ["map"] = new Dictionary<string, object>
        {
            ["safeZones"] = safeZones,
            ["worldGrid"] = worldGrid,
            ["bus"] = bus,
        },
    };
    Console.WriteLine(JsonSerializer.Serialize(result));
}
catch (Exception e)
{
    Console.Error.WriteLine("PARSE_ERROR: " + e.GetType().Name + ": " + e.Message);
    Console.WriteLine(JsonSerializer.Serialize(new { error = e.GetType().Name + ": " + e.Message }));
    Environment.Exit(2);
}
