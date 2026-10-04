param(
    [ValidateSet("Eew", "Earthquake", "Tsunami")]
    [string]$Mode,
    [int]$Scale = 0,
    [switch]$FollowUp,
    [switch]$Cancelled,
    [string]$AreaCodes = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$projectDir = Split-Path -Path $PSScriptRoot -Parent
$p2pAudioDir = Join-Path $PSScriptRoot "WpfClient\Resources\Sounds"
$eewVoiceDir = Join-Path $p2pAudioDir "EEW"
$priorityPath = Join-Path $projectDir "temp\eew_audio_priority.lock"
$logDir = Join-Path $projectDir "logs"
$logPath = Join-Path $logDir "disaster_audio.log"
$audioMutex = [Threading.Mutex]::new($false, "Global\InfomationSystemDisasterAudio")
$parsedAreaCodes = @(
    $AreaCodes -split "," |
        Where-Object { $_ -match "^\d+$" } |
        ForEach-Object { [int]$_ }
)
Add-Type -AssemblyName PresentationCore

function Write-DisasterAudioLog {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    $line = "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss.fff') [$Level] $Message"
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Play-DisasterSound {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-DisasterAudioLog -Level "ERROR" -Message "音源ファイルがありません: $Path"
        return $false
    }

    $player = $null
    try {
        $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        $player = [Windows.Media.MediaPlayer]::new()
        $player.Open([Uri]$resolvedPath)
        $player.Volume = 1.0
        $player.Play()

        $loadDeadline = (Get-Date).AddSeconds(5)
        while (-not $player.NaturalDuration.HasTimeSpan) {
            if ((Get-Date) -ge $loadDeadline) {
                throw "音源の読み込みが5秒以内に完了しませんでした。"
            }
            Start-Sleep -Milliseconds 30
        }

        $duration = [int]$player.NaturalDuration.TimeSpan.TotalMilliseconds
        $playbackDeadline = (Get-Date).AddMilliseconds($duration + 5000)
        while ($player.Position.TotalMilliseconds -lt ($duration - 20)) {
            if ((Get-Date) -ge $playbackDeadline) {
                throw "音源の再生が規定時間内に完了しませんでした。"
            }
            Start-Sleep -Milliseconds 50
        }

        Write-DisasterAudioLog -Message "音源を再生しました: $resolvedPath"
        return $true
    }
    catch {
        Write-DisasterAudioLog -Level "ERROR" -Message "音源再生に失敗しました: $Path / $($_.Exception.Message)"
        return $false
    }
    finally {
        if ($player) {
            try { $player.Stop() } catch {}
            try { $player.Close() } catch {}
        }
        Start-Sleep -Milliseconds 80
    }
}

function Play-EewVoiceSequence {
    $announcementName = if ($FollowUp) { "eew_followup.mp3" } else { "eew.mp3" }
    $sequence = @($announcementName, "announce_areas.mp3")
    $sequence += @($parsedAreaCodes | ForEach-Object { "$_.mp3" })
    $sequence += @($announcementName, "announce_areas.mp3")
    $sequence += @($parsedAreaCodes | ForEach-Object { "$_.mp3" })
    $sequence += "guidance.mp3"

    foreach ($fileName in $sequence) {
        [void](Play-DisasterSound -Path (Join-Path $eewVoiceDir $fileName))
    }
}

function Play-EewAudio {
    if ($Cancelled) {
        [void](Play-DisasterSound -Path (Join-Path $eewVoiceDir "eew_cancelled.mp3"))
        return
    }

    # P2P地震情報クライアントと同じ警報音と読み上げ素材を同じ順番で再生する。
    [void](Play-DisasterSound -Path (Join-Path $p2pAudioDir "EEW_Beta.mp3"))
    Play-EewVoiceSequence
}

function Play-EarthquakeAudio {
    $soundName = if ($Scale -ge 55) {
        "P2PQ_Snd4.mp3"
    }
    elseif ($Scale -ge 45) {
        "P2PQ_Snd3.mp3"
    }
    else {
        "P2PQ_Snd2.mp3"
    }
    [void](Play-DisasterSound -Path (Join-Path $p2pAudioDir $soundName))
}

function Play-TsunamiAudio {
    [void](Play-DisasterSound -Path (Join-Path $p2pAudioDir "P2PQ_Sndt.mp3"))
}

$hasMutex = $false
try {
    $hasMutex = $audioMutex.WaitOne([TimeSpan]::FromSeconds(60))
    if (-not $hasMutex) {
        throw "先行する災害通知音が60秒以内に終了しませんでした。"
    }

    [IO.File]::WriteAllText(
        $priorityPath,
        (Get-Date).AddMinutes(5).ToString("o"),
        [Text.UTF8Encoding]::new($false)
    )
    Write-DisasterAudioLog -Message "災害通知音を開始します: mode=$Mode scale=$Scale followUp=$FollowUp cancelled=$Cancelled areas=$($parsedAreaCodes -join ',')"
    switch ($Mode) {
        "Eew" { Play-EewAudio }
        "Earthquake" { Play-EarthquakeAudio }
        "Tsunami" { Play-TsunamiAudio }
    }
    Write-DisasterAudioLog -Message "災害通知音を完了しました: mode=$Mode"
}
catch {
    Write-DisasterAudioLog -Level "ERROR" -Message "災害通知音処理に失敗しました: mode=$Mode / $($_.Exception.Message)"
    exit 1
}
finally {
    Remove-Item -LiteralPath $priorityPath -Force -ErrorAction SilentlyContinue
    if ($hasMutex) { [void]$audioMutex.ReleaseMutex() }
    $audioMutex.Dispose()
}
