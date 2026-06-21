param(
    [string] $RepoJsonPath = "repo.json",

    [string] $DownloadCountOffsetsPath = "download-count-offsets.json"
)

$ErrorActionPreference = "Stop"

function Get-GitHubRepoParts {
    param([string] $RepoUrl)

    if ($RepoUrl -notmatch "^https://github\.com/([^/]+)/([^/#?]+)") {
        return $null
    }

    return [pscustomobject]@{
        Owner = $Matches[1]
        Repo = $Matches[2] -replace "\.git$", ""
    }
}

function Get-AssetName {
    param([string] $DownloadLink)

    if ([string]::IsNullOrWhiteSpace($DownloadLink)) {
        return "latest.zip"
    }

    try {
        $uri = [Uri] $DownloadLink
        $assetName = $uri.Segments[-1]
        return [Uri]::UnescapeDataString($assetName)
    }
    catch {
        return "latest.zip"
    }
}

function Get-ReleaseAssetDownloadTotal {
    param(
        [string] $RepoUrl,
        [string] $DownloadLink
    )

    $repoParts = Get-GitHubRepoParts -RepoUrl $RepoUrl
    if ($null -eq $repoParts) {
        Write-Warning "Skipping non-GitHub repo URL: $RepoUrl"
        return $null
    }

    $assetName = Get-AssetName -DownloadLink $DownloadLink
    $headers = @{
        "Accept"               = "application/vnd.github+json"
        "User-Agent"           = "IMakeSillyThings-download-count-updater"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN"
    }

    $total = 0
    $page = 1
    while ($true) {
        $url = "https://api.github.com/repos/$($repoParts.Owner)/$($repoParts.Repo)/releases?per_page=100&page=$page"
        $releases = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
        if ($null -eq $releases -or $releases.Count -eq 0) {
            break
        }

        foreach ($release in @($releases)) {
            foreach ($asset in @($release.assets)) {
                if ($asset.name -eq $assetName) {
                    $total += [int] $asset.download_count
                }
            }
        }

        if ($releases.Count -lt 100) {
            break
        }

        $page++
    }

    return $total
}

function Get-DownloadCountOffsets {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{}
    }

    $json = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $offsets = @{}
    foreach ($property in @($json.PSObject.Properties)) {
        $offsets[$property.Name] = [int] $property.Value
    }

    return $offsets
}

$repoJsonFullPath = (Resolve-Path -LiteralPath $RepoJsonPath).Path
$offsetsFullPath = Join-Path (Split-Path -Parent $repoJsonFullPath) $DownloadCountOffsetsPath
$downloadCountOffsets = Get-DownloadCountOffsets -Path $offsetsFullPath
$plugins = Get-Content -Raw -LiteralPath $repoJsonFullPath | ConvertFrom-Json
$changed = $false

foreach ($plugin in @($plugins)) {
    $releaseCount = Get-ReleaseAssetDownloadTotal -RepoUrl $plugin.RepoUrl -DownloadLink $plugin.DownloadLinkInstall
    if ($null -eq $releaseCount) {
        continue
    }

    $offset = 0
    if ($downloadCountOffsets.ContainsKey($plugin.InternalName)) {
        $offset = $downloadCountOffsets[$plugin.InternalName]
    }

    $count = $releaseCount + $offset
    if ($null -eq $count) {
        continue
    }

    $downloadCountProperty = $plugin.PSObject.Properties["DownloadCount"]
    if ($null -eq $downloadCountProperty) {
        Write-Host "$($plugin.InternalName): DownloadCount missing -> $count"
        $plugin | Add-Member -NotePropertyName "DownloadCount" -NotePropertyValue $count
        $changed = $true
    }
    elseif ($plugin.DownloadCount -ne $count) {
        Write-Host "$($plugin.InternalName): DownloadCount $($plugin.DownloadCount) -> $count"
        $plugin.DownloadCount = $count
        $changed = $true
    }
    else {
        Write-Host "$($plugin.InternalName): DownloadCount already $count"
    }
}

if ($changed) {
    $json = ConvertTo-Json -InputObject @($plugins) -Depth 20
    [System.IO.File]::WriteAllText($repoJsonFullPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Updated $repoJsonFullPath"
}
else {
    Write-Host "No download count changes."
}
