using System.Globalization;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Client.App;
using Client.Peer;
using log4net.Config;
using Map.Controller;
using Map.Model;

namespace EarthquakeSignageBridge;

internal static class Program
{
    private static readonly object StateLock = new();
    private static readonly object EventLogLock = new();
    private static readonly object MapRenderLock = new();
    private static readonly object MapTaskLock = new();
    private static readonly object DisasterAudioLock = new();
    private const string FallbackDisasterMapImage = "earthquake/Map/Resources/Maps/japan-gsi_2048-8bit.png";
    private static readonly HttpClient LocalControlClient = new()
    {
        Timeout = TimeSpan.FromSeconds(2),
    };
    private static readonly HttpClient P2pApiClient = new()
    {
        Timeout = TimeSpan.FromSeconds(5),
    };
    private static readonly JsonSerializerOptions P2pApiJsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };
    private static readonly object P2pApiFallbackLock = new();
    private static readonly HashSet<string> ProcessedP2pApiIds = new(StringComparer.Ordinal);
    private static readonly List<Task> PendingMapTasks = new();
    private static readonly IReadOnlyDictionary<string, int> PrefectureOrder = new[]
    {
        "北海道", "青森県", "岩手県", "宮城県", "秋田県", "山形県", "福島県",
        "茨城県", "栃木県", "群馬県", "埼玉県", "千葉県", "東京都", "神奈川県",
        "新潟県", "富山県", "石川県", "福井県", "山梨県", "長野県", "岐阜県",
        "静岡県", "愛知県", "三重県", "滋賀県", "京都府", "大阪府", "兵庫県",
        "奈良県", "和歌山県", "鳥取県", "島根県", "岡山県", "広島県", "山口県",
        "徳島県", "香川県", "愛媛県", "高知県", "福岡県", "佐賀県", "長崎県",
        "熊本県", "大分県", "宮崎県", "鹿児島県", "沖縄県",
    }.Select((name, index) => new { name, index })
        .ToDictionary(item => item.name, item => item.index);
    private static readonly EewRegionDefinition[] EewRegions =
    {
        new("北海道", "hokkaido.mp3", new[] { 160, 161, 162, 163 }),
        new("東北", "touhoku.mp3", new[] { 164, 165, 166, 167, 168, 169 }),
        new("関東", "kantou.mp3", new[] { 170, 171, 172, 173, 174, 175, 178 }),
        new("北陸", "hokuriku.mp3", new[] { 179, 180, 181, 182 }),
        new("甲信", "koushin.mp3", new[] { 183, 184 }),
        new("東海", "toukai.mp3", new[] { 185, 186, 187, 188 }),
        new("近畿", "kinki.mp3", new[] { 189, 190, 191, 192, 193, 194 }),
        new("中国", "tyuugoku.mp3", new[] { 195, 196, 197, 198, 363 }),
        new("四国", "shikoku.mp3", new[] { 199, 360, 361, 362 }),
        new("九州", "kyusyu.mp3", new[] { 364, 365, 366, 367, 368, 369, 370 }),
        new("沖縄", "okinawa.mp3", new[] { 372, 373, 374, 375 }),
    };
    private static readonly string[] DesignatedCityPrefixes =
    {
        "札幌", "仙台", "さいたま", "千葉", "横浜", "川崎", "相模原", "新潟",
        "静岡", "浜松", "名古屋", "京都", "大阪", "神戸", "岡山", "広島",
        "北九州", "福岡", "熊本",
    };
    private static readonly IReadOnlyDictionary<string, string[]> IslandNamesByMunicipality =
        new Dictionary<string, string[]>(StringComparer.Ordinal)
        {
            ["三島村"] = new[] { "硫黄島", "竹島", "黒島" },
            ["十島村"] = new[] { "諏訪之瀬島", "中之島", "口之島", "悪石島", "小宝島", "平島", "宝島" },
            ["新島村"] = new[] { "式根島", "新島" },
            ["小笠原村"] = new[] { "父島", "母島" },
            ["竹富町"] = new[] { "西表島", "波照間島", "竹富島", "小浜島", "鳩間島", "新城島", "黒島" },
        };
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };
    private static readonly JsonSerializerOptions JsonLineOptions = new()
    {
        WriteIndented = false,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private static string outputPath = "";
    private static string projectDirectory = "";
    private static string eventLogPath = "";
    private static string informationLogPath = "";
    private static string testCommandPath = "";
    private static string lastTestCommandId = "";
    private static EewView? eew;
    private static readonly List<EewView> eews = new();
    private static QuakeView? earthquake;
    private static readonly List<QuakeView> earthquakes = new();
    private static TsunamiView tsunami = TsunamiView.Inactive;
    private static DateTime? eewExpiresAt;
    private static DateTime? earthquakeExpiresAt;
    private static DateTime? earthquakePriorityUntil;
    private static DateTime? tsunamiPriorityUntil;
    private static string lastJson = "";
    private static bool executingTestCommand;
    private static string? testEewHypocenterName;
    private static DateTime? testEewOccurredAt;
    private static Process? activeDisasterAudioProcess;

    private static int Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        BasicConfigurator.Configure();

        projectDirectory = ResolveProjectDirectory(args);
        string tempDirectory = Path.Combine(projectDirectory, "temp");
        string logDirectory = Path.Combine(projectDirectory, "logs");
        Directory.CreateDirectory(tempDirectory);
        Directory.CreateDirectory(logDirectory);
        outputPath = Path.Combine(tempDirectory, "earthquake_data.js");
        eventLogPath = Path.Combine(logDirectory, "earthquake_bridge_events.log");
        informationLogPath = Path.Combine(logDirectory, "earthquake_information.jsonl");
        testCommandPath = Path.Combine(tempDirectory, "earthquake_test_command.json");
        LoadExistingState();

        var mediator = new MediatorContext
        {
            Verification = true,
            AreaCode = 900,
            IsPortOpen = false,
            UseUPnP = false,
            MaxConnections = 8,
        };

        mediator.OnEEW += HandleEew;
        mediator.OnEarthquake += HandleEarthquake;
        mediator.OnTsunami += HandleTsunami;
        mediator.StateChanged += (_, _) =>
        {
            string message = $"P2P状態: {mediator.ReadonlyState}";
            Console.WriteLine($"{DateTime.Now:HH:mm:ss.fff} {message}");
            WriteEventLog(message);
        };

        WriteState(force: true);
        // 管理画面のテストはP2Pネットワークの接続可否に依存させない。
        // 起動前から残っている命令も、実際の受信と同じイベント経路で直ちに処理する。
        RunRequestedTest(args, mediator);
        ProcessTestCommand(mediator);
        if (args.Contains("--exit-after-test", StringComparer.OrdinalIgnoreCase))
        {
            // 地図生成が完了して画面データへ反映されるまで、試験プロセスを維持する。
            WaitForPendingMapRenders(TimeSpan.FromSeconds(30));
            WriteEventLog("P2P内蔵テストのワンショット実行を完了しました。");
            return 0;
        }

        if (!mediator.Connect())
        {
            WriteEventLog("P2Pネットワークへの接続開始に失敗しました。");
            Console.Error.WriteLine("P2Pネットワークへの接続開始に失敗しました。");
        }

        // ピア接続が生きたまま受信不能になる場合に備え、公式APIでも直近情報を照合する。
        StartP2pApiFallback();

        Console.WriteLine($"{DateTime.Now:HH:mm:ss.fff} P2P地震情報の常時受信を開始しました。");
        WriteEventLog("P2P地震情報の常時受信を開始しました。");
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(200));
        while (timer.WaitForNextTickAsync().AsTask().GetAwaiter().GetResult())
        {
            ProcessTestCommand(mediator);
            ExpireOldInformation();
        }

        return 0;
    }

    private static void StartP2pApiFallback()
    {
        _ = Task.Run(async () =>
        {
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(3));
            do
            {
                await PollP2pApiEarthquakes();
            }
            while (await timer.WaitForNextTickAsync());
        });
    }

    private static async Task PollP2pApiEarthquakes()
    {
        try
        {
            const string url = "https://api.p2pquake.net/v2/history?codes=551&limit=20";
            string json = await P2pApiClient.GetStringAsync(url);
            P2pApiEarthquake[] items =
                JsonSerializer.Deserialize<P2pApiEarthquake[]>(json, P2pApiJsonOptions) ??
                Array.Empty<P2pApiEarthquake>();

            foreach (P2pApiEarthquake item in items.Reverse())
            {
                ProcessP2pApiEarthquake(item);
            }
        }
        catch (Exception exception)
        {
            WriteEventLog($"P2P公式APIの地震情報照合に失敗しました: {exception.Message}");
        }
    }

    private static void ProcessP2pApiEarthquake(P2pApiEarthquake item)
    {
        if (string.IsNullOrWhiteSpace(item.Id) || item.Earthquake is null || item.Issue is null)
        {
            return;
        }

        if (!TryParseP2pApiDateTime(item.Issue.Time, out DateTime issueTime))
        {
            return;
        }

        DateTime now = DateTime.Now;
        // 震度3・4は受信後1時間が表示対象なので、再起動後も同じ範囲を復旧する。
        if (issueTime < now.AddHours(-1) || issueTime > now.AddMinutes(2))
        {
            return;
        }

        lock (P2pApiFallbackLock)
        {
            if (!ProcessedP2pApiIds.Add(item.Id))
            {
                return;
            }
        }

        EPSPQuakeEventArgs converted = ConvertP2pApiEarthquake(item, issueTime);
        if (GetMaximumScale(converted) < 30 || IsEarthquakeAlreadyStored(converted, issueTime))
        {
            return;
        }

        WriteEventLog($"P2P公式APIから未受信の地震情報を補完しました: id={item.Id}, 種類={item.Issue.Type}");
        HandleEarthquake(null, converted);
    }

    private static bool IsEarthquakeAlreadyStored(EPSPQuakeEventArgs value, DateTime receivedAt)
    {
        QuakeView candidate = ConvertEarthquake(value, GetMaximumScale(value), receivedAt);
        lock (StateLock)
        {
            return earthquakes.Any(item =>
                (item.EventId == candidate.EventId &&
                    item.InformationType == candidate.InformationType) ||
                (IsEquivalentEarthquakeReport(item, candidate) &&
                    !IsPreferredEarthquakeReport(candidate, item)));
        }
    }

    private static EPSPQuakeEventArgs ConvertP2pApiEarthquake(P2pApiEarthquake item, DateTime issueTime)
    {
        P2pApiHypocenter hypocenter = item.Earthquake?.Hypocenter ?? new P2pApiHypocenter();
        QuakeObservationPoint[] points = (item.Points ?? Array.Empty<P2pApiPoint>())
            .Select(point => new QuakeObservationPoint
            {
                Prefecture = point.Pref ?? "",
                Name = point.Addr ?? "",
                Scale = ConvertScaleText(point.Scale),
            })
            .ToArray();

        return new EPSPQuakeEventArgs
        {
            ReceivedAt = issueTime,
            IsInvalidSignature = false,
            IsExpired = false,
            OccuredTime = item.Earthquake?.Time ?? item.Issue?.Time ?? "",
            Scale = ConvertScaleText(item.Earthquake?.MaxScale ?? 0),
            TsunamiType = ConvertP2pApiTsunamiType(item.Earthquake?.DomesticTsunami),
            InformationType = ConvertP2pApiInformationType(item.Issue?.Type),
            Destination = hypocenter.Name ?? "調査中",
            Depth = hypocenter.Depth.HasValue
                ? hypocenter.Depth.Value.ToString(CultureInfo.InvariantCulture)
                : "不明",
            Magnitude = hypocenter.Magnitude.HasValue
                ? hypocenter.Magnitude.Value.ToString("0.0", CultureInfo.InvariantCulture)
                : "不明",
            Latitude = hypocenter.Latitude?.ToString(CultureInfo.InvariantCulture) ?? "不明",
            Longitude = hypocenter.Longitude?.ToString(CultureInfo.InvariantCulture) ?? "不明",
            IssueFrom = item.Issue?.Source ?? "気象庁",
            PointList = points,
            FreeCommentList = Array.Empty<string>(),
        };
    }

    private static bool TryParseP2pApiDateTime(string? value, out DateTime parsed)
    {
        return DateTime.TryParseExact(
            value,
            new[] { "yyyy/MM/dd HH:mm:ss.FFF", "yyyy/MM/dd HH:mm:ss" },
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeLocal,
            out parsed);
    }

    private static QuakeInformationType ConvertP2pApiInformationType(string? value)
    {
        return value switch
        {
            "ScalePrompt" => QuakeInformationType.ScalePrompt,
            "Destination" => QuakeInformationType.Destination,
            "ScaleAndDestination" => QuakeInformationType.ScaleAndDestination,
            "DetailScale" => QuakeInformationType.Detail,
            "Foreign" => QuakeInformationType.Foreign,
            _ => QuakeInformationType.Unknown,
        };
    }

    private static DomesticTsunamiType ConvertP2pApiTsunamiType(string? value)
    {
        return value switch
        {
            "None" => DomesticTsunamiType.None,
            "Checking" => DomesticTsunamiType.Checking,
            "Unknown" => DomesticTsunamiType.Unknown,
            _ => DomesticTsunamiType.Effective,
        };
    }

    private static void RunRequestedTest(string[] args, MediatorContext mediator)
    {
        if (args.Contains("--test-eew", StringComparer.OrdinalIgnoreCase))
        {
            mediator.TestEEW();
        }
        if (args.Contains("--test-quake", StringComparer.OrdinalIgnoreCase))
        {
            mediator.TestEarthquake("5弱");
        }
        if (args.Contains("--test-quake-3-plus", StringComparer.OrdinalIgnoreCase))
        {
            mediator.TestEarthquake("3以上");
        }
        if (args.Contains("--test-tsunami", StringComparer.OrdinalIgnoreCase))
        {
            mediator.TestTsunami();
        }
        if (args.Contains("--clear-test", StringComparer.OrdinalIgnoreCase))
        {
            ClearTestInformation();
        }
    }

    private static void ProcessTestCommand(MediatorContext mediator)
    {
        if (!File.Exists(testCommandPath))
        {
            return;
        }

        try
        {
            string json = File.ReadAllText(testCommandPath, Encoding.UTF8);
            TestCommand? command = JsonSerializer.Deserialize<TestCommand>(json, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true,
            });
            if (command is null || string.IsNullOrWhiteSpace(command.Id) || command.Id == lastTestCommandId)
            {
                return;
            }

            WriteEventLog($"管理画面の災害テスト命令を受信しました: id={command.Id}, kind={command.Kind}");
            lastTestCommandId = command.Id;
            ExecuteTestCommand(command, mediator);
            File.Delete(testCommandPath);
        }
        catch (IOException)
        {
            // 管理画面による一時ファイル更新中は次の200ms周期で再試行する。
        }
        catch (Exception exception)
        {
            WriteEventLog($"管理画面の災害テスト命令を処理できませんでした: {exception.Message}");
        }
    }

    private static void ExecuteTestCommand(TestCommand command, MediatorContext mediator)
    {
        executingTestCommand = true;
        try
        {
            switch (command.Kind.ToLowerInvariant())
            {
                case "eew":
                    ExecuteEewTest(command);
                    break;
                case "earthquake":
                    ExecuteEarthquakeTest(command);
                    break;
                case "tsunami":
                    ExecuteTsunamiTest(command);
                    break;
                case "clear":
                    ClearTestInformation();
                    break;
                default:
                    throw new InvalidOperationException($"未対応の災害テストです: {command.Kind}");
            }
        }
        finally
        {
            executingTestCommand = false;
        }

        WriteEventLog($"管理画面から災害テストを実行しました: {command.Kind}");
    }

    private static void ExecuteEewTest(TestCommand command)
    {
        string eewType = string.IsNullOrWhiteSpace(command.EewType)
            ? "announcement"
            : command.EewType.ToLowerInvariant();
        bool isFollowUp = eewType == "follow-up";
        bool isCancelled = eewType == "cancel";
        int[] areaCodes = command.EewAreas
            .Select(value => int.TryParse(value, out int code) ? code : EEWConverter.GetAreaCode(value))
            .Where(code => code > 0)
            .Distinct()
            .ToArray();

        int hypocenterCode = EEWConverter.GetHypocenterCode(command.Hypocenter);
        if (hypocenterCode < 0)
        {
            // The P2P packet requires a code, while an administration test may
            // intentionally use a scenario name not present in the code table.
            hypocenterCode = 871;
        }

        testEewHypocenterName = command.Hypocenter;
        testEewOccurredAt = ParseTestOccurredAt(command.OccurredAt);
        try
        {
            HandleEew(null, new EPSPEEWEventArgs
            {
                IsTest = true,
                IsExpired = false,
                IsInvalidSignature = false,
                IsFollowUp = isFollowUp,
                IsCancelled = isCancelled,
                ReceivedAt = DateTime.Now,
                Hypocenter = hypocenterCode,
                Areas = areaCodes,
            });
        }
        finally
        {
            testEewHypocenterName = null;
            testEewOccurredAt = null;
        }
    }

    private static void ExecuteEarthquakeTest(TestCommand command)
    {
        QuakeInformationType informationType = command.EarthquakeType switch
        {
            "scale-prompt" => QuakeInformationType.ScalePrompt,
            "hypocenter" => QuakeInformationType.Destination,
            _ => QuakeInformationType.Detail,
        };
        TestQuakePoint[] requestedPoints = GetTestQuakePoints(command, informationType);
        QuakeObservationPoint[] points = requestedPoints
            .Where(point => !string.IsNullOrWhiteSpace(point.Name))
            .Select(point => new QuakeObservationPoint
            {
                Prefecture = string.IsNullOrWhiteSpace(point.Pref) ? "その他" : point.Pref,
                Name = point.Name,
                Scale = string.IsNullOrWhiteSpace(point.Scale) ? "3" : point.Scale,
            })
            .ToArray();
        string maximumScale = points
            .OrderByDescending(point => ConvertScale(point.Scale))
            .Select(point => point.Scale)
            .FirstOrDefault() ?? "3";
        QuakeObservationPoint[] informationPoints = informationType == QuakeInformationType.Destination
            ? Array.Empty<QuakeObservationPoint>()
            : points;

        DateTime occurredAt = ParseTestOccurredAt(command.OccurredAt) ?? DateTime.Now;
        HandleEarthquake(null, new EPSPQuakeEventArgs
        {
            Depth = $"{ParsePositiveNumber(command.Depth, "10")}km",
            Destination = string.IsNullOrWhiteSpace(command.Hypocenter) ? "調査中" : command.Hypocenter,
            InformationType = informationType,
            IsCorrection = false,
            IsExpired = false,
            IsInvalidSignature = false,
            IssueFrom = "管理画面試験",
            Latitude = NormalizeTestCoordinate(command.HypocenterLatitude),
            Longitude = NormalizeTestCoordinate(command.HypocenterLongitude),
            Magnitude = ParsePositiveNumber(command.Magnitude, "5.0"),
            OccuredTime = occurredAt.ToString("dd日HH時mm分"),
            PointList = informationPoints,
            ReceivedAt = DateTime.Now,
            Scale = maximumScale,
            TsunamiType = ConvertTestTsunamiType(command.TsunamiType),
        });
    }

    private static TestQuakePoint[] GetTestQuakePoints(
        TestCommand command,
        QuakeInformationType informationType)
    {
        if (informationType == QuakeInformationType.ScalePrompt && command.EarthquakeAreas.Length > 0)
        {
            return command.EarthquakeAreas;
        }
        if (command.EarthquakePoints.Length > 0)
        {
            return command.EarthquakePoints;
        }
        return Array.Empty<TestQuakePoint>();
    }

    private static string ParsePositiveNumber(string value, string fallback)
    {
        return double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out double parsed) && parsed >= 0
            ? parsed.ToString("0.0#", CultureInfo.InvariantCulture)
            : fallback;
    }

    private static DateTime? ParseTestOccurredAt(string value)
    {
        return DateTime.TryParse(
            value,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeLocal,
            out DateTime parsed)
            ? parsed
            : null;
    }

    private static string NormalizeTestCoordinate(string value)
    {
        return double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out double parsed)
            ? parsed.ToString("0.####", CultureInfo.InvariantCulture)
            : "";
    }

    private static DomesticTsunamiType ConvertTestTsunamiType(string value)
    {
        return value switch
        {
            "調査中" => DomesticTsunamiType.Checking,
            "津波あり" => DomesticTsunamiType.Effective,
            "津波警報等発表中" => DomesticTsunamiType.Effective,
            _ => DomesticTsunamiType.None,
        };
    }

    private static void ExecuteTsunamiTest(TestCommand command)
    {
        TsunamiForecastRegion[] regions = command.TsunamiAreas
            .Where(area => !string.IsNullOrWhiteSpace(area.Name))
            .Select(area => new TsunamiForecastRegion
            {
                Region = area.Name,
                Category = area.Grade switch
                {
                    "大津波警報" => Client.Peer.TsunamiCategory.MajorWarning,
                    "津波警報" => Client.Peer.TsunamiCategory.Warning,
                    _ => Client.Peer.TsunamiCategory.Advisory,
                },
                IsImmediately = area.Immediate,
            })
            .ToArray();

        HandleTsunami(null, new EPSPTsunamiEventArgs
        {
            IsCancelled = false,
            IsExpired = false,
            IsInvalidSignature = false,
            ReceivedAt = DateTime.Now,
            RegionList = regions,
        });
    }

    private static void ClearTestInformation()
    {
        lock (StateLock)
        {
            eew = null;
            eews.Clear();
            earthquake = null;
            earthquakes.Clear();
            tsunami = TsunamiView.Inactive;
            eewExpiresAt = null;
            earthquakeExpiresAt = null;
            earthquakePriorityUntil = null;
            tsunamiPriorityUntil = null;
            WriteStateLocked(force: true);
        }
    }

    private static string ResolveProjectDirectory(string[] args)
    {
        if (args.Length > 0 && Directory.Exists(args[0]))
        {
            return Path.GetFullPath(args[0]);
        }

        string executableDirectory = AppContext.BaseDirectory;
        return Path.GetFullPath(Path.Combine(executableDirectory, "..", "..", "..", ".."));
    }

    private static void LoadExistingState()
    {
        if (!File.Exists(outputPath))
        {
            return;
        }

        try
        {
            string source = File.ReadAllText(outputPath, Encoding.UTF8);
            int assignmentIndex = source.IndexOf('=');
            if (assignmentIndex < 0)
            {
                return;
            }

            string json = source[(assignmentIndex + 1)..].Trim().TrimEnd(';');
            var options = new JsonSerializerOptions(JsonOptions)
            {
                PropertyNameCaseInsensitive = true,
            };
            StoredState? stored = JsonSerializer.Deserialize<StoredState>(json, options);
            RestoreStoredState(stored);
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"以前の地震情報を復元できませんでした: {exception.Message}");
        }
    }

    private static void RestoreStoredState(StoredState? stored)
    {
        if (stored is null)
        {
            return;
        }

        DateTime now = DateTime.Now;
        EewView[] storedEews = stored.Eews?.Length > 0
            ? stored.Eews
            : stored.Eew is null
                ? Array.Empty<EewView>()
                : new[] { stored.Eew };
        foreach (EewView storedEew in storedEews)
        {
            if (!TryParseDateTime(storedEew.IssueTime, out DateTime eewTime)) continue;
            DateTime expiresAt = eewTime.AddMinutes(3);
            if (now > expiresAt) continue;
            eews.Add(storedEew);
        }
        eew = eews
            .OrderByDescending(item => ParseDateTimeOrMinimum(item.IssueTime))
            .FirstOrDefault();
        if (eew is not null)
        {
            eewExpiresAt = ParseDateTimeOrMinimum(eew.IssueTime).AddMinutes(3);
        }

        QuakeView[] storedEarthquakes = stored.Earthquakes?.Length > 0
            ? stored.Earthquakes
            : stored.Earthquake is null
                ? Array.Empty<QuakeView>()
                : new[] { stored.Earthquake };
        foreach (QuakeView storedQuake in storedEarthquakes)
        {
            if (!TryParseDateTime(storedQuake.IssueTime, out DateTime quakeTime)) continue;
            if (now > GetEarthquakeExpiry(quakeTime, storedQuake.MaxScale)) continue;
            earthquakes.Add(storedQuake);
        }
        RemoveStoredEarthquakeDuplicates();
        earthquake = earthquakes
            .OrderByDescending(item => ParseDateTimeOrMinimum(item.IssueTime))
            .FirstOrDefault();
        if (earthquake is not null)
        {
            DateTime quakeTime = ParseDateTimeOrMinimum(earthquake.IssueTime);
            earthquakeExpiresAt = GetEarthquakeExpiry(quakeTime, earthquake.MaxScale);
            earthquakePriorityUntil = GetEarthquakePriorityUntil(quakeTime, earthquake.MaxScale);
        }

        if (stored.Tsunami?.Active == true && TryParseDateTime(stored.Tsunami.IssueTime, out DateTime tsunamiTime))
        {
            tsunami = stored.Tsunami;
            tsunamiPriorityUntil = tsunamiTime.AddMinutes(30);
        }
    }

    private static void RemoveStoredEarthquakeDuplicates()
    {
        QuakeView[] preferredOrder = earthquakes
            .OrderBy(GetOccurrenceIssueDistance)
            .ThenByDescending(item => ParseDateTimeOrMinimum(item.IssueTime))
            .ToArray();
        var unique = new List<QuakeView>();
        foreach (QuakeView candidate in preferredOrder)
        {
            if (unique.Any(item => IsEquivalentEarthquakeReport(item, candidate)))
            {
                continue;
            }
            unique.Add(candidate);
        }

        if (unique.Count == earthquakes.Count)
        {
            return;
        }

        int removedCount = earthquakes.Count - unique.Count;
        earthquakes.Clear();
        earthquakes.AddRange(unique);
        WriteEventLog($"保存済み地震情報から重複データを{removedCount}件除外しました。");
    }

    private static void HandleEew(object? sender, EPSPEEWEventArgs value)
    {
        DateTime systemReceivedAt = DateTime.Now;
        DateTime receivedAt = NormalizeReceivedAt(value.ReceivedAt);
        DateTime? occurrenceTime = executingTestCommand ? testEewOccurredAt : null;
        int[] rawAreaCodes = (value.Areas ?? Array.Empty<int>())
            .Where(code => code > 0)
            .Distinct()
            .ToArray();
        EewAnnouncement[] announcements = CreateEewAnnouncements(rawAreaCodes);
        bool useGenericVoice = rawAreaCodes.Length == 0 ||
            rawAreaCodes.Any(code => EEWConverter.GetArea(code) is null);
        EewView receivedEew;
        lock (StateLock)
        {
            string eventId = ResolveEewEventId(value, occurrenceTime, receivedAt);
            receivedEew = new EewView
            {
                Id = $"p2p-eew-{receivedAt:yyyyMMddHHmmssfff}",
                EventId = eventId,
                Serial = value.IsFollowUp ? 2 : 1,
                IsFollowUp = value.IsFollowUp,
                Cancelled = value.IsCancelled,
                IssueTime = FormatDateTime(receivedAt),
                OriginTime = occurrenceTime.HasValue ? FormatDateTime(occurrenceTime.Value) : null,
                ArrivalTime = null,
                Hypocenter = executingTestCommand && !string.IsNullOrWhiteSpace(testEewHypocenterName)
                    ? testEewHypocenterName
                    : EEWConverter.GetHypocenter(value.Hypocenter) ?? "調査中",
                Magnitude = null,
                Depth = null,
                Areas = rawAreaCodes
                    .Select(CreateEewArea)
                    .ToArray(),
                DisplayAreas = announcements
                    .Select(CreateEewDisplayArea)
                    .ToArray(),
            };
            eews.RemoveAll(item => item.EventId == eventId);
            eews.Add(receivedEew);
            eew = receivedEew;
            eewExpiresAt = receivedAt.AddMinutes(3);
            WriteStateLocked(force: true);
        }

        Console.WriteLine($"{DateTime.Now:HH:mm:ss.fff} 緊急地震速報を即時反映しました。");
        WriteEventLog($"緊急地震速報を即時反映: 震源={receivedEew.Hypocenter}, 取消={value.IsCancelled}");
        WriteDetailedInformationLog(
            "eew",
            receivedAt,
            systemReceivedAt,
            DateTime.Now,
            receivedEew
        );
        RequestEmergencyDisplayWake(3, "緊急地震速報");
        StartDisasterAudio(
            "Eew",
            value.IsFollowUp,
            value.IsCancelled,
            rawAreaCodes
                .Select(code => code.ToString(CultureInfo.InvariantCulture))
                .ToArray(),
            eewVoiceFiles: announcements.Select(item => item.AudioFile).ToArray(),
            genericEew: useGenericVoice
        );
        GenerateOrQueueEewMap(receivedEew.Id);
    }

    private static string ResolveEewEventId(
        EPSPEEWEventArgs value,
        DateTime? occurrenceTime,
        DateTime receivedAt)
    {
        if (occurrenceTime.HasValue)
        {
            return $"p2p-{occurrenceTime.Value:yyyyMMddHHmmss}";
        }
        if ((value.IsFollowUp || value.IsCancelled) && eew is not null)
        {
            return eew.EventId;
        }
        return $"p2p-{receivedAt:yyyyMMddHHmmss}";
    }

    private static EewAnnouncement[] CreateEewAnnouncements(int[] areaCodes)
    {
        var positions = areaCodes
            .Select((code, index) => new { code, index })
            .ToDictionary(item => item.code, item => item.index);
        var consumedCodes = new HashSet<int>();
        var announcements = new List<EewAnnouncement>();

        foreach (EewRegionDefinition region in EewRegions)
        {
            if (!region.AreaCodes.All(positions.ContainsKey))
            {
                continue;
            }

            announcements.Add(new EewAnnouncement(
                region.AreaCodes.Min(code => positions[code]),
                region.DisplayName,
                region.AudioFile
            ));
            consumedCodes.UnionWith(region.AreaCodes);
        }

        foreach (int code in areaCodes.Where(code => !consumedCodes.Contains(code)))
        {
            announcements.Add(new EewAnnouncement(
                positions[code],
                EEWConverter.GetArea(code) ?? $"地域コード {code}",
                $"{code}.mp3"
            ));
        }

        return announcements
            .OrderBy(item => GetEewAnnouncementPriority(item.DisplayName))
            .ThenBy(item => item.Order)
            .ToArray();
    }

    private static int GetEewAnnouncementPriority(string displayName)
    {
        if (displayName.Contains("近畿", StringComparison.Ordinal)) return 0;
        if (displayName.Contains("大阪", StringComparison.Ordinal)) return 1;
        return 2;
    }

    private static EewAreaView CreateEewDisplayArea(EewAnnouncement announcement)
    {
        return new EewAreaView
        {
            Name = announcement.DisplayName,
            Pref = announcement.DisplayName,
            ScaleFrom = 40,
            ScaleTo = 70,
            ScaleText = "4以上",
            ArrivalTime = null,
            KindCode = "",
        };
    }

    private static EewAreaView CreateEewArea(int code)
    {
        string name = EEWConverter.GetArea(code) ?? $"地域コード {code}";
        return new EewAreaView
        {
            Name = name,
            Pref = name,
            ScaleFrom = 40,
            ScaleTo = 70,
            ScaleText = "4以上",
            ArrivalTime = null,
            KindCode = code.ToString(CultureInfo.InvariantCulture),
        };
    }

    private static void HandleEarthquake(object? sender, EPSPQuakeEventArgs value)
    {
        DateTime systemReceivedAt = DateTime.Now;
        int maxScale = GetMaximumScale(value);
        int pointCount = value.PointList?.Count ?? 0;
        WriteEventLog(
            $"地震情報を受信: 種類={value.InformationType}, " +
            $"概要震度={value.Scale}, 判定震度={ConvertScaleText(maxScale)}, 観測点数={pointCount}"
        );
        if (maxScale < 30)
        {
            WriteEventLog("最大震度3未満のためサイネージ表示対象外としました。");
            EndEewWhenEarthquakeInformationArrives();
            return;
        }

        DateTime receivedAt = NormalizeReceivedAt(value.ReceivedAt);
        QuakeView converted = ConvertEarthquake(value, maxScale, receivedAt);
        lock (StateLock)
        {
            QuakeView? equivalent = earthquakes.FirstOrDefault(item =>
                IsEquivalentEarthquakeReport(item, converted));
            if (equivalent is not null && !IsPreferredEarthquakeReport(converted, equivalent))
            {
                WriteEventLog(
                    $"同一地震情報の重複受信を除外しました: " +
                    $"種類={converted.InformationType}, 震源={converted.Hypocenter}, 発生={converted.Time}"
                );
                return;
            }

            earthquakes.RemoveAll(item =>
                (item.EventId == converted.EventId &&
                    item.InformationType == converted.InformationType) ||
                IsEquivalentEarthquakeReport(item, converted));
            earthquakes.Add(converted);
            earthquake = converted;
            earthquakeExpiresAt = GetEarthquakeExpiry(receivedAt, maxScale);
            earthquakePriorityUntil = GetEarthquakePriorityUntil(receivedAt, maxScale);
            eew = null;
            eews.Clear();
            eewExpiresAt = null;
            WriteStateLocked(force: true);
        }

        Console.WriteLine($"{DateTime.Now:HH:mm:ss.fff} 震度{converted.MaxScaleText}の地震情報を即時反映しました。");
        WriteEventLog(
            $"震度{converted.MaxScaleText}の地震情報を即時反映: " +
            $"種類={value.InformationType}, 震源={converted.Hypocenter}"
        );
        WriteDetailedInformationLog(
            "earthquake",
            receivedAt,
            systemReceivedAt,
            DateTime.Now,
            converted
        );
        if (maxScale >= 45)
        {
            int wakeMinutes = maxScale >= 70 ? 30 : maxScale >= 55 ? 10 : 5;
            RequestEmergencyDisplayWake(wakeMinutes, $"震度{converted.MaxScaleText}の地震情報");
        }
        StartDisasterAudio("Earthquake", false, false, Array.Empty<string>(), maxScale);
        GenerateOrQueueEarthquakeMap(converted.Id);
    }

    private static int GetMaximumScale(EPSPQuakeEventArgs value)
    {
        int summaryScale = ConvertScale(value.Scale);
        int pointScale = (value.PointList ?? Array.Empty<QuakeObservationPoint>())
            .Select(point => ConvertScale(point.Scale))
            .DefaultIfEmpty(0)
            .Max();
        return Math.Max(summaryScale, pointScale);
    }

    private static void EndEewWhenEarthquakeInformationArrives()
    {
        lock (StateLock)
        {
            if (eew is null)
            {
                return;
            }

            eew = null;
            eews.Clear();
            eewExpiresAt = null;
            WriteStateLocked(force: true);
        }
    }

    private static QuakeView ConvertEarthquake(EPSPQuakeEventArgs value, int maxScale, DateTime receivedAt)
    {
        string occurrenceTime = NormalizeOccurrenceTime(value.OccuredTime, receivedAt);
        string eventId = CreateEarthquakeEventId(occurrenceTime);
        QuakePointView[] points = (value.PointList ?? Array.Empty<QuakeObservationPoint>())
            .Select(point => new
            {
                Point = point,
                Scale = ConvertScale(point.Scale),
                IsMissing = IsMissingScale(point.Scale),
                ScaleText = ConvertObservationScaleText(point.Scale),
                Municipality = NormalizeEarthquakeMunicipality(point.Prefecture, point.Name),
            })
            .Where(item => item.Scale >= 30 || item.IsMissing)
            .GroupBy(item => new { item.Point.Prefecture, item.Municipality })
            .Select(group => group
                .OrderByDescending(item => item.Scale)
                .ThenBy(item => item.IsMissing)
                .ThenBy(item => item.Point.Name)
                .First())
            .Select(item => new QuakePointView
            {
                Pref = item.Point.Prefecture,
                Addr = item.Municipality,
                ObservationAddr = item.Point.Name,
                Scale = item.Scale,
                ScaleText = item.ScaleText,
                IsMissing = item.IsMissing,
            })
            .OrderByDescending(GetEarthquakePointDisplayOrder)
            .ThenBy(point => GetPrefectureOrder(point.Pref))
            .ThenBy(point => point.Pref)
            .ThenBy(point => point.Addr)
            .ToArray();

        ScaleGroupView[] groups = points
            .GroupBy(point => new { point.Scale, point.ScaleText, point.IsMissing })
            .OrderByDescending(group => GetEarthquakePointDisplayOrder(group.First()))
            .Select(group => new ScaleGroupView
            {
                Scale = group.Key.Scale,
                ScaleText = group.Key.ScaleText,
                IsMissing = group.Key.IsMissing,
                Prefs = group.GroupBy(point => point.Pref)
                    .OrderBy(prefGroup => GetPrefectureOrder(prefGroup.Key))
                    .ThenBy(prefGroup => prefGroup.Key)
                    .Select(prefGroup => new PrefGroupView
                    {
                        Pref = string.IsNullOrWhiteSpace(prefGroup.Key) ? "その他" : prefGroup.Key,
                        Addrs = prefGroup.Select(point => point.Addr).Where(name => !string.IsNullOrWhiteSpace(name)).ToArray(),
                    })
                    .ToArray(),
            })
            .ToArray();

        int ikunoScale = points
            .Where(point => point.Addr.Contains("生野区", StringComparison.Ordinal))
            .Select(point => point.Scale)
            .DefaultIfEmpty(0)
            .Max();
        string ikunoScaleText = points
            .Where(point => point.Addr.Contains("生野区", StringComparison.Ordinal))
            .OrderByDescending(GetEarthquakePointDisplayOrder)
            .Select(point => point.ScaleText)
            .FirstOrDefault() ?? ConvertScaleText(ikunoScale);

        return new QuakeView
        {
            Id = $"{eventId}-{value.InformationType}",
            EventId = eventId,
            InformationType = value.InformationType.ToString(),
            InformationTitle = GetEarthquakeInformationTitle(value.InformationType),
            Time = occurrenceTime,
            IssueTime = FormatDateTime(receivedAt),
            Hypocenter = string.IsNullOrWhiteSpace(value.Destination) ? "調査中" : value.Destination,
            MaxScale = maxScale,
            MaxScaleText = ConvertScaleText(maxScale),
            IkunoScale = ikunoScale,
            IkunoScaleText = ikunoScaleText,
            Magnitude = value.Magnitude,
            Depth = NormalizeDepth(value.Depth),
            Tsunami = ConvertTsunamiType(value.TsunamiType),
            Latitude = ParseCoordinate(value.Latitude),
            Longitude = ParseCoordinate(value.Longitude),
            Points = points,
            ScaleGroups = groups,
        };
    }

    private static string NormalizeEarthquakeMunicipality(string prefecture, string stationName)
    {
        if (string.IsNullOrWhiteSpace(stationName))
        {
            return stationName;
        }

        var match = StationNameShorter.ShortenPattern.Match(stationName);
        if (!match.Success)
        {
            return stationName;
        }

        string municipality = NormalizeMunicipalityPrefix(prefecture, match.Groups[1].Value);
        string? islandName = GetIslandName(municipality, stationName);
        return string.IsNullOrWhiteSpace(islandName)
            ? municipality
            : $"{municipality}・{islandName}";
    }

    private static string NormalizeMunicipalityPrefix(string prefecture, string municipality)
    {
        if (municipality.StartsWith("大阪堺市", StringComparison.Ordinal))
        {
            return municipality[2..];
        }
        if (municipality.StartsWith("東京", StringComparison.Ordinal) && municipality.EndsWith("区", StringComparison.Ordinal))
        {
            return municipality[2..];
        }

        string? designatedPrefix = DesignatedCityPrefixes.FirstOrDefault(prefix =>
            municipality.StartsWith(prefix, StringComparison.Ordinal) &&
            municipality.EndsWith("区", StringComparison.Ordinal));
        if (!string.IsNullOrWhiteSpace(designatedPrefix))
        {
            return $"{designatedPrefix}市{municipality[designatedPrefix.Length..]}";
        }

        string prefectureStem = prefecture.TrimEnd('都', '道', '府', '県');
        if (!municipality.StartsWith(prefectureStem, StringComparison.Ordinal))
        {
            return municipality;
        }

        string withoutPrefecture = municipality[prefectureStem.Length..];
        return withoutPrefecture is "市" or "区" or "町" or "村"
            ? municipality
            : withoutPrefecture;
    }

    private static string? GetIslandName(string municipality, string stationName)
    {
        if (!IslandNamesByMunicipality.TryGetValue(municipality, out string[]? islandNames))
        {
            return null;
        }

        return islandNames
            .OrderByDescending(name => name.Length)
            .FirstOrDefault(name => stationName.Contains(name, StringComparison.Ordinal));
    }

    private static string CreateEarthquakeEventId(string occurrenceTime)
    {
        string timeKey = DateTime.TryParse(occurrenceTime, out DateTime parsed)
            ? parsed.ToString("yyyyMMddHHmmss")
            : occurrenceTime;
        return $"quake-{timeKey}";
    }

    private static bool IsEquivalentEarthquakeReport(QuakeView left, QuakeView right)
    {
        if (left.InformationType != right.InformationType ||
            left.Hypocenter != right.Hypocenter ||
            left.MaxScale != right.MaxScale ||
            left.Magnitude != right.Magnitude ||
            left.Depth != right.Depth)
        {
            return false;
        }

        DateTime leftIssue = ParseDateTimeOrMinimum(left.IssueTime);
        DateTime rightIssue = ParseDateTimeOrMinimum(right.IssueTime);
        if (leftIssue == DateTime.MinValue || rightIssue == DateTime.MinValue ||
            Math.Abs((leftIssue - rightIssue).TotalSeconds) > 120)
        {
            return false;
        }

        return GetEarthquakePointKey(left) == GetEarthquakePointKey(right);
    }

    private static string GetEarthquakePointKey(QuakeView value)
    {
        return string.Join(
            "|",
            value.Points
                .OrderBy(point => point.Pref)
                .ThenBy(point => point.Addr)
                .ThenBy(point => point.ScaleText)
                .Select(point => $"{point.Pref}:{point.Addr}:{point.ScaleText}")
        );
    }

    private static bool IsPreferredEarthquakeReport(QuakeView candidate, QuakeView current)
    {
        TimeSpan candidateDistance = GetOccurrenceIssueDistance(candidate);
        TimeSpan currentDistance = GetOccurrenceIssueDistance(current);
        if (candidateDistance != currentDistance)
        {
            return candidateDistance < currentDistance;
        }

        return ParseDateTimeOrMinimum(candidate.IssueTime) > ParseDateTimeOrMinimum(current.IssueTime);
    }

    private static TimeSpan GetOccurrenceIssueDistance(QuakeView value)
    {
        DateTime occurrence = ParseDateTimeOrMinimum(value.Time);
        DateTime issue = ParseDateTimeOrMinimum(value.IssueTime);
        if (occurrence == DateTime.MinValue || issue == DateTime.MinValue)
        {
            return TimeSpan.MaxValue;
        }

        return (issue - occurrence).Duration();
    }

    private static int GetPrefectureOrder(string prefecture)
    {
        return PrefectureOrder.TryGetValue(prefecture, out int order) ? order : int.MaxValue;
    }

    private static string GetEarthquakeInformationTitle(QuakeInformationType informationType)
    {
        return informationType switch
        {
            QuakeInformationType.ScalePrompt => "震度速報",
            QuakeInformationType.Destination => "震源速報",
            QuakeInformationType.ScaleAndDestination => "震源・震度情報",
            QuakeInformationType.Detail => "各地の震度情報",
            QuakeInformationType.Foreign => "遠地地震情報",
            _ => "地震情報",
        };
    }

    private static void HandleTsunami(object? sender, EPSPTsunamiEventArgs value)
    {
        DateTime systemReceivedAt = DateTime.Now;
        DateTime receivedAt = NormalizeReceivedAt(value.ReceivedAt);
        lock (StateLock)
        {
            if (value.IsCancelled)
            {
                tsunami = TsunamiView.Inactive with
                {
                    Cancelled = true,
                    IssueTime = FormatDateTime(receivedAt),
                };
                tsunamiPriorityUntil = null;
            }
            else
            {
                tsunami = new TsunamiView
                {
                    Active = true,
                    Cancelled = false,
                    IssueTime = FormatDateTime(receivedAt),
                    Type = "津波情報",
                    Areas = (value.RegionList ?? Array.Empty<TsunamiForecastRegion>())
                        .Select(ConvertTsunamiArea)
                        .OrderBy(area => GetTsunamiGradeOrder(area.Grade))
                        .ThenBy(area => area.Name)
                        .ToArray(),
                };
                tsunamiPriorityUntil = receivedAt.AddMinutes(30);
            }

            WriteStateLocked(force: true);
        }

        Console.WriteLine($"{DateTime.Now:HH:mm:ss.fff} 津波情報を即時反映しました。");
        WriteEventLog($"津波情報を即時反映: 取消={value.IsCancelled}, 予報区数={value.RegionList?.Count ?? 0}");
        WriteDetailedInformationLog(
            "tsunami",
            receivedAt,
            systemReceivedAt,
            DateTime.Now,
            tsunami
        );
        if (!value.IsCancelled)
        {
            RequestEmergencyDisplayWake(30, "津波情報");
        }
        StartDisasterAudio("Tsunami", false, value.IsCancelled, Array.Empty<string>());
        if (!value.IsCancelled)
        {
            GenerateOrQueueTsunamiMap(receivedAt);
        }
    }

    private static double? ParseCoordinate(string value)
    {
        return double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out double coordinate)
            ? coordinate
            : null;
    }

    private static void GenerateOrQueueEewMap(string? eventId)
    {
        if (string.IsNullOrWhiteSpace(eventId))
        {
            return;
        }

        if (executingTestCommand)
        {
            GenerateEewMap(eventId);
            return;
        }

        TrackMapRender(Task.Run(() => GenerateEewMap(eventId)));
    }

    private static void GenerateEewMap(string eventId)
    {
        try
        {
            EewView? snapshot;
            lock (StateLock)
            {
                snapshot = eews.FirstOrDefault(item => item.Id == eventId);
            }
            if (snapshot is null)
            {
                WriteEventLog($"緊急地震速報の地図生成対象が見つかりませんでした: {eventId}");
                return;
            }

            var points = snapshot.Areas
                .Select(area => area.KindCode)
                .Where(code => EEWAreas.Instance.ContainsKey(code))
                .Distinct(StringComparer.Ordinal)
                .Select(code => new EEWPoint(code))
                .ToList();
            string mapImage = RenderDisasterMapWithRetry(
                $"eew_{SanitizeFileName(eventId)}.png",
                new MapDrawer
                {
                    MapType = MapType.JAPAN_1024,
                    Trim = points.Count > 0,
                    PreferedAspectRatio = 1.2,
                    EEWPoints = points,
                }
            );

            SetEewMapImage(eventId, mapImage);
            WriteEventLog($"緊急地震速報の地図生成が完了しました: {mapImage}");
        }
        catch (Exception exception)
        {
            WriteEventLog($"緊急地震速報の地図生成に失敗しました: {exception.Message}");
            SetEewMapImage(eventId, FallbackDisasterMapImage);
        }
    }

    private static void GenerateOrQueueEarthquakeMap(string eventId)
    {
        if (executingTestCommand)
        {
            GenerateEarthquakeMap(eventId);
            return;
        }

        TrackMapRender(Task.Run(() => GenerateEarthquakeMap(eventId)));
    }

    private static void GenerateEarthquakeMap(string eventId)
    {
        try
        {
            QuakeView? snapshot;
            lock (StateLock)
            {
                snapshot = earthquakes.FirstOrDefault(item => item.Id == eventId);
            }
            if (snapshot is null)
            {
                WriteEventLog($"地震情報の地図生成対象が見つかりませんでした: {eventId}");
                return;
            }

            // 本文には全観測点を残し、地図には内蔵地点データで描画可能な地点だけを渡す。
            var observations = snapshot.Points
                .Where(point => !point.IsMissing && Stations.Instance.GetPoint(
                    string.IsNullOrWhiteSpace(point.ObservationAddr) ? point.Addr : point.ObservationAddr,
                    point.Pref) is not null)
                .Select(point => new ObservationPoint(
                    point.Pref,
                    string.IsNullOrWhiteSpace(point.ObservationAddr) ? point.Addr : point.ObservationAddr,
                    point.Scale))
                .ToList();
            GeoCoordinate? hypocenter = snapshot.Latitude.HasValue && snapshot.Longitude.HasValue
                ? new GeoCoordinate(snapshot.Latitude.Value, snapshot.Longitude.Value)
                : null;
            string mapImage = RenderDisasterMapWithRetry(
                $"earthquake_{SanitizeFileName(eventId)}.png",
                new MapDrawer
                {
                    MapType = MapType.JAPAN_1024,
                    Trim = observations.Count > 0 || hypocenter is not null,
                    PreferedAspectRatio = 1.2,
                    TrimLatitudeMargin = 0.45,
                    TrimLongitudeMargin = 0.7,
                    Hypocenter = hypocenter,
                    ObservationPoints = observations,
                }
            );

            SetEarthquakeMapImage(eventId, mapImage);
            WriteEventLog($"地震情報の地図生成が完了しました: {mapImage}");
        }
        catch (Exception exception)
        {
            WriteEventLog($"地震情報の地図生成に失敗しました: {exception.Message}");
            SetEarthquakeMapImage(eventId, FallbackDisasterMapImage);
        }
    }

    private static void GenerateOrQueueTsunamiMap(DateTime receivedAt)
    {
        string issueTime = FormatDateTime(receivedAt);
        if (executingTestCommand)
        {
            GenerateTsunamiMap(receivedAt, issueTime);
            return;
        }

        TrackMapRender(Task.Run(() => GenerateTsunamiMap(receivedAt, issueTime)));
    }

    private static void GenerateTsunamiMap(DateTime receivedAt, string issueTime)
    {
        try
        {
            TsunamiView snapshot;
            lock (StateLock)
            {
                snapshot = tsunami.IssueTime == issueTime ? tsunami : TsunamiView.Inactive;
            }
            if (!snapshot.Active)
            {
                WriteEventLog($"津波情報の地図生成対象が見つかりませんでした: {issueTime}");
                return;
            }

            var points = snapshot.Areas
                .Where(area => TsunamiAreas.Instance.GetArea(area.Name) is not null)
                .Select(area => new TsunamiPoint(area.Name, ConvertMapTsunamiCategory(area.Grade)))
                .ToList();
            string mapImage = RenderDisasterMapWithRetry(
                $"tsunami_{receivedAt:yyyyMMddHHmmssfff}.png",
                new MapDrawer
                {
                    MapType = MapType.JAPAN_1024,
                    Trim = points.Count > 0,
                    PreferedAspectRatio = 1.2,
                    TsunamiPoints = points,
                }
            );

            SetTsunamiMapImage(issueTime, mapImage);
            WriteEventLog($"津波情報の地図生成が完了しました: {mapImage}");
        }
        catch (Exception exception)
        {
            WriteEventLog($"津波情報の地図生成に失敗しました: {exception.Message}");
            SetTsunamiMapImage(issueTime, FallbackDisasterMapImage);
        }
    }

    private static void SetEewMapImage(string eventId, string mapImage)
    {
        lock (StateLock)
        {
            EewView? target = eews.FirstOrDefault(item => item.Id == eventId);
            if (target is null) return;

            target.MapImage = mapImage;
            if (eew?.Id == eventId) eew.MapImage = mapImage;
            WriteStateLocked(force: true);
        }
    }

    private static void SetEarthquakeMapImage(string eventId, string mapImage)
    {
        lock (StateLock)
        {
            QuakeView? target = earthquakes.FirstOrDefault(item => item.Id == eventId);
            if (target is null) return;

            target.MapImage = mapImage;
            if (earthquake?.Id == eventId) earthquake.MapImage = mapImage;
            WriteStateLocked(force: true);
        }
    }

    private static void SetTsunamiMapImage(string issueTime, string mapImage)
    {
        lock (StateLock)
        {
            if (!tsunami.Active || tsunami.IssueTime != issueTime) return;

            tsunami = tsunami with { MapImage = mapImage };
            WriteStateLocked(force: true);
        }
    }

    private static void TrackMapRender(Task task)
    {
        lock (MapTaskLock)
        {
            PendingMapTasks.Add(task);
        }

        _ = task.ContinueWith(
            completedTask =>
            {
                lock (MapTaskLock)
                {
                    PendingMapTasks.Remove(completedTask);
                }
            },
            TaskScheduler.Default
        );
    }

    private static void WaitForPendingMapRenders(TimeSpan timeout)
    {
        Task[] tasks;
        lock (MapTaskLock)
        {
            tasks = PendingMapTasks.ToArray();
        }
        if (tasks.Length == 0)
        {
            return;
        }

        try
        {
            Task.WaitAll(tasks, timeout);
        }
        catch (AggregateException exception)
        {
            WriteEventLog($"テスト用地図の生成完了待機中にエラーが発生しました: {exception.GetBaseException().Message}");
        }
    }

    private static Map.Model.TsunamiCategory ConvertMapTsunamiCategory(string grade)
    {
        return grade switch
        {
            "大津波警報" => Map.Model.TsunamiCategory.MajorWarning,
            "津波警報" => Map.Model.TsunamiCategory.Warning,
            "津波注意報" => Map.Model.TsunamiCategory.Advisory,
            _ => Map.Model.TsunamiCategory.Unknown,
        };
    }

    private static string RenderDisasterMap(string fileName, MapDrawer drawer)
    {
        string mapDirectory = Path.Combine(projectDirectory, "temp", "disaster_maps");
        Directory.CreateDirectory(mapDirectory);
        string destinationPath = Path.Combine(mapDirectory, fileName);
        string temporaryPath = destinationPath + ".tmp";

        lock (MapRenderLock)
        {
            using MemoryStream png = drawer.DrawAsPng();
            using (FileStream file = File.Create(temporaryPath))
            {
                png.CopyTo(file);
            }
            File.Move(temporaryPath, destinationPath, overwrite: true);
            DeleteOldMapImages(mapDirectory, destinationPath);
        }

        return $"temp/disaster_maps/{fileName}";
    }

    private static string RenderDisasterMapWithRetry(string fileName, MapDrawer drawer)
    {
        Exception? lastException = null;
        for (int attempt = 1; attempt <= 2; attempt++)
        {
            try
            {
                return RenderDisasterMap(fileName, drawer);
            }
            catch (Exception exception)
            {
                lastException = exception;
                WriteEventLog($"地図生成の{attempt}回目に失敗しました: {exception.Message}");
                Thread.Sleep(250);
            }
        }

        throw new InvalidOperationException("地図生成の再試行に失敗しました。", lastException);
    }

    private static void DeleteOldMapImages(string mapDirectory, string currentPath)
    {
        DateTime cutoff = DateTime.Now.AddDays(-1);
        foreach (string path in Directory.EnumerateFiles(mapDirectory, "*.png"))
        {
            if (path.Equals(currentPath, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            if (File.GetLastWriteTime(path) < cutoff)
            {
                File.Delete(path);
            }
        }
    }

    private static string SanitizeFileName(string value)
    {
        char[] invalid = Path.GetInvalidFileNameChars();
        return new string(value.Select(character => invalid.Contains(character) ? '_' : character).ToArray());
    }

    private static TsunamiAreaView ConvertTsunamiArea(TsunamiForecastRegion value)
    {
        string grade = value.Category switch
        {
            Client.Peer.TsunamiCategory.MajorWarning => "大津波警報",
            Client.Peer.TsunamiCategory.Warning => "津波警報",
            Client.Peer.TsunamiCategory.Advisory => "津波注意報",
            _ => "津波情報",
        };
        return new TsunamiAreaView
        {
            Name = value.Region,
            Grade = grade,
            Immediate = value.IsImmediately,
            MaxHeight = grade switch
            {
                "大津波警報" => "10m超",
                "津波警報" => "3m",
                "津波注意報" => "1m",
                _ => "不明",
            },
            FirstHeight = value.IsImmediately ? "津波到達中と推測" : "調査中",
        };
    }

    private static int GetTsunamiGradeOrder(string grade)
    {
        return grade switch
        {
            "大津波警報" => 0,
            "津波警報" => 1,
            "津波注意報" => 2,
            _ => 3,
        };
    }

    private static void ExpireOldInformation()
    {
        lock (StateLock)
        {
            DateTime now = DateTime.Now;
            bool changed = false;
            int removedEews = eews.RemoveAll(item =>
            {
                DateTime issueTime = ParseDateTimeOrMinimum(item.IssueTime);
                return issueTime == DateTime.MinValue || now > issueTime.AddMinutes(3);
            });
            changed |= removedEews > 0;
            eew = eews
                .OrderByDescending(item => ParseDateTimeOrMinimum(item.IssueTime))
                .FirstOrDefault();
            eewExpiresAt = eew is null
                ? null
                : ParseDateTimeOrMinimum(eew.IssueTime).AddMinutes(3);
            int removed = earthquakes.RemoveAll(item =>
            {
                DateTime issueTime = ParseDateTimeOrMinimum(item.IssueTime);
                return issueTime == DateTime.MinValue || now > GetEarthquakeExpiry(issueTime, item.MaxScale);
            });
            changed |= removed > 0;
            earthquake = earthquakes
                .OrderByDescending(item => ParseDateTimeOrMinimum(item.IssueTime))
                .FirstOrDefault();
            if (changed)
            {
                earthquakeExpiresAt = earthquake is null
                    ? null
                    : GetEarthquakeExpiry(ParseDateTimeOrMinimum(earthquake.IssueTime), earthquake.MaxScale);
                earthquakePriorityUntil = earthquake is null
                    ? null
                    : GetEarthquakePriorityUntil(ParseDateTimeOrMinimum(earthquake.IssueTime), earthquake.MaxScale);
                WriteStateLocked(force: true);
                return;
            }

            WriteStateLocked(force: false);
        }

    }

    private static void StartDisasterAudio(
        string mode,
        bool followUp,
        bool cancelled,
        string[] areaCodes,
        int scale = 0,
        string[]? eewVoiceFiles = null,
        bool genericEew = false)
    {
        try
        {
            if (mode == "Eew" && (followUp || cancelled))
            {
                StopCurrentDisasterAudio();
            }

            string scriptPath = Path.Combine(projectDirectory, "earthquake", "play_disaster_audio.ps1");
            if (!File.Exists(scriptPath))
            {
                WriteEventLog($"災害通知音スクリプトが見つかりません: {scriptPath}");
                return;
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                WorkingDirectory = Path.GetDirectoryName(scriptPath) ?? projectDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
            };
            startInfo.ArgumentList.Add("-NoProfile");
            startInfo.ArgumentList.Add("-ExecutionPolicy");
            startInfo.ArgumentList.Add("Bypass");
            startInfo.ArgumentList.Add("-WindowStyle");
            startInfo.ArgumentList.Add("Hidden");
            startInfo.ArgumentList.Add("-File");
            startInfo.ArgumentList.Add(scriptPath);
            startInfo.ArgumentList.Add("-Mode");
            startInfo.ArgumentList.Add(mode);
            startInfo.ArgumentList.Add("-Scale");
            startInfo.ArgumentList.Add(scale.ToString(CultureInfo.InvariantCulture));
            if (followUp)
            {
                startInfo.ArgumentList.Add("-FollowUp");
            }
            if (cancelled)
            {
                startInfo.ArgumentList.Add("-Cancelled");
            }
            if (areaCodes.Length > 0)
            {
                startInfo.ArgumentList.Add("-AreaCodes");
                startInfo.ArgumentList.Add(string.Join(",", areaCodes));
            }
            if (eewVoiceFiles?.Length > 0)
            {
                startInfo.ArgumentList.Add("-VoiceFiles");
                startInfo.ArgumentList.Add(string.Join(",", eewVoiceFiles));
            }
            if (genericEew)
            {
                startInfo.ArgumentList.Add("-GenericEew");
            }

            Process? process = Process.Start(startInfo);
            if (process is not null)
            {
                lock (DisasterAudioLock)
                {
                    activeDisasterAudioProcess?.Dispose();
                    activeDisasterAudioProcess = process;
                }
            }
            WriteEventLog(
                $"災害通知音プロセスを開始しました: " +
                $"mode={mode}, followUp={followUp}, cancelled={cancelled}, genericEew={genericEew}, " +
                $"voices={string.Join(',', eewVoiceFiles ?? Array.Empty<string>())}, pid={process?.Id ?? 0}"
            );
        }
        catch (Exception exception)
        {
            WriteEventLog($"災害通知音を開始できませんでした: {exception.Message}");
        }
    }

    private static void StopCurrentDisasterAudio()
    {
        string processIdPath = Path.Combine(projectDirectory, "temp", "disaster_audio.pid");
        Process? trackedProcess;
        lock (DisasterAudioLock)
        {
            trackedProcess = activeDisasterAudioProcess;
            activeDisasterAudioProcess = null;
        }

        if (trackedProcess is not null)
        {
            StopDisasterAudioProcess(trackedProcess);
            trackedProcess.Dispose();
        }

        try
        {
            if (!File.Exists(processIdPath))
            {
                return;
            }
            string processIdText = File.ReadAllText(processIdPath, Encoding.UTF8).Trim();
            if (!int.TryParse(processIdText, out int processId))
            {
                return;
            }

            using Process process = Process.GetProcessById(processId);
            StopDisasterAudioProcess(process);
        }
        catch (ArgumentException)
        {
            // PIDのプロセスが既に終了している場合は何もしない。
        }
        catch (Exception exception)
        {
            WriteEventLog($"先行する災害通知音を停止できませんでした: {exception.Message}");
        }
        finally
        {
            try
            {
                File.Delete(processIdPath);
            }
            catch (Exception exception)
            {
                WriteEventLog($"災害通知音のPIDファイルを削除できませんでした: {exception.Message}");
            }
        }
    }

    private static void StopDisasterAudioProcess(Process process)
    {
        if (process.HasExited)
        {
            return;
        }

        int processId = process.Id;
        process.Kill(entireProcessTree: true);
        process.WaitForExit(3000);
        WriteEventLog($"先行する災害通知音を停止しました: pid={processId}");
    }

    private static bool ClearExpired<T>(ref T? value, ref DateTime? expiresAt, DateTime now) where T : class
    {
        if (value is null || !expiresAt.HasValue || now <= expiresAt.Value)
        {
            return false;
        }

        value = null;
        expiresAt = null;
        return true;
    }

    private static void WriteState(bool force)
    {
        lock (StateLock)
        {
            WriteStateLocked(force);
        }
    }

    private static void WriteStateLocked(bool force)
    {
        DateTime now = DateTime.Now;
        bool tsunamiPriority = tsunami.Active && tsunamiPriorityUntil.HasValue && now <= tsunamiPriorityUntil.Value;
        EewView[] activeEews = eews
            .OrderByDescending(item => ParseDateTimeOrMinimum(item.IssueTime))
            .ToArray();
        DateTime? latestEewExpiresAt = activeEews.Length == 0
            ? null
            : activeEews
                .Select(item => ParseDateTimeOrMinimum(item.IssueTime).AddMinutes(3))
                .Max();
        QuakeView[] activeEarthquakes = earthquakes
            .OrderByDescending(item => ParseDateTimeOrMinimum(item.IssueTime))
            .ThenBy(item => item.InformationType)
            .ToArray();
        QuakeView[] emergencyEarthquakes = activeEarthquakes
            .Where(item => now <= GetEarthquakePriorityUntil(
                ParseDateTimeOrMinimum(item.IssueTime),
                item.MaxScale))
            .ToArray();
        DateTime? latestEarthquakePriorityUntil = emergencyEarthquakes.Length == 0
            ? null
            : emergencyEarthquakes
                .Select(item => GetEarthquakePriorityUntil(
                    ParseDateTimeOrMinimum(item.IssueTime),
                    item.MaxScale))
                .Max();
        bool earthquakePriority = emergencyEarthquakes.Length > 0;
        bool disasterPriority = activeEews.Length > 0 || tsunamiPriority || earthquakePriority;

        string[] reasons = new[]
        {
            activeEews.Length > 0 ? "eew" : "",
            tsunamiPriority ? "tsunami" : "",
            earthquakePriority ? "earthquake" : "",
        }.Where(reason => reason.Length > 0).ToArray();

        var corePayload = new
        {
            Eew = eew,
            Eews = activeEews,
            Earthquake = earthquake,
            Earthquakes = activeEarthquakes,
            EmergencyEarthquake = emergencyEarthquakes.FirstOrDefault(),
            EmergencyEarthquakes = emergencyEarthquakes,
            RecentScale3Earthquake = earthquake,
            Tsunami = tsunami,
            EmergencyMode = new
            {
                Active = disasterPriority,
                Reason = string.Join(",", reasons),
                Until = LatestDate(latestEewExpiresAt, latestEarthquakePriorityUntil, tsunamiPriorityUntil),
            },
            PriorityMode = disasterPriority ? "disaster" : "normal",
            PriorityReasons = reasons,
        };

        string coreJson = JsonSerializer.Serialize(corePayload, JsonOptions);
        if (!force && coreJson == lastJson)
        {
            return;
        }

        lastJson = coreJson;
        var payload = new
        {
            UpdateTime = FormatDateTime(now),
            corePayload.Eew,
            corePayload.Eews,
            corePayload.Earthquake,
            corePayload.Earthquakes,
            corePayload.EmergencyEarthquake,
            corePayload.EmergencyEarthquakes,
            corePayload.RecentScale3Earthquake,
            corePayload.Tsunami,
            corePayload.EmergencyMode,
            corePayload.PriorityMode,
            corePayload.PriorityReasons,
        };
        string json = JsonSerializer.Serialize(payload, JsonOptions);
        string temporaryPath = outputPath + ".tmp";
        File.WriteAllText(temporaryPath, $"var earthquakeData = {json};", new UTF8Encoding(false));
        File.Move(temporaryPath, outputPath, overwrite: true);
    }

    private static string? LatestDate(params DateTime?[] values)
    {
        DateTime? latest = values.Where(value => value.HasValue).Max();
        return latest.HasValue ? FormatDateTime(latest.Value) : null;
    }

    private static DateTime NormalizeReceivedAt(DateTime value)
    {
        return value == default ? DateTime.Now : value.ToLocalTime();
    }

    private static string NormalizeOccurrenceTime(string value, DateTime fallback)
    {
        string normalized = (value ?? "").Trim().TrimEnd('頃').Trim();
        if (TryParseFullOccurrenceTime(normalized, out DateTime fullTime))
        {
            return FormatDateTime(fullTime);
        }

        if (TryParseProtocolOccurrenceTime(normalized, fallback, out DateTime protocolTime))
        {
            return FormatDateTime(protocolTime);
        }

        return FormatDateTime(fallback);
    }

    private static bool TryParseFullOccurrenceTime(string value, out DateTime parsed)
    {
        parsed = default;
        if (!System.Text.RegularExpressions.Regex.IsMatch(value, @"^\d{4}[/\-年]"))
        {
            return false;
        }

        return DateTime.TryParse(
            value,
            CultureInfo.GetCultureInfo("ja-JP"),
            DateTimeStyles.AssumeLocal,
            out parsed
        );
    }

    private static bool TryParseProtocolOccurrenceTime(
        string value,
        DateTime fallback,
        out DateTime parsed)
    {
        var match = System.Text.RegularExpressions.Regex.Match(
            value,
            @"^(?:(?<month>\d{1,2})月)?(?<day>\d{1,2})日(?<hour>\d{1,2})時(?<minute>\d{1,2})分(?:(?<second>\d{1,2})秒)?$"
        );
        if (!match.Success)
        {
            parsed = default;
            return false;
        }

        int month = ParseOccurrencePart(match, "month", fallback.Month);
        int day = ParseOccurrencePart(match, "day", 1);
        int hour = ParseOccurrencePart(match, "hour", 0);
        int minute = ParseOccurrencePart(match, "minute", 0);
        int second = ParseOccurrencePart(match, "second", 0);
        try
        {
            parsed = new DateTime(fallback.Year, month, day, hour, minute, second, DateTimeKind.Local);
        }
        catch (ArgumentOutOfRangeException)
        {
            parsed = default;
            return false;
        }

        // 月初に前月末の地震情報を受信する場合を補正する。
        if (!match.Groups["month"].Success && parsed > fallback.AddHours(1))
        {
            parsed = parsed.AddMonths(-1);
        }
        return true;
    }

    private static int ParseOccurrencePart(
        System.Text.RegularExpressions.Match match,
        string groupName,
        int fallback)
    {
        return int.TryParse(
            match.Groups[groupName].Value,
            NumberStyles.None,
            CultureInfo.InvariantCulture,
            out int parsed)
            ? parsed
            : fallback;
    }

    private static bool TryParseDateTime(string? value, out DateTime parsed)
    {
        return DateTime.TryParse(
            value,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeLocal,
            out parsed
        );
    }

    private static DateTime ParseDateTimeOrMinimum(string? value)
    {
        return TryParseDateTime(value, out DateTime parsed) ? parsed : DateTime.MinValue;
    }

    private static string NormalizeDepth(string value)
    {
        return value.Replace("km", "", StringComparison.OrdinalIgnoreCase).Trim();
    }

    private static DateTime GetEarthquakeExpiry(DateTime receivedAt, int scale)
    {
        if (scale >= 70) return receivedAt.AddHours(5);
        if (scale >= 45) return receivedAt.AddHours(3);
        return receivedAt.AddHours(1);
    }

    private static DateTime GetEarthquakePriorityUntil(DateTime receivedAt, int scale)
    {
        if (scale >= 70) return receivedAt.AddMinutes(30);
        if (scale >= 55) return receivedAt.AddMinutes(10);
        if (scale >= 45) return receivedAt.AddMinutes(5);
        return receivedAt.AddMinutes(3);
    }

    private static int ConvertScale(string value)
    {
        string normalized = NormalizeScale(value);
        return normalized switch
        {
            "7" => 70,
            "7相当" => 70,
            "6強" => 60,
            "6+" => 60,
            "6弱" => 55,
            "6-" => 55,
            "5強" => 50,
            "5+" => 50,
            "5弱" => 45,
            "5-" => 45,
            "5弱以上(推定)" => 46,
            "4" => 40,
            "3" => 30,
            "2" => 20,
            "1" => 10,
            _ => 0,
        };
    }

    private static bool IsMissingScale(string? value)
    {
        return (value ?? "").Contains("欠測", StringComparison.Ordinal);
    }

    private static string ConvertObservationScaleText(string? value)
    {
        if (!IsMissingScale(value))
        {
            return ConvertScaleText(ConvertScale(value ?? ""));
        }

        int equivalentScale = GetMissingEquivalentScale(value);
        return equivalentScale > 0
            ? $"欠測（震度{ConvertScaleText(equivalentScale)}相当）"
            : "欠測";
    }

    private static int GetMissingEquivalentScale(string? value)
    {
        string normalized = NormalizeScale(value);
        string[] scaleCandidates = { "7", "6強", "6弱", "5強", "5弱", "4", "3", "2", "1" };
        foreach (string candidate in scaleCandidates)
        {
            if (normalized.Contains($"{candidate}相当", StringComparison.Ordinal))
            {
                return ConvertScale(candidate);
            }
        }
        return 0;
    }

    private static int GetEarthquakePointDisplayOrder(QuakePointView point)
    {
        if (!point.IsMissing)
        {
            return point.Scale * 10;
        }

        int equivalentScale = GetMissingEquivalentScale(point.ScaleText);
        return equivalentScale > 0 ? equivalentScale * 10 + 1 : 1000;
    }

    private static string NormalizeScale(string? value)
    {
        string normalized = (value ?? "")
            .Trim()
            .Replace("　", "", StringComparison.Ordinal)
            .Replace("震度", "", StringComparison.Ordinal)
            .Replace("＋", "+", StringComparison.Ordinal)
            .Replace("－", "-", StringComparison.Ordinal)
            .Replace("（", "(", StringComparison.Ordinal)
            .Replace("）", ")", StringComparison.Ordinal);

        if (normalized.EndsWith("以上", StringComparison.Ordinal))
        {
            normalized = normalized[..^2];
        }

        return normalized;
    }

    private static string ConvertScaleText(int value)
    {
        return value switch
        {
            70 => "7",
            60 => "6強",
            55 => "6弱",
            50 => "5強",
            45 => "5弱",
            40 => "4",
            30 => "3",
            _ => "-",
        };
    }

    private static string ConvertTsunamiType(DomesticTsunamiType value)
    {
        return value switch
        {
            DomesticTsunamiType.None => "なし",
            DomesticTsunamiType.Effective => "あり",
            DomesticTsunamiType.Checking => "調査中",
            _ => "不明",
        };
    }

    private static string FormatDateTime(DateTime value)
    {
        return value.ToString("yyyy-MM-dd'T'HH:mm:ss.fffzzz", CultureInfo.InvariantCulture);
    }

    private static void WriteEventLog(string message)
    {
        if (string.IsNullOrWhiteSpace(eventLogPath))
        {
            return;
        }

        try
        {
            string line = $"{DateTime.Now:yyyy/MM/dd HH:mm:ss.fff} {message}{Environment.NewLine}";
            lock (EventLogLock)
            {
                File.AppendAllText(eventLogPath, line, new UTF8Encoding(false));
            }
        }
        catch
        {
            // ログ書き込み失敗で受信プロセスを停止させない。
        }
    }

    private static void RequestEmergencyDisplayWake(int minutes, string reason)
    {
        _ = Task.Run(async () =>
        {
            try
            {
                string encodedReason = Uri.EscapeDataString(reason);
                string url =
                    $"http://127.0.0.1:18765/time-signal/display/emergency-wake" +
                    $"?minutes={minutes}&reason={encodedReason}";
                using HttpResponseMessage response = await LocalControlClient.GetAsync(url);
                if (!response.IsSuccessStatusCode)
                {
                    WriteEventLog($"緊急情報による画面点灯要求に失敗しました: status={(int)response.StatusCode}, reason={reason}");
                }
            }
            catch (Exception exception)
            {
                WriteEventLog($"緊急情報による画面点灯要求に失敗しました: reason={reason}, error={exception.Message}");
            }
        });
    }

    private static void WriteDetailedInformationLog(
        string type,
        DateTime jmaIssueAt,
        DateTime receivedAt,
        DateTime displayedAt,
        object details)
    {
        if (string.IsNullOrWhiteSpace(informationLogPath))
        {
            return;
        }

        try
        {
            var record = new
            {
                Type = type,
                IsTest = executingTestCommand,
                JmaIssueAt = FormatDateTime(jmaIssueAt),
                ReceivedAt = FormatDateTime(receivedAt),
                DisplayedAt = FormatDateTime(displayedAt),
                Details = details,
            };
            string line = JsonSerializer.Serialize(record, JsonLineOptions) + Environment.NewLine;
            lock (EventLogLock)
            {
                File.AppendAllText(informationLogPath, line, new UTF8Encoding(false));
            }
        }
        catch (Exception exception)
        {
            WriteEventLog($"地震詳細ログを書き込めませんでした: {exception.Message}");
        }
    }
}

internal sealed class EewView
{
    public string Id { get; init; } = "";
    public string EventId { get; init; } = "";
    public int Serial { get; init; }
    public bool IsFollowUp { get; init; }
    public bool Cancelled { get; init; }
    public string IssueTime { get; init; } = "";
    public string? OriginTime { get; init; }
    public string? ArrivalTime { get; init; }
    public string Hypocenter { get; init; } = "";
    public string? Magnitude { get; init; }
    public string? Depth { get; init; }
    public EewAreaView[] Areas { get; init; } = Array.Empty<EewAreaView>();
    public EewAreaView[]? DisplayAreas { get; init; }
    public string? MapImage { get; set; }
}

internal sealed record EewRegionDefinition(
    string DisplayName,
    string AudioFile,
    int[] AreaCodes
);

internal sealed record EewAnnouncement(
    int Order,
    string DisplayName,
    string AudioFile
);

internal sealed class EewAreaView
{
    public string Name { get; init; } = "";
    public string Pref { get; init; } = "";
    public int ScaleFrom { get; init; }
    public int ScaleTo { get; init; }
    public string ScaleText { get; init; } = "";
    public string? ArrivalTime { get; init; }
    public string KindCode { get; init; } = "";
}

internal sealed class QuakeView
{
    public string Id { get; init; } = "";
    public string EventId { get; init; } = "";
    public string InformationType { get; init; } = "";
    public string InformationTitle { get; init; } = "地震情報";
    public string Time { get; init; } = "";
    public string IssueTime { get; init; } = "";
    public string Hypocenter { get; init; } = "";
    public int MaxScale { get; init; }
    public string MaxScaleText { get; init; } = "";
    public int IkunoScale { get; init; }
    public string IkunoScaleText { get; init; } = "";
    public string Magnitude { get; init; } = "";
    public string Depth { get; init; } = "";
    public string Tsunami { get; init; } = "";
    public double? Latitude { get; init; }
    public double? Longitude { get; init; }
    public QuakePointView[] Points { get; init; } = Array.Empty<QuakePointView>();
    public ScaleGroupView[] ScaleGroups { get; init; } = Array.Empty<ScaleGroupView>();
    public string? MapImage { get; set; }
}

internal sealed class QuakePointView
{
    public string Pref { get; init; } = "";
    public string Addr { get; init; } = "";
    public string ObservationAddr { get; init; } = "";
    public int Scale { get; init; }
    public string ScaleText { get; init; } = "";
    public bool IsMissing { get; init; }
}

internal sealed class ScaleGroupView
{
    public int Scale { get; init; }
    public string ScaleText { get; init; } = "";
    public bool IsMissing { get; init; }
    public PrefGroupView[] Prefs { get; init; } = Array.Empty<PrefGroupView>();
}

internal sealed class PrefGroupView
{
    public string Pref { get; init; } = "";
    public string[] Addrs { get; init; } = Array.Empty<string>();
}

internal sealed record TsunamiView
{
    public static TsunamiView Inactive { get; } = new();
    public bool Active { get; init; }
    public bool Cancelled { get; init; }
    public string? IssueTime { get; init; }
    public string? Type { get; init; }
    public TsunamiAreaView[] Areas { get; init; } = Array.Empty<TsunamiAreaView>();
    public string? MapImage { get; init; }
}

internal sealed class TsunamiAreaView
{
    public string Name { get; init; } = "";
    public string Grade { get; init; } = "";
    public bool Immediate { get; init; }
    public string MaxHeight { get; init; } = "";
    public string FirstHeight { get; init; } = "";
}

internal sealed class StoredState
{
    public EewView? Eew { get; init; }
    public EewView[]? Eews { get; init; }
    public QuakeView? Earthquake { get; init; }
    public QuakeView[]? Earthquakes { get; init; }
    public TsunamiView? Tsunami { get; init; }
}

internal sealed class P2pApiEarthquake
{
    public string Id { get; init; } = "";
    public P2pApiIssue? Issue { get; init; }
    public P2pApiEarthquakeBody? Earthquake { get; init; }
    public P2pApiPoint[]? Points { get; init; }
}

internal sealed class P2pApiIssue
{
    public string Source { get; init; } = "";
    public string Time { get; init; } = "";
    public string Type { get; init; } = "";
}

internal sealed class P2pApiEarthquakeBody
{
    public string Time { get; init; } = "";
    public int MaxScale { get; init; }
    public string DomesticTsunami { get; init; } = "Unknown";
    public P2pApiHypocenter? Hypocenter { get; init; }
}

internal sealed class P2pApiHypocenter
{
    public string? Name { get; init; }
    public int? Depth { get; init; }
    public double? Magnitude { get; init; }
    public double? Latitude { get; init; }
    public double? Longitude { get; init; }
}

internal sealed class P2pApiPoint
{
    public string? Pref { get; init; }
    public string? Addr { get; init; }
    public int Scale { get; init; }
}

internal sealed class TestCommand
{
    public string Id { get; init; } = "";
    public string Kind { get; init; } = "";
    public string Scale { get; init; } = "";
    public string Hypocenter { get; init; } = "";
    public string HypocenterLatitude { get; init; } = "";
    public string HypocenterLongitude { get; init; } = "";
    public string OccurredAt { get; init; } = "";
    public string EarthquakeType { get; init; } = "detail";
    public string EewType { get; init; } = "announcement";
    public string Magnitude { get; init; } = "5.0";
    public string Depth { get; init; } = "10";
    public string TsunamiType { get; init; } = "津波なし";
    public string[] EewAreas { get; init; } = Array.Empty<string>();
    public TestQuakePoint[] EarthquakeAreas { get; init; } = Array.Empty<TestQuakePoint>();
    public TestQuakePoint[] EarthquakePoints { get; init; } = Array.Empty<TestQuakePoint>();
    public TestTsunamiArea[] TsunamiAreas { get; init; } = Array.Empty<TestTsunamiArea>();
}

internal sealed class TestQuakePoint
{
    public string Pref { get; init; } = "";
    public string Name { get; init; } = "";
    public string Scale { get; init; } = "3";
}

internal sealed class TestTsunamiArea
{
    public string Name { get; init; } = "";
    public string Grade { get; init; } = "津波注意報";
    public bool Immediate { get; init; }
}
