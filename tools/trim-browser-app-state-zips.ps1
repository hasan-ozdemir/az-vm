$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression.FileSystem

$targets = @(
    'windows/update/app-states/02-check-install-chrome/app-state.zip',
    'windows/update/app-states/111-install-edge-browser/app-state.zip'
)

foreach ($target in $targets) {
    $resolvedZipPath = (Resolve-Path $target).Path
    $workBase = 'C:\azvtrim'
    if (-not (Test-Path -LiteralPath $workBase)) {
        New-Item -ItemType Directory -Path $workBase -Force | Out-Null
    }
    $workRoot = Join-Path $workBase ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $extractRoot = Join-Path $workRoot 'extract'
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null

    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($resolvedZipPath, $extractRoot)

        $manifestPath = Join-Path $extractRoot 'app-state.manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.profileDirectories = @()
        $manifest.registryImports = @()

        $profileDirectoriesRoot = Join-Path $extractRoot 'payload/profile-directories'
        if (Test-Path -LiteralPath $profileDirectoriesRoot) {
            Remove-Item -LiteralPath $profileDirectoriesRoot -Recurse -Force
        }
        $registryRoot = Join-Path $extractRoot 'payload/registry'
        if (Test-Path -LiteralPath $registryRoot) {
            Remove-Item -LiteralPath $registryRoot -Recurse -Force
        }

        $manifestJson = $manifest | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($manifestPath, $manifestJson, [System.Text.UTF8Encoding]::new($false))

        $rebuiltZipPath = Join-Path $workRoot 'rebuilt.zip'
        if (Test-Path -LiteralPath $rebuiltZipPath) {
            Remove-Item -LiteralPath $rebuiltZipPath -Force
        }

        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $extractRoot,
            $rebuiltZipPath,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $false
        )

        Copy-Item -LiteralPath $rebuiltZipPath -Destination $resolvedZipPath -Force
        $updatedFile = Get-Item -LiteralPath $resolvedZipPath
        Write-Host ("Trimmed browser app-state zip: {0} ({1} bytes)" -f $updatedFile.FullName, [int64]$updatedFile.Length)
    }
    finally {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
