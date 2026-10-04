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
    private static readonly List<Task> PendingMapTasks = new();
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
    private static QuakeView? earthquake;
    private static TsunamiView tsunami = TsunamiView.Inactive;
    private static DateTime? eewExpiresAt;
    private static DateTime? earthquakeExpiresAt;
    private static DateTime? earthquakePriorityUntil;
    private static DateTime? tsunamiPriorityUntil;
    private static string lastJson = "";
    private static bool executingTestCommand;
    private static string? testEewHypocenterName;

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
        int[] areaCodes = command.EewAreas
            .Select(value => int.TryParse(value, out int code) ? code : EEWConverter.GetAreaCode(value))
            .Where(code => code > 0)
            .Distinct()
            .ToArray();
        if (areaCodes.Length == 0)
        {
            areaCodes = new[] { 191 };
        }

        int hypocenterCode = EEWConverter.GetHypocenterCode(command.Hypocenter);
        if (hypocenterCode < 0)
        {
            // The P2P packet requires a code, while an administration test may
            // intentionally use a scenario name not present in the code table.
            hypocenterCode = 871;
        }

        testEewHypocenterName = command.Hypocenter;
        try
        {
            HandleEew(null, new EPSPEEWEventArgs
            {
                IsTest = true,
                IsExpired = false,
                IsInvalidSignature = false,
                ReceivedAt = DateTime.Now,
                Hypocenter = hypocenterCode,
                Areas = areaCodes,
            });
        }
        finally
        {
            testEewHypocenterName = null;
        }
    }

    private static void ExecuteEarthquakeTest(TestCommand command)
    {
        TestQuakePoint[] requestedPoints = command.EarthquakePoints.Length > 0
            ? command.EarthquakePoints
            : new[] { new TestQuakePoint { Pref = "大阪府", Name = "大阪市生野区", Scale = command.Scale } };
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

        HandleEarthquake(null, new EPSPQuakeEventArgs
        {
            Depth = "10km",
            Destination = string.IsNullOrWhiteSpace(command.Hypocenter) ? "大阪府北部" : command.Hypocenter,
            InformationType = QuakeInformationType.Detail,
            IsCorrection = false,
            IsExpired = false,
            IsInvalidSignature = false,
            IssueFrom = "管理画面試験",
            Latitude = "34.70",
            Longitude = "135.50",
            Magnitude = "5.0",
            OccuredTime = DateTime.Now.ToString("dd日HH時mm分"),
            PointList = points,
            ReceivedAt = DateTime.Now,
            Scale = maximumScale,
            TsunamiType = DomesticTsunamiType.None,
        });
    }

    private static void ExecuteTsunamiTest(TestCommand command)
    {
        TestTsunamiArea[] requestedAreas = command.TsunamiAreas.Length > 0
            ? command.TsunamiAreas
            : new[] { new TestTsunamiArea { Name = "大阪府", Grade = "津波注意報" } };
        TsunamiForecastRegion[] regions = requestedAreas
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
            earthquake = null;
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
        if (stored.Eew is not null && TryParseDateTime(stored.Eew.IssueTime, out DateTime eewTime))
        {
            DateTime expiresAt = eewTime.AddMinutes(3);
            if (now <= expiresAt)
            {
                eew = stored.Eew;
                eewExpiresAt = expiresAt;
            }
        }

        if (stored.Earthquake is not null && TryParseDateTime(stored.Earthquake.IssueTime, out DateTime quakeTime))
        {
            DateTime expiresAt = GetEarthquakeExpiry(quakeTime, stored.Earthquake.MaxScale);
            if (now <= expiresAt)
            {
                earthquake = stored.Earthquake;
                earthquakeExpiresAt = expiresAt;
                earthquakePriorityUntil = GetEarthquakePriorityUntil(quakeTime, stored.Earthquake.MaxScale);
            }
        }

        if (stored.Tsunami?.Active == true && TryParseDateTime(stored.Tsunami.IssueTime, out DateTime tsunamiTime))
        {
            tsunami = stored.Tsunami;
            tsunamiPriorityUntil = tsunamiTime.AddMinutes(30);
        }
    }

    private static void HandleEew(object? sender, EPSPEEWEventArgs value)
    {
        DateTime systemReceivedAt = DateTime.Now;
        DateTime receivedAt = NormalizeReceivedAt(value.ReceivedAt);
        lock (StateLock)
        {
            eew = new EewView
            {
                Id = $"p2p-eew-{receivedAt:yyyyMMddHHmmssfff}",
                EventId = $"p2p-{receivedAt:yyyyMMddHHmmss}",
                Serial = value.IsFollowUp ? 2 : 1,
                IsFollowUp = value.IsFollowUp,
                Cancelled = value.IsCancelled,
                IssueTime = FormatDateTime(receivedAt),
                OriginTime = null,
                ArrivalTime = null,
                Hypocenter = executingTestCommand && !string.IsNullOrWhiteSpace(testEewHypocenterName)
                    ? testEewHypocenterName
                    : EEWConverter.GetHypocenter(value.Hypocenter) ?? "調査中",
                Magnitude = null,
                Depth = null,
                Areas = value.Areas
                    .Where(code => code > 0)
                    .Select(CreateEewArea)
                    .ToArray(),
            };
            eewExpiresAt = receivedAt.AddMinutes(3);
            WriteStateLocked(force: true);
        }

        Console.WriteLine($"{DateTime.Now:HH:mm:ss.fff} 緊急地震速報を即時反映しました。");
        WriteEventLog($"緊急地震速報を即時反映: 震源={eew?.Hypocenter ?? "調査中"}, 取消={value.IsCancelled}");
        WriteDetailedInformationLog(
            "eew",
            receivedAt,
            systemReceivedAt,
            DateTime.Now,
            eew ?? new EewView()
        );
        StartDisasterAudio(
            "Eew",
            value.IsFollowUp,
            value.IsCancelled,
            value.Areas
                .Where(code => code > 0)
                .Select(code => code.ToString(CultureInfo.InvariantCulture))
                .ToArray()
        );
        QueueEewMap(eew?.Id);
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
            earthquake = converted;
            earthquakeExpiresAt = GetEarthquakeExpiry(receivedAt, maxScale);
            earthquakePriorityUntil = GetEarthquakePriorityUntil(receivedAt, maxScale);
            eew = null;
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
        StartDisasterAudio("Earthquake", false, false, Array.Empty<string>(), maxScale);
        QueueEarthquakeMap(converted.Id);
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
            eewExpiresAt = null;
            WriteStateLocked(force: true);
        }
    }

    private static QuakeView ConvertEarthquake(EPSPQuakeEventArgs value, int maxScale, DateTime receivedAt)
    {
        QuakePointView[] points = (value.PointList ?? Array.Empty<QuakeObservationPoint>())
            .Select(point => new
            {
                Point = point,
                Scale = ConvertScale(point.Scale),
            })
            .Where(item => item.Scale >= 30)
            .Select(point => new QuakePointView
            {
                Pref = point.Point.Prefecture,
                Addr = point.Point.Name,
                Scale = point.Scale,
                ScaleText = ConvertScaleText(point.Scale),
            })
            .OrderByDescending(point => point.Scale)
            .ThenBy(point => point.Pref)
            .ThenBy(point => point.Addr)
            .ToArray();

        ScaleGroupView[] groups = points
            .GroupBy(point => point.Scale)
            .OrderByDescending(group => group.Key)
            .Select(group => new ScaleGroupView
            {
                Scale = group.Key,
                ScaleText = ConvertScaleText(group.Key),
                Prefs = group.GroupBy(point => point.Pref)
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

        return new QuakeView
        {
            Id = $"p2p-quake-{receivedAt:yyyyMMddHHmmssfff}",
            InformationType = value.InformationType.ToString(),
            InformationTitle = GetEarthquakeInformationTitle(value.InformationType),
            Time = NormalizeOccurrenceTime(value.OccuredTime, receivedAt),
            IssueTime = FormatDateTime(receivedAt),
            Hypocenter = string.IsNullOrWhiteSpace(value.Destination) ? "調査中" : value.Destination,
            MaxScale = maxScale,
            MaxScaleText = ConvertScaleText(maxScale),
            IkunoScale = ikunoScale,
            IkunoScaleText = ConvertScaleText(ikunoScale),
            Magnitude = value.Magnitude,
            Depth = NormalizeDepth(value.Depth),
            Tsunami = ConvertTsunamiType(value.TsunamiType),
            Latitude = ParseCoordinate(value.Latitude),
            Longitude = ParseCoordinate(value.Longitude),
            Points = points,
            ScaleGroups = groups,
        };
    }

    private static string GetEarthquakeInformationTitle(QuakeInformationType informationType)
    {
        return informationType switch
        {
            QuakeInformationType.ScalePrompt => "震度速報",
            QuakeInformationType.Destination => "震源速報",
            QuakeInformationType.ScaleAndDestination => "震源・震度情報",
            QuakeInformationType.Detail => "各地点の震度",
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
        StartDisasterAudio("Tsunami", false, value.IsCancelled, Array.Empty<string>());
        if (!value.IsCancelled)
        {
            QueueTsunamiMap(receivedAt);
        }
    }

    private static double? ParseCoordinate(string value)
    {
        return double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out double coordinate)
            ? coordinate
            : null;
    }

    private static void QueueEewMap(string? eventId)
    {
        if (string.IsNullOrWhiteSpace(eventId))
        {
            return;
        }

        TrackMapRender(Task.Run(() =>
        {
            try
            {
                EewView? snapshot;
                lock (StateLock)
                {
                    snapshot = eew?.Id == eventId ? eew : null;
                }
                if (snapshot is null)
                {
                    return;
                }

                var points = snapshot.Areas
                    .Select(area => area.KindCode)
                    .Where(code => EEWAreas.Instance.ContainsKey(code))
                    .Distinct(StringComparer.Ordinal)
                    .Select(code => new EEWPoint(code))
                    .ToList();
                string mapImage = RenderDisasterMap(
                    $"eew_{SanitizeFileName(eventId)}.png",
                    new MapDrawer
                    {
                        MapType = MapType.JAPAN_1024,
                        Trim = points.Count > 0,
                        PreferedAspectRatio = 1.2,
                        EEWPoints = points,
                    }
                );

                lock (StateLock)
                {
                    if (eew?.Id != eventId)
                    {
                        return;
                    }
                    eew.MapImage = mapImage;
                    WriteStateLocked(force: true);
                }
            }
            catch (Exception exception)
            {
                WriteEventLog($"緊急地震速報の地図生成に失敗しました: {exception.Message}");
            }
        }));
    }

    private static void QueueEarthquakeMap(string eventId)
    {
        TrackMapRender(Task.Run(() =>
        {
            try
            {
                QuakeView? snapshot;
                lock (StateLock)
                {
                    snapshot = earthquake?.Id == eventId ? earthquake : null;
                }
                if (snapshot is null)
                {
                    return;
                }

                // Keep every observation in the textual report, but only pass
                // points known to the bundled map database to the map renderer.
                // An unknown test location otherwise leaves the trim bounds empty.
                var observations = snapshot.Points
                    .Where(point => Stations.Instance.GetPoint(point.Addr, point.Pref) is not null)
                    .Select(point => new ObservationPoint(point.Pref, point.Addr, point.Scale))
                    .ToList();
                GeoCoordinate? hypocenter = snapshot.Latitude.HasValue && snapshot.Longitude.HasValue
                    ? new GeoCoordinate(snapshot.Latitude.Value, snapshot.Longitude.Value)
                    : null;
                string mapImage = RenderDisasterMap(
                    $"earthquake_{SanitizeFileName(eventId)}.png",
                    new MapDrawer
                    {
                        MapType = MapType.JAPAN_1024,
                        Trim = observations.Count > 0 || hypocenter is not null,
                        PreferedAspectRatio = 1.2,
                        Hypocenter = hypocenter,
                        ObservationPoints = observations,
                    }
                );

                lock (StateLock)
                {
                    if (earthquake?.Id != eventId)
                    {
                        return;
                    }
                    earthquake.MapImage = mapImage;
                    WriteStateLocked(force: true);
                }
            }
            catch (Exception exception)
            {
                WriteEventLog($"地震情報の地図生成に失敗しました: {exception.Message}");
            }
        }));
    }

    private static void QueueTsunamiMap(DateTime receivedAt)
    {
        string issueTime = FormatDateTime(receivedAt);
        TrackMapRender(Task.Run(() =>
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
                    return;
                }

                var points = snapshot.Areas
                    .Where(area => TsunamiAreas.Instance.GetArea(area.Name) is not null)
                    .Select(area => new TsunamiPoint(area.Name, ConvertMapTsunamiCategory(area.Grade)))
                    .ToList();
                string mapImage = RenderDisasterMap(
                    $"tsunami_{receivedAt:yyyyMMddHHmmssfff}.png",
                    new MapDrawer
                    {
                        MapType = MapType.JAPAN_1024,
                        Trim = points.Count > 0,
                        PreferedAspectRatio = 1.2,
                        TsunamiPoints = points,
                    }
                );

                lock (StateLock)
                {
                    if (!tsunami.Active || tsunami.IssueTime != issueTime)
                    {
                        return;
                    }
                    tsunami = tsunami with { MapImage = mapImage };
                    WriteStateLocked(force: true);
                }
            }
            catch (Exception exception)
            {
                WriteEventLog($"津波情報の地図生成に失敗しました: {exception.Message}");
            }
        }));
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
        return new TsunamiAreaView
        {
            Name = value.Region,
            Grade = value.Category switch
            {
                Client.Peer.TsunamiCategory.MajorWarning => "大津波警報",
                Client.Peer.TsunamiCategory.Warning => "津波警報",
                Client.Peer.TsunamiCategory.Advisory => "津波注意報",
                _ => "津波情報",
            },
            Immediate = value.IsImmediately,
            MaxHeight = "不明",
            FirstHeight = value.IsImmediately ? "直ちに来襲" : "調査中",
        };
    }

    private static void ExpireOldInformation()
    {
        lock (StateLock)
        {
            DateTime now = DateTime.Now;
            bool changed = false;
            changed |= ClearExpired(ref eew, ref eewExpiresAt, now);
            changed |= ClearExpired(ref earthquake, ref earthquakeExpiresAt, now);
            if (changed)
            {
                earthquakePriorityUntil = earthquake is null ? null : earthquakePriorityUntil;
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
        int scale = 0)
    {
        try
        {
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

            Process? process = Process.Start(startInfo);
            WriteEventLog($"災害通知音プロセスを開始しました: mode={mode}, pid={process?.Id ?? 0}");
        }
        catch (Exception exception)
        {
            WriteEventLog($"災害通知音を開始できませんでした: {exception.Message}");
        }
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
        bool earthquakePriority = earthquake is not null && earthquakePriorityUntil.HasValue && now <= earthquakePriorityUntil.Value;
        bool disasterPriority = eew is not null || tsunamiPriority || earthquakePriority;

        string[] reasons = new[]
        {
            eew is not null ? "eew" : "",
            tsunamiPriority ? "tsunami" : "",
            earthquakePriority ? "earthquake" : "",
        }.Where(reason => reason.Length > 0).ToArray();

        var corePayload = new
        {
            Eew = eew,
            Earthquake = earthquake,
            EmergencyEarthquake = earthquakePriority ? earthquake : null,
            RecentScale3Earthquake = earthquake,
            Tsunami = tsunami,
            EmergencyMode = new
            {
                Active = disasterPriority,
                Reason = string.Join(",", reasons),
                Until = LatestDate(eewExpiresAt, earthquakePriorityUntil, tsunamiPriorityUntil),
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
            corePayload.Earthquake,
            corePayload.EmergencyEarthquake,
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
        string monthQualifiedValue = $"{fallback:yyyy/MM}/{value}";
        if (DateTime.TryParseExact(
            monthQualifiedValue,
            "yyyy/MM/d日HH時mm分",
            CultureInfo.GetCultureInfo("ja-JP"),
            DateTimeStyles.AssumeLocal,
            out DateTime protocolTime
        ))
        {
            // 月初に前月末の地震情報を受信する場合を補正する。
            if (protocolTime > fallback.AddHours(1))
            {
                protocolTime = protocolTime.AddMonths(-1);
            }

            return FormatDateTime(protocolTime);
        }

        if (DateTime.TryParse(value, CultureInfo.GetCultureInfo("ja-JP"), DateTimeStyles.AssumeLocal, out DateTime parsed))
        {
            return FormatDateTime(parsed);
        }

        return FormatDateTime(fallback);
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
            _ => 0,
        };
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
    public string? MapImage { get; set; }
}

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
    public int Scale { get; init; }
    public string ScaleText { get; init; } = "";
}

internal sealed class ScaleGroupView
{
    public int Scale { get; init; }
    public string ScaleText { get; init; } = "";
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
    public QuakeView? Earthquake { get; init; }
    public TsunamiView? Tsunami { get; init; }
}

internal sealed class TestCommand
{
    public string Id { get; init; } = "";
    public string Kind { get; init; } = "";
    public string Scale { get; init; } = "";
    public string Hypocenter { get; init; } = "";
    public string[] EewAreas { get; init; } = Array.Empty<string>();
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
