param(
  [Parameter(Mandatory = $true)]
  [string]$Server,

  [Parameter(Mandatory = $false)]
  [string]$User = "root",

  [Parameter(Mandatory = $false)]
  [int]$Port = 22,

  [Parameter(Mandatory = $false)]
  [string]$SshKeyPath,

  [Parameter(Mandatory = $false)]
  [string]$Container,

  [Parameter(Mandatory = $false)]
  [string]$ContainerBackupPath = "/var/opt/mssql/backup",

  [Parameter(Mandatory = $false)]
  [string]$BackupFileName,

  [Parameter(Mandatory = $false)]
  [string]$LocalOutputPath,

  [Parameter(Mandatory = $false)]
  [switch]$DownloadAll,

  [Parameter(Mandatory = $false)]
  [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $LocalOutputPath) {
  $LocalOutputPath = Join-Path -Path $PSScriptRoot -ChildPath "Data\DownloadedBackups"
}

function Quote-BashSingle {
  param([Parameter(Mandatory = $true)][string]$Value)
  return "'" + ($Value -replace "'", "'""'""'") + "'"
}

function New-SshTarget {
  param(
    [Parameter(Mandatory = $true)][string]$UserName,
    [Parameter(Mandatory = $true)][string]$HostName
  )
  return "$UserName@$HostName"
}

function Invoke-Ssh {
  param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$CommandText,
    [Parameter(Mandatory = $false)][int]$PortNumber = 22,
    [Parameter(Mandatory = $false)][string]$IdentityFile
  )

  $args = New-Object System.Collections.Generic.List[string]
  $args.Add("-p"); $args.Add("$PortNumber")
  $args.Add("-o"); $args.Add("BatchMode=yes")
  $args.Add("-o"); $args.Add("StrictHostKeyChecking=accept-new")
  if ($IdentityFile) {
    $args.Add("-i"); $args.Add($IdentityFile)
  }
  $args.Add($Target)
  $args.Add($CommandText)

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "ssh"
  $psi.Arguments = ($args | ForEach-Object { if ($_ -match "\s") { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join " "
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  if ($p.ExitCode -ne 0) {
    $msg = "ssh $($psi.Arguments)`n$stderr"
    throw $msg
  }
  return $stdout
}

function Invoke-ScpDownload {
  param(
    [Parameter(Mandatory = $true)][string]$RemoteTarget,
    [Parameter(Mandatory = $true)][string]$RemotePath,
    [Parameter(Mandatory = $true)][string]$LocalPath,
    [Parameter(Mandatory = $false)][int]$PortNumber = 22,
    [Parameter(Mandatory = $false)][string]$IdentityFile
  )

  $args = New-Object System.Collections.Generic.List[string]
  $args.Add("-P"); $args.Add("$PortNumber")
  $args.Add("-o"); $args.Add("BatchMode=yes")
  $args.Add("-o"); $args.Add("StrictHostKeyChecking=accept-new")
  if ($IdentityFile) {
    $args.Add("-i"); $args.Add($IdentityFile)
  }
  $args.Add("--")
  $args.Add("$RemoteTarget`:$RemotePath")
  $args.Add($LocalPath)

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "scp"
  $psi.Arguments = ($args | ForEach-Object { if ($_ -match "\s") { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join " "
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  if ($p.ExitCode -ne 0) {
    $msg = "scp $($psi.Arguments)`n$stderr"
    throw $msg
  }
  return $stdout
}

function Get-RemoteContainerNames {
  param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][int]$PortNumber,
    [Parameter(Mandatory = $false)][string]$IdentityFile
  )

  $cmd = "docker ps --format {{.Names}}"
  $out = Invoke-Ssh -Target $Target -CommandText $cmd -PortNumber $PortNumber -IdentityFile $IdentityFile
  return ($out -split "(`r`n|`n|`r)" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-LatestBackupPathInContainer {
  param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][int]$PortNumber,
    [Parameter(Mandatory = $false)][string]$IdentityFile,
    [Parameter(Mandatory = $true)][string]$ContainerName,
    [Parameter(Mandatory = $true)][string]$BackupDir
  )

  $dirQ = Quote-BashSingle -Value $BackupDir
  $containerQ = Quote-BashSingle -Value $ContainerName
  $remote = "docker exec $containerQ bash -lc ""ls -1t $dirQ/*.bak 2>/dev/null | head -n 1"""
  $out = Invoke-Ssh -Target $Target -CommandText $remote -PortNumber $PortNumber -IdentityFile $IdentityFile
  $line = ($out -split "(`r`n|`n|`r)" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 1)
  return $line
}

function Get-AllBackupPathsInContainer {
  param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][int]$PortNumber,
    [Parameter(Mandatory = $false)][string]$IdentityFile,
    [Parameter(Mandatory = $true)][string]$ContainerName,
    [Parameter(Mandatory = $true)][string]$BackupDir
  )

  $dirQ = Quote-BashSingle -Value $BackupDir
  $containerQ = Quote-BashSingle -Value $ContainerName
  $remote = "docker exec $containerQ bash -lc ""ls -1t $dirQ/*.bak 2>/dev/null || true"""
  $out = Invoke-Ssh -Target $Target -CommandText $remote -PortNumber $PortNumber -IdentityFile $IdentityFile
  return ($out -split "(`r`n|`n|`r)" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Stage-BackupToRemoteTemp {
  param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][int]$PortNumber,
    [Parameter(Mandatory = $false)][string]$IdentityFile,
    [Parameter(Mandatory = $true)][string]$ContainerName,
    [Parameter(Mandatory = $true)][string]$BakPathInContainer
  )

  $fileName = [IO.Path]::GetFileName($BakPathInContainer)
  if (-not $fileName) { throw "Could not determine file name for '$BakPathInContainer'." }

  $src = "$ContainerName`:$BakPathInContainer"
  $srcQ = Quote-BashSingle -Value $src
  $fileNameQ = Quote-BashSingle -Value $fileName

  $cmd = "set -e; fileName=$fileNameQ; tmpDir=`$(mktemp -d); dst=""`$tmpDir/`$fileName""; docker cp $srcQ ""`$dst""; echo ""`$dst"""
  $out = Invoke-Ssh -Target $Target -CommandText $cmd -PortNumber $PortNumber -IdentityFile $IdentityFile
  $remoteTmpFile = ($out -split "(`r`n|`n|`r)" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 1)
  if (-not $remoteTmpFile) { throw "Failed to stage '$BakPathInContainer' from '$ContainerName'." }

  $remoteTmpDir = $null
  $lastSlash = $remoteTmpFile.LastIndexOf("/")
  if ($lastSlash -gt 0) {
    $remoteTmpDir = $remoteTmpFile.Substring(0, $lastSlash)
  }

  return [pscustomobject]@{
    RemoteTempFile = $remoteTmpFile
    RemoteTempDir  = $remoteTmpDir
    FileName       = $fileName
  }
}

function Remove-RemoteTempDir {
  param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][int]$PortNumber,
    [Parameter(Mandatory = $false)][string]$IdentityFile,
    [Parameter(Mandatory = $true)][string]$RemoteDir
  )
  $dirQ = Quote-BashSingle -Value $RemoteDir
  Invoke-Ssh -Target $Target -CommandText "rm -rf $dirQ" -PortNumber $PortNumber -IdentityFile $IdentityFile | Out-Null
}

function Ensure-LocalDirectory {
  param([Parameter(Mandatory = $true)][string]$PathValue)
  if (-not (Test-Path -LiteralPath $PathValue)) {
    New-Item -ItemType Directory -Path $PathValue | Out-Null
  }
}

$sshTarget = New-SshTarget -UserName $User -HostName $Server

if ($WhatIf) {
  if (-not $Container) { $Container = "<container>" }
  if (-not $BackupFileName) { $BackupFileName = "<backup.bak>" }
  $bakInContainer = "$ContainerBackupPath/$BackupFileName"
  Write-Host "WhatIf: ssh $sshTarget docker exec $Container bash -lc `"ls -1t '$ContainerBackupPath'/*.bak | head -n 1`""
  Write-Host "WhatIf: ssh $sshTarget docker cp $Container`:$bakInContainer /tmp/$BackupFileName"
  Write-Host "WhatIf: scp $sshTarget`:/tmp/$BackupFileName `"$LocalOutputPath\$BackupFileName`""
  exit 0
}

Ensure-LocalDirectory -PathValue $LocalOutputPath

Invoke-Ssh -Target $sshTarget -CommandText "command -v docker >/dev/null 2>&1" -PortNumber $Port -IdentityFile $SshKeyPath | Out-Null

$containers = @()
if ($Container) {
  $containers = @($Container)
  Invoke-Ssh -Target $sshTarget -CommandText ("docker inspect " + (Quote-BashSingle -Value $Container) + " >/dev/null 2>&1") -PortNumber $Port -IdentityFile $SshKeyPath | Out-Null
} else {
  $containers = @(Get-RemoteContainerNames -Target $sshTarget -PortNumber $Port -IdentityFile $SshKeyPath)
}

if (-not $containers -or $containers.Count -eq 0) {
  throw "No running containers found on '$Server'."
}

$downloadQueue = New-Object System.Collections.Generic.List[object]

if ($BackupFileName) {
  if (-not $Container) { throw "When using -BackupFileName you must also pass -Container." }
  $downloadQueue.Add([pscustomobject]@{
    Container = $Container
    BakPath   = "$ContainerBackupPath/$BackupFileName"
  })
} else {
  foreach ($c in $containers) {
    if ($DownloadAll) {
      $paths = @(Get-AllBackupPathsInContainer -Target $sshTarget -PortNumber $Port -IdentityFile $SshKeyPath -ContainerName $c -BackupDir $ContainerBackupPath)
      foreach ($p in $paths) {
        $downloadQueue.Add([pscustomobject]@{ Container = $c; BakPath = $p })
      }
    } else {
      $p = Get-LatestBackupPathInContainer -Target $sshTarget -PortNumber $Port -IdentityFile $SshKeyPath -ContainerName $c -BackupDir $ContainerBackupPath
      if ($p) {
        $downloadQueue.Add([pscustomobject]@{ Container = $c; BakPath = $p })
      }
    }
  }
}

if ($downloadQueue.Count -eq 0) {
  throw "No .bak files found in '$ContainerBackupPath' on server '$Server'."
}

foreach ($item in $downloadQueue) {
  $containerName = $item.Container
  $bakPathInContainer = $item.BakPath

  Write-Host "Downloading '$bakPathInContainer' from container '$containerName'..."
  $stage = Stage-BackupToRemoteTemp -Target $sshTarget -PortNumber $Port -IdentityFile $SshKeyPath -ContainerName $containerName -BakPathInContainer $bakPathInContainer

  try {
    $localFile = Join-Path -Path $LocalOutputPath -ChildPath $stage.FileName
    Invoke-ScpDownload -RemoteTarget $sshTarget -RemotePath $stage.RemoteTempFile -LocalPath $localFile -PortNumber $Port -IdentityFile $SshKeyPath | Out-Null
    Write-Host "  Saved: $localFile"
  } finally {
    if ($stage.RemoteTempDir) {
      Remove-RemoteTempDir -Target $sshTarget -PortNumber $Port -IdentityFile $SshKeyPath -RemoteDir $stage.RemoteTempDir
    }
  }
}
