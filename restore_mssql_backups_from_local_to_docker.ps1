param(
  [Parameter(Mandatory = $true)]
  [string]$HostBackupPath,

  [Parameter(Mandatory = $false)]
  [string]$Container = "hostnsell-sqlserver",

  [Parameter(Mandatory = $false)]
  [string]$ContainerBackupPath = "/var/opt/mssql/backup",

  [Parameter(Mandatory = $false)]
  [string]$DataPath = "/var/opt/mssql/data",

  [Parameter(Mandatory = $false)]
  [string]$SaPassword,

  [Parameter(Mandatory = $false)]
  [switch]$Recurse,

  [Parameter(Mandatory = $false)]
  [switch]$UseBackupDatabaseName,

  [Parameter(Mandatory = $false)]
  [switch]$KeepBackupInContainer,

  [Parameter(Mandatory = $false)]
  [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Docker {
  param(
    [Parameter(Mandatory = $true)][string[]]$Args
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "docker"
  $psi.Arguments = ($Args | ForEach-Object { if ($_ -match "\s") { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join " "
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
    $safeArgs = $psi.Arguments
    $safeArgs = [regex]::Replace($safeArgs, '(\s-P\s+)(".*?"|\S+)', '$1********')
    $msg = "docker $safeArgs`n$stderr"
    throw $msg
  }
  return $stdout
}

function Get-SaPassword {
  param([string]$ExplicitPassword)
  if ($ExplicitPassword) { return $ExplicitPassword }
  if ($env:MSSQL_SA_PASSWORD) { return $env:MSSQL_SA_PASSWORD }
  if ($env:SA_PASSWORD) { return $env:SA_PASSWORD }
  throw "SaPassword not provided. Pass -SaPassword or set MSSQL_SA_PASSWORD/SA_PASSWORD."
}

function Get-SqlCmdInContainer {
  param([string]$ContainerName)

  $candidates = @(
    "/opt/mssql-tools18/bin/sqlcmd",
    "/opt/mssql-tools/bin/sqlcmd"
  )

  foreach ($path in $candidates) {
    try {
      Invoke-Docker -Args @("exec", $ContainerName, "bash", "-lc", "test -x '$path'") | Out-Null
      return $path
    } catch {
    }
  }

  throw "sqlcmd not found in container '$ContainerName'. Expected /opt/mssql-tools18/bin/sqlcmd or /opt/mssql-tools/bin/sqlcmd."
}

function Invoke-SqlCmdInContainer {
  param(
    [Parameter(Mandatory = $true)][string]$ContainerName,
    [Parameter(Mandatory = $true)][string]$SqlCmdPath,
    [Parameter(Mandatory = $true)][string]$SaPasswordValue,
    [Parameter(Mandatory = $true)][string]$Query,
    [Parameter(Mandatory = $false)][string]$Separator = "|",
    [Parameter(Mandatory = $false)][switch]$TrustServerCertificate
  )

  $args = @("exec", $ContainerName, $SqlCmdPath)
  if ($TrustServerCertificate) {
    $args += "-C"
  }

  $args += @(
    "-S", "localhost",
    "-U", "sa",
    "-P", $SaPasswordValue,
    "-b",
    "-V", "16",
    "-W",
    "-s", $Separator,
    "-Q", $Query
  )

  return Invoke-Docker -Args $args
}

function Get-TableLines {
  param([Parameter(Mandatory = $true)][string]$SqlCmdOutput)

  $lines = $SqlCmdOutput -split "(`r`n|`n|`r)" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_.Trim().Length -gt 0 }
  $lines = $lines | Where-Object { $_ -like "*|*" }
  $lines = $lines | Where-Object { $_ -notmatch '^\s*-+(\s*\|\s*-+)+\s*$' }
  return $lines
}

function Get-BackupDatabaseName {
  param(
    [Parameter(Mandatory = $true)][string]$ContainerName,
    [Parameter(Mandatory = $true)][string]$SqlCmdPath,
    [Parameter(Mandatory = $true)][string]$SaPasswordValue,
    [Parameter(Mandatory = $true)][string]$BakPathInContainer,
    [Parameter(Mandatory = $true)][switch]$TrustServerCertificate
  )

  $q = "RESTORE HEADERONLY FROM DISK = N'$BakPathInContainer';"
  $out = Invoke-SqlCmdInContainer -ContainerName $ContainerName -SqlCmdPath $SqlCmdPath -SaPasswordValue $SaPasswordValue -Query $q -Separator "|" -TrustServerCertificate:$TrustServerCertificate

  $lines = Get-TableLines -SqlCmdOutput $out
  if ($lines.Count -lt 2) { throw "Unexpected RESTORE HEADERONLY output for '$BakPathInContainer'." }
  $header = $lines[0].Split("|")
  $data = $lines[1].Split("|")

  $dbNameIndex = [Array]::IndexOf($header, "DatabaseName")
  if ($dbNameIndex -lt 0) { throw "Could not find DatabaseName column in RESTORE HEADERONLY output." }
  $dbName = $data[$dbNameIndex].Trim()
  if (-not $dbName) { throw "Backup header had empty DatabaseName." }
  return $dbName
}

function Get-BackupFileList {
  param(
    [Parameter(Mandatory = $true)][string]$ContainerName,
    [Parameter(Mandatory = $true)][string]$SqlCmdPath,
    [Parameter(Mandatory = $true)][string]$SaPasswordValue,
    [Parameter(Mandatory = $true)][string]$BakPathInContainer,
    [Parameter(Mandatory = $true)][switch]$TrustServerCertificate
  )

  $q = "RESTORE FILELISTONLY FROM DISK = N'$BakPathInContainer';"
  $out = Invoke-SqlCmdInContainer -ContainerName $ContainerName -SqlCmdPath $SqlCmdPath -SaPasswordValue $SaPasswordValue -Query $q -Separator "|" -TrustServerCertificate:$TrustServerCertificate
  $lines = Get-TableLines -SqlCmdOutput $out
  if ($lines.Count -lt 2) { throw "Unexpected RESTORE FILELISTONLY output for '$BakPathInContainer'." }

  $columns = $lines[0].Split("|")
  $logicalIndex = [Array]::IndexOf($columns, "LogicalName")
  $typeIndex = [Array]::IndexOf($columns, "Type")

  if ($logicalIndex -lt 0 -or $typeIndex -lt 0) {
    throw "Could not find LogicalName/Type columns in RESTORE FILELISTONLY output."
  }

  $rows = @()
  foreach ($line in ($lines | Select-Object -Skip 1)) {
    $parts = $line.Split("|")
    if ($parts.Count -le [Math]::Max($logicalIndex, $typeIndex)) { continue }
    $rows += [pscustomobject]@{
      LogicalName = $parts[$logicalIndex].Trim()
      Type        = $parts[$typeIndex].Trim()
    }
  }

  if ($rows.Count -eq 0) { throw "No rows returned by RESTORE FILELISTONLY for '$BakPathInContainer'." }
  return $rows
}

function Parse-BackupFileName {
  param([Parameter(Mandatory = $true)][string]$FileName)

  $pattern = '^(?<db>.+)_(?<date>\d{8})_(?<time>\d{6})\.bak$'
  $m = [regex]::Match($FileName, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $m.Success) {
    return $null
  }

  $db = $m.Groups["db"].Value
  $date = $m.Groups["date"].Value
  $time = $m.Groups["time"].Value
  $dt = [datetime]::ParseExact("$date$time", "yyyyMMddHHmmss", [System.Globalization.CultureInfo]::InvariantCulture)

  return [pscustomobject]@{
    DatabaseName   = $db
    BackupDateTime = $dt
  }
}

function New-RestoreQuery {
  param(
    [Parameter(Mandatory = $true)][string]$DatabaseName,
    [Parameter(Mandatory = $true)][string]$BakPathInContainer,
    [Parameter(Mandatory = $true)][object[]]$FileListRows,
    [Parameter(Mandatory = $true)][string]$DataDirectory
  )

  $dbEsc = $DatabaseName.Replace("]", "]]")
  $moves = New-Object System.Collections.Generic.List[string]

  $dataFiles = @($FileListRows | Where-Object { $_.Type -eq "D" })
  $logFiles = @($FileListRows | Where-Object { $_.Type -eq "L" })

  $i = 0
  foreach ($f in $dataFiles) {
    $i++
    $suffix = if ($i -eq 1) { "" } else { "_$i" }
    $target = "$DataDirectory/$DatabaseName$suffix.mdf"
    $moves.Add("MOVE N'$($f.LogicalName.Replace("'", "''"))' TO N'$($target.Replace("'", "''"))'")
  }

  $j = 0
  foreach ($f in $logFiles) {
    $j++
    $suffix = if ($j -eq 1) { "" } else { "_$j" }
    $target = "$DataDirectory/$DatabaseName$suffix" + "_log.ldf"
    $moves.Add("MOVE N'$($f.LogicalName.Replace("'", "''"))' TO N'$($target.Replace("'", "''"))'")
  }

  if ($moves.Count -eq 0) { throw "No MOVE clauses were generated for '$BakPathInContainer'." }

  $moveSql = $moves -join ",`n  "

  $q = @"
IF DB_ID(N'$($DatabaseName.Replace("'", "''"))') IS NOT NULL
BEGIN
  ALTER DATABASE [$dbEsc] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
END
RESTORE DATABASE [$dbEsc]
FROM DISK = N'$($BakPathInContainer.Replace("'", "''"))'
WITH
  $moveSql,
  REPLACE,
  RECOVERY;
ALTER DATABASE [$dbEsc] SET MULTI_USER;
"@

  return $q
}

$SaPasswordValue = Get-SaPassword -ExplicitPassword $SaPassword

try {
  Invoke-Docker -Args @("inspect", $Container) | Out-Null
} catch {
  throw "Container '$Container' not found. Pass -Container with the container name."
}

$sqlcmdPath = Get-SqlCmdInContainer -ContainerName $Container

$trustServerCertificate = $false
if ($sqlcmdPath -like "*mssql-tools18*") {
  $trustServerCertificate = $true
}

Invoke-Docker -Args @("exec", $Container, "bash", "-lc", "mkdir -p '$ContainerBackupPath'") | Out-Null

$resolvedHostPath = (Resolve-Path -Path $HostBackupPath).Path
$gciArgs = @{
  Path   = $resolvedHostPath
  Filter = "*.bak"
}
if ($Recurse) {
  $gciArgs.Recurse = $true
}
$bakFiles = Get-ChildItem @gciArgs | Sort-Object FullName

if (-not $bakFiles -or $bakFiles.Count -eq 0) {
  throw "No .bak files found under '$resolvedHostPath'."
}

$backupCandidates = foreach ($bak in $bakFiles) {
  $parsed = Parse-BackupFileName -FileName $bak.Name
  if ($null -ne $parsed) {
    [pscustomobject]@{
      File           = $bak
      DatabaseName   = $parsed.DatabaseName
      BackupDateTime = $parsed.BackupDateTime
    }
  } else {
    [pscustomobject]@{
      File           = $bak
      DatabaseName   = [IO.Path]::GetFileNameWithoutExtension($bak.Name)
      BackupDateTime = $bak.LastWriteTime
    }
  }
}

$latestBackups = $backupCandidates |
  Group-Object -Property DatabaseName |
  ForEach-Object { $_.Group | Sort-Object BackupDateTime -Descending | Select-Object -First 1 } |
  Sort-Object DatabaseName

foreach ($candidate in $latestBackups) {
  $bak = $candidate.File
  $fileName = $bak.Name
  $bakInContainer = "$ContainerBackupPath/$fileName"

  Write-Host "Restoring '$($bak.FullName)'..."

  if ($WhatIf) {
    Write-Host "  WhatIf: docker cp `"$($bak.FullName)`" `"${Container}:$bakInContainer`""
    $dbName = $candidate.DatabaseName
    if ($UseBackupDatabaseName) {
      Write-Host "  WhatIf: read DatabaseName from backup header"
    }
    Write-Host "  WhatIf: RESTORE FILELISTONLY FROM DISK = N'$bakInContainer'"
    Write-Host "  WhatIf: RESTORE DATABASE [$dbName] FROM DISK = N'$bakInContainer' ..."
  } else {
    Invoke-Docker -Args @("cp", $bak.FullName, "${Container}:$bakInContainer") | Out-Null

    $dbName = $candidate.DatabaseName
    if ($UseBackupDatabaseName) {
      $dbName = Get-BackupDatabaseName -ContainerName $Container -SqlCmdPath $sqlcmdPath -SaPasswordValue $SaPasswordValue -BakPathInContainer $bakInContainer -TrustServerCertificate:$trustServerCertificate
    }

    $fileList = Get-BackupFileList -ContainerName $Container -SqlCmdPath $sqlcmdPath -SaPasswordValue $SaPasswordValue -BakPathInContainer $bakInContainer -TrustServerCertificate:$trustServerCertificate
    $restoreQuery = New-RestoreQuery -DatabaseName $dbName -BakPathInContainer $bakInContainer -FileListRows $fileList -DataDirectory $DataPath

    Invoke-SqlCmdInContainer -ContainerName $Container -SqlCmdPath $sqlcmdPath -SaPasswordValue $SaPasswordValue -Query $restoreQuery -TrustServerCertificate:$trustServerCertificate | Out-Null
  }

  if (-not $KeepBackupInContainer) {
    if ($WhatIf) {
      Write-Host "  WhatIf: rm -f '$bakInContainer'"
    } else {
      Invoke-Docker -Args @("exec", $Container, "bash", "-lc", "rm -f '$bakInContainer'") | Out-Null
    }
  }

  Write-Host "  Done: $dbName"
}

