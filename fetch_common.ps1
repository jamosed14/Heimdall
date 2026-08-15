# Shared data-integrity library, dot-sourced by every fetch_*.ps1 script. This is a deliberate
# exception to Heimdall's usual "each fetch script is self-contained" convention - duplicating
# validate/merge/atomic-write logic five times would be a bigger risk than one shared file.
#
# Guidelines this exists to enforce (see conversation/commit history for the full brief):
#   - Fail stale, not broken: a bad/empty/malformed fetch keeps the last known-good cache.
#   - Validate before overwrite: schema/count/date/numeric checks on every series.
#   - Write atomically: temp file -> validate -> rename, never a half-written production file.
#   - Preserve history: merge new observations into the existing series by date, don't rebuild
#     from a single API response (a truncated response can't silently shrink history).
#   - Treat "no new data" as success: merging is a no-op when nothing changed, not a failure.
#   - Track freshness explicitly: lastObservation / lastSuccessfulRefresh / sourceStatus.
#   - Never coerce missing data to zero: every helper below treats $null/NaN as "invalid", not 0.

# ===================== Validation =====================

# Sanity-checks a raw {Date;Value} series before it's trusted: non-empty, meets a minimum
# expected count, every value is a real (non-null, non-NaN) number, every date parses, and
# there are no duplicate dates. Returns $true/$false; logs a loud ::error:: line on failure so
# CI surfaces it even though the script continues (source isolation - one bad series doesn't
# take down the whole payload).
function Test-SeriesSane {
    param($Series, [int]$MinCount = 1, [string]$Name = "series")
    if ($null -eq $Series -or $Series.Count -eq 0) {
        Write-Host ("::error::{0}: empty or null series" -f $Name)
        return $false
    }
    if ($Series.Count -lt $MinCount) {
        Write-Host ("::error::{0}: only {1} observations, expected at least {2}" -f $Name, $Series.Count, $MinCount)
        return $false
    }
    $seenDates = @{}
    foreach ($p in $Series) {
        if ($null -eq $p.Value -or ($p.Value -is [double] -and [double]::IsNaN($p.Value))) {
            Write-Host ("::error::{0}: null/NaN value at date {1}" -f $Name, $p.Date)
            return $false
        }
        $parsed = [DateTime]::MinValue
        if ([string]::IsNullOrWhiteSpace($p.Date) -or -not [DateTime]::TryParse($p.Date, [ref]$parsed)) {
            Write-Host ("::error::{0}: unparseable date '{1}'" -f $Name, $p.Date)
            return $false
        }
        if ($seenDates.ContainsKey($p.Date)) {
            Write-Host ("::error::{0}: duplicate date {1}" -f $Name, $p.Date)
            return $false
        }
        $seenDates[$p.Date] = $true
    }
    return $true
}

# ===================== Merge (preserve history) =====================

# Unions existing and fresh series by date - fresh values win on overlapping dates (APIs revise
# recent prints), dates only in $Existing are kept (protects against a truncated fresh response
# silently shrinking history), sorted ascending. A no-op merge (fresh == existing) is expected
# and correct on weekends/holidays/between-release days, not a failure.
function Merge-SeriesByDate {
    param($Existing, $Fresh)
    $map = @{}
    foreach ($p in $Existing) { if ($p.Date) { $map[$p.Date] = $p.Value } }
    foreach ($p in $Fresh) { if ($p.Date) { $map[$p.Date] = $p.Value } }
    $merged = foreach ($k in $map.Keys) { [PSCustomObject]@{ Date = $k; Value = $map[$k] } }
    return , ($merged | Sort-Object Date)
}

# Fetches+validates a series, falling back to the existing cached series (marked "stale") if the
# fresh one fails validation, and to an empty series + loud error (marked "error") only if
# there's no existing data to fall back to either (first-ever run with a bad source). This is
# the central "fail stale, not broken" decision point - call it for every raw series a fetch
# script pulls, before computing anything derived from it.
function Get-ValidatedMergedSeries {
    param($Fresh, $Existing, [int]$MinCount = 1, [string]$Name = "series")
    if (Test-SeriesSane -Series $Fresh -MinCount $MinCount -Name $Name) {
        $merged = if ($Existing -and $Existing.Count -gt 0) { Merge-SeriesByDate -Existing $Existing -Fresh $Fresh } else { $Fresh }
        return @{ series = $merged; status = "ok" }
    }
    if ($Existing -and $Existing.Count -gt 0) {
        Write-Host ("::warning::{0}: fresh fetch invalid, falling back to {1} cached observations" -f $Name, $Existing.Count)
        return @{ series = $Existing; status = "stale" }
    }
    Write-Host ("::error::{0}: fresh fetch invalid AND no existing cached data - this series will be empty, not zero-filled" -f $Name)
    return @{ series = @(); status = "error" }
}

# ===================== Read/write existing payloads =====================

# Reads and parses an existing data\X_data.js cache (window.X_DATA = {...};) back into a
# PSCustomObject, for merge purposes. Returns $null (not throw) if the file is missing or
# corrupt - a missing/corrupt existing file just means "nothing to merge/fall back to", it
# should never crash the fetch script itself.
function Get-ExistingPayload {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $raw = Get-Content $Path -Raw -Encoding UTF8
        $raw = $raw.TrimStart([char]0xFEFF)
        $eqIdx = $raw.IndexOf("=")
        if ($eqIdx -lt 0) { return $null }
        $jsonPart = $raw.Substring($eqIdx + 1).Trim()
        if ($jsonPart.EndsWith(";")) { $jsonPart = $jsonPart.Substring(0, $jsonPart.Length - 1) }
        # -Depth isn't supported by ConvertFrom-Json on Windows PowerShell 5.1 (only PS6+) -
        # omitted here so this works on both; PS5.1's default depth (100) is plenty for our data.
        return ($jsonPart | ConvertFrom-Json)
    } catch {
        Write-Host ("::warning::Could not parse existing payload at {0}: {1}" -f $Path, $_.Exception.Message)
        return $null
    }
}

# Converts an existing payload's output-shaped series ([{d;v}]) back into the {Date;Value}
# working shape used by Merge-SeriesByDate/Test-SeriesSane. $null-safe.
function ConvertFrom-SeriesJson {
    param($JsonSeries)
    if ($null -eq $JsonSeries) { return @() }
    return , ($JsonSeries | ForEach-Object { [PSCustomObject]@{ Date = $_.d; Value = [double]$_.v } })
}

# Writes a payload to a temp file, validates the temp file actually round-trips as parseable
# JSON, and only then replaces the production file. A crash/interruption mid-write leaves the
# temp file orphaned and the real file untouched - a page load can never see a half-written
# file. Throws (doesn't silently continue) if validation fails, so a caller's try/catch decides
# how to handle it rather than this function guessing.
function Write-DataFileAtomic {
    param([string]$Path, [string]$VarName, $Payload, [int]$Depth = 12)
    $json = $Payload | ConvertTo-Json -Depth $Depth -Compress
    $jsOut = "window.$VarName = $json;"
    $tmpPath = "$Path.tmp"
    Set-Content -Path $tmpPath -Value $jsOut -Encoding UTF8
    $verify = Get-ExistingPayload $tmpPath
    if ($null -eq $verify) {
        Remove-Item $tmpPath -ErrorAction SilentlyContinue
        throw "Atomic write validation failed for $Path - temp file did not parse back as valid JSON. Existing file left untouched."
    }
    Move-Item -Path $tmpPath -Destination $Path -Force
    Write-Output ("Wrote {0} (atomic, validated)" -f $Path)
}

