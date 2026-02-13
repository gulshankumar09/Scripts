# MSSQL Backup Restore (Local .bak → SQL Server in Docker)

This folder contains scripts to restore one or more SQL Server `.bak` backups into a SQL Server instance running inside a Docker container.

## Prerequisites

- Docker Desktop installed and running
- A running SQL Server container (default: `hostnsell-sqlserver`)
- `sqlcmd` available inside the container (`/opt/mssql-tools18/bin/sqlcmd` or `/opt/mssql-tools/bin/sqlcmd`)
- Your backups are `.bak` files on the host machine

## Restore latest backup per database

Script: `restore_mssql_backups_from_local_to_docker.ps1`

It scans `-HostBackupPath` for `.bak` files, groups them by database name using this filename pattern:

`DbName_yyyyMMdd_HHmmss.bak`

Then it restores only the latest `.bak` for each database.

### 1) Set SA password (recommended)

```powershell
$env:MSSQL_SA_PASSWORD = "<your_sa_password>"
```

You can also pass `-SaPassword`, but environment variables avoid leaking secrets into shell history.

### 2) Dry-run (prints what it would do)

```powershell
.\restore_mssql_backups_from_local_to_docker.ps1 `
  -HostBackupPath "d:\Scripts\Data\sqlserver_backups" `
  -WhatIf
```

### 3) Restore for real

```powershell
.\restore_mssql_backups_from_local_to_docker.ps1 `
  -HostBackupPath "d:\Scripts\Data\sqlserver_backups"
```

## Common options

Use a different container name:

```powershell
.\restore_mssql_backups_from_local_to_docker.ps1 `
  -HostBackupPath "d:\Scripts\Data\sqlserver_backups" `
  -Container "hostnsell-sqlserver"
```

Search backups recursively:

```powershell
.\restore_mssql_backups_from_local_to_docker.ps1 `
  -HostBackupPath "d:\Scripts\Data\sqlserver_backups" `
  -Recurse
```

Use the database name stored inside the backup header (instead of the filename):

```powershell
.\restore_mssql_backups_from_local_to_docker.ps1 `
  -HostBackupPath "d:\Scripts\Data\sqlserver_backups" `
  -UseBackupDatabaseName
```

Keep `.bak` files inside the container after restore:

```powershell
.\restore_mssql_backups_from_local_to_docker.ps1 `
  -HostBackupPath "d:\Scripts\Data\sqlserver_backups" `
  -KeepBackupInContainer
```

## Notes

- The script uses `RESTORE FILELISTONLY` to discover logical file names and generates `WITH MOVE` so restores work inside the container even if the original backup paths don’t exist there.
- If a database already exists, it is put into `SINGLE_USER` with rollback, restored with `REPLACE`, then set back to `MULTI_USER`.

## Troubleshooting

- `sqlcmd not found in container`: install mssql-tools inside the image/container, or use a SQL Server image that already includes it.
- `Login failed for user 'sa'`: ensure the SA password matches the container’s configured password.
- `RESTORE FILELISTONLY ... cannot open backup device`: make sure the `.bak` was copied into the container path shown in the output and the container can read it.
