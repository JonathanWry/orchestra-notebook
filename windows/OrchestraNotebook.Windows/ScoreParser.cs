using System.IO.Compression;
using System.Text.Json;
using System.Xml.Linq;

namespace OrchestraNotebook.WindowsHost;

internal static class ScoreParser
{
    private static bool Named(XElement element, string name) => element.Name.LocalName == name;
    private static string? FirstText(XContainer element, string name) =>
        element.Descendants().FirstOrDefault(node => Named(node, name))?.Value.Trim();

    public static object Parse(string path)
    {
        byte[] xml;
        byte[]? thumbnail = null;
        if (Path.GetExtension(path).Equals(".mscx", StringComparison.OrdinalIgnoreCase))
        {
            xml = File.ReadAllBytes(path);
        }
        else
        {
            using var archive = ZipFile.OpenRead(path);
            var scoreEntry = archive.Entries.FirstOrDefault(entry =>
                !entry.FullName.Contains('/') && Path.GetExtension(entry.Name).Equals(".mscx", StringComparison.OrdinalIgnoreCase));
            scoreEntry ??= archive.Entries.FirstOrDefault(entry => Path.GetExtension(entry.Name).Equals(".mscx", StringComparison.OrdinalIgnoreCase));
            if (scoreEntry is null) throw new InvalidDataException("MSCZ 中没有找到主乐谱 XML。");
            using (var stream = scoreEntry.Open())
            using (var memory = new MemoryStream()) { stream.CopyTo(memory); xml = memory.ToArray(); }
            var thumbEntry = archive.Entries.FirstOrDefault(entry => entry.FullName.EndsWith("Thumbnails/thumbnail.png", StringComparison.OrdinalIgnoreCase));
            if (thumbEntry is not null)
            {
                using var stream = thumbEntry.Open();
                using var memory = new MemoryStream();
                stream.CopyTo(memory); thumbnail = memory.ToArray();
            }
        }

        using var xmlStream = new MemoryStream(xml);
        var document = XDocument.Load(xmlStream, LoadOptions.None);
        var score = document.Descendants().FirstOrDefault(element => Named(element, "Score"))
                    ?? throw new InvalidDataException("没有找到 MuseScore 的 Score 节点。");
        var parts = new List<PartInfo>();
        var staffToPart = new Dictionary<string, PartInfo>();

        foreach (var partElement in score.Elements().Where(element => Named(element, "Part")))
        {
            var staffIds = partElement.Elements().Where(element => Named(element, "Staff"))
                .Select(element => element.Attribute("id")?.Value).Where(value => !string.IsNullOrWhiteSpace(value)).Cast<string>().ToList();
            var name = FirstText(partElement, "longName") ?? FirstText(partElement, "trackName")
                       ?? FirstText(partElement, "shortName") ?? "未命名乐器";
            var instrument = partElement.Descendants().FirstOrDefault(element => Named(element, "Instrument"));
            var instrumentId = FirstText(partElement, "instrumentId") ?? instrument?.Attribute("id")?.Value ?? "";
            var part = new PartInfo
            {
                Id = partElement.Attribute("id")?.Value ?? $"part-{parts.Count + 1}",
                Name = name,
                TrackName = FirstText(partElement, "trackName") ?? "",
                LongName = FirstText(partElement, "longName") ?? "",
                ShortName = FirstText(partElement, "shortName") ?? "",
                InstrumentId = instrumentId,
                Group = InstrumentGroup(instrumentId, name)
            };
            parts.Add(part);
            foreach (var staffId in staffIds) staffToPart[staffId] = part;
        }

        var scoreStaves = score.Elements().Where(element => Named(element, "Staff")).ToList();
        var markers = new List<object>();
        var measureCount = 0;
        var pageCount = 1;
        for (var staffIndex = 0; staffIndex < scoreStaves.Count; staffIndex++)
        {
            var staff = scoreStaves[staffIndex];
            var staffId = staff.Attribute("id")?.Value ?? "";
            staffToPart.TryGetValue(staffId, out var part);
            var measure = 0;
            foreach (var measureElement in staff.Elements().Where(element => Named(element, "Measure")))
            {
                measure++;
                measureCount = Math.Max(measureCount, measure);
                var notes = measureElement.Descendants().Count(element => Named(element, "Note"));
                var chords = measureElement.Descendants().Count(element => Named(element, "Chord"));
                var pitches = measureElement.Descendants().Where(element => Named(element, "pitch"))
                    .Select(element => int.TryParse(element.Value, out var pitch) ? pitch : -1).Where(pitch => pitch >= 0).ToList();
                var dynamic = measureElement.Descendants().Where(element => Named(element, "Dynamic"))
                    .Select(element => FirstText(element, "subtype")).FirstOrDefault(value => !string.IsNullOrWhiteSpace(value)) ?? "";
                if (part is not null && (notes > 0 || chords > 0 || dynamic.Length > 0))
                    part.AddActivity(measure, notes, chords, pitches, dynamic);

                if (staffIndex != 0) continue;
                foreach (var rehearsal in measureElement.Descendants().Where(element => Named(element, "RehearsalMark")))
                {
                    var text = FirstText(rehearsal, "text");
                    if (!string.IsNullOrWhiteSpace(text)) markers.Add(new { measure, text, type = "rehearsal" });
                }
                foreach (var tempo in measureElement.Descendants().Where(element => Named(element, "Tempo")))
                {
                    if (double.TryParse(FirstText(tempo, "tempo"), System.Globalization.NumberStyles.Float,
                            System.Globalization.CultureInfo.InvariantCulture, out var beats))
                        markers.Add(new { measure, text = $"♩ = {Math.Round(beats * 60)}", type = "tempo" });
                }
                foreach (var layoutBreak in measureElement.Descendants().Where(element => Named(element, "LayoutBreak")))
                {
                    if (string.Equals(FirstText(layoutBreak, "subtype"), "page", StringComparison.OrdinalIgnoreCase))
                    {
                        pageCount++;
                        markers.Add(new { measure, text = $"第 {pageCount} 页起", type = "page" });
                    }
                }
            }
        }

        var metadata = score.Descendants().Where(element => Named(element, "metaTag"))
            .GroupBy(element => element.Attribute("name")?.Value ?? "")
            .ToDictionary(group => group.Key, group => group.First().Value.Trim());
        var fallback = Path.GetFileNameWithoutExtension(path);
        var result = new Dictionary<string, object?>
        {
            ["id"] = path,
            ["path"] = path,
            ["title"] = metadata.GetValueOrDefault("workTitle") is { Length: > 0 } title ? title : fallback,
            ["composer"] = metadata.GetValueOrDefault("composer") ?? "",
            ["subtitle"] = metadata.GetValueOrDefault("subtitle") ?? "",
            ["measureCount"] = measureCount,
            ["pageCount"] = Math.Max(1, pageCount),
            ["parts"] = parts.Select(part => part.ToPayload()).ToList(),
            ["markers"] = markers
        };
        if (thumbnail is { Length: > 0 }) result["thumbnail"] = "data:image/png;base64," + Convert.ToBase64String(thumbnail);
        return result;
    }

    private static string InstrumentGroup(string id, string name)
    {
        var value = $"{id} {name}".ToLowerInvariant();
        var groups = new (string Group, string[] Terms)[]
        {
            ("木管", new[] { "flute", "piccolo", "oboe", "clarinet", "bassoon", "saxophone", "recorder", "wind." }),
            ("铜管", new[] { "trumpet", "horn", "trombone", "tuba", "euphonium", "cornet", "brass" }),
            ("打击乐", new[] { "percussion", "drum", "cymbal", "timpani", "marimba", "xylophone", "glock", "bells", "tambourine" }),
            ("弦乐", new[] { "violin", "viola", "cello", "contrabass", "double-bass", "strings" }),
            ("键盘 / 竖琴", new[] { "piano", "keyboard", "harp", "organ", "celesta" }),
            ("人声", new[] { "voice", "vocal", "choir", "soprano", "alto", "tenor", "baritone" })
        };
        return groups.FirstOrDefault(group => group.Terms.Any(value.Contains)).Group ?? "其他";
    }

    private sealed class PartInfo
    {
        public required string Id { get; init; }
        public required string Name { get; init; }
        public required string TrackName { get; init; }
        public required string LongName { get; init; }
        public required string ShortName { get; init; }
        public required string InstrumentId { get; init; }
        public required string Group { get; init; }
        private readonly Dictionary<int, Activity> _activities = new();

        public void AddActivity(int measure, int notes, int chords, List<int> pitches, string dynamic)
        {
            if (!_activities.TryGetValue(measure, out var activity)) _activities[measure] = activity = new Activity { Measure = measure };
            activity.Notes += notes; activity.Chords += chords;
            if (pitches.Count > 0)
            {
                activity.MinPitch = Math.Min(activity.MinPitch ?? int.MaxValue, pitches.Min());
                activity.MaxPitch = Math.Max(activity.MaxPitch ?? int.MinValue, pitches.Max());
            }
            if (dynamic.Length > 0) activity.Dynamic = dynamic;
        }

        public object ToPayload()
        {
            var maxNotes = Math.Max(1, _activities.Values.Select(activity => activity.Notes).DefaultIfEmpty(1).Max());
            var activities = _activities.Values.OrderBy(activity => activity.Measure).Select(activity => new Dictionary<string, object?>
            {
                ["measure"] = activity.Measure, ["chords"] = activity.Chords, ["notes"] = activity.Notes,
                ["minPitch"] = activity.MinPitch, ["maxPitch"] = activity.MaxPitch, ["dynamic"] = activity.Dynamic,
                ["density"] = Math.Min(1.0, 0.18 + 0.82 * activity.Notes / maxNotes)
            }).ToList();
            return new { id = Id, name = Name, trackName = TrackName, longName = LongName, shortName = ShortName, instrumentId = InstrumentId, group = Group, activities };
        }
    }

    private sealed class Activity
    {
        public int Measure { get; init; }
        public int Notes { get; set; }
        public int Chords { get; set; }
        public int? MinPitch { get; set; }
        public int? MaxPitch { get; set; }
        public string Dynamic { get; set; } = "";
    }
}
