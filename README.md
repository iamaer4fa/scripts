# Server and infrastructure scripts

This folder contains scripts for Linux, Windows, VMware ESXi, PostgreSQL,
BackupPC, and maintenance reporting. Some scripts can send uptime results to
NocoBase; the maintenance notification script can send a Telegram message.

## Keep credentials private

1. Copy `.env.example` to `.env`.
2. Fill in the values needed for the integrations you use.
3. Keep `.env` private. It is excluded from Git by `.gitignore`; commit
   `.env.example` instead.

Shell scripts load `.env` from this folder. PowerShell scripts also read it
from their own folder. `NOCOBASE_URL` and `NOCOBASE_TOKEN` are required by
scripts that call NocoBase. The token should be a NocoBase API token, supplied
as an `Authorization: Bearer ...` header.

Optional settings:

| Variable | Used by | Description |
| --- | --- | --- |
| `NOCOBASE_URL` | NocoBase-enabled scripts | Base URL of the NocoBase instance, without a trailing slash |
| `NOCOBASE_TOKEN` | NocoBase-enabled scripts | API token |
| `TELEGRAM_BOT_TOKEN` | `monthly-maintenance.sh` | Telegram bot token |
| `TELEGRAM_CHAT_ID` | `monthly-maintenance.sh` | Destination chat ID |
| `ESXI_HOSTS` | `vmware_esxi.sh` | Semicolon-separated `host\|username\|password` entries |

For example, `ESXI_HOSTS="esxi1.example|root|password1;esxi2.example|root|password2"`.
Avoid committing these values or sharing the populated `.env`.

## Scripts

| Script | Purpose |
| --- | --- |
| [`backup-postgresql.sh`](./backup-postgresql.sh) | Dumps the configured PostgreSQL databases, archives the backups, and removes archives older than the configured retention period. Uses the local PostgreSQL `.pgpass` file for authentication. |
| [`backup-postgresql.sh.bak`](./backup-postgresql.sh.bak) | Older PostgreSQL backup-script copy kept for reference; prefer `backup-postgresql.sh`. |
| [`backuppc_check_host_backup.pl`](./backuppc_check_host_backup.pl) | BackupPC-oriented Perl endpoint that accepts a host name or IP and returns host registration/backup information as JSON. |
| [`get-current-month-uptime.ps1`](./get-current-month-uptime.ps1) | Reports the current month-to-date Windows uptime from System event-log events, writes summary/detail CSV files, and optionally pushes the KPI to NocoBase. |
| [`get-uptime-server-year.ps1`](./get-uptime-server-year.ps1) | Reports Windows uptime by month for a selected calendar year, exports CSV files, and optionally pushes monthly KPIs to NocoBase. |
| [`monthly-maintenance.sh`](./monthly-maintenance.sh) | Sends a Telegram maintenance message with NVMe health/wear and pgBackRest verification status. |
| [`simple_uuid_query.sh`](./simple_uuid_query.sh) | Checks whether the local/default host name resolves to a NocoBase device UUID. |
| [`test_lookup.sh`](./test_lookup.sh) | Diagnoses NocoBase device lookup using a supplied host name, trying several possible field names and match styles. |
| [`test_uuid.sh`](./test_uuid.sh) | Tests NocoBase connectivity and tries common device fields to find a host UUID. Accepts an optional host name. |
| [`uptime-current-month.sh`](./uptime-current-month.sh) | Reports Linux uptime for the current month-to-date using `tuptime`, writes a CSV, and pushes the result to NocoBase. |
| [`uptime.sh`](./uptime.sh) | Produces a Linux monthly uptime report for the current calendar year using `tuptime` and can push monthly results to NocoBase. |
| [`uptime1.sh`](./uptime1.sh) | Alternate annual Linux uptime report; creates the CSV rows first and uses those rows to build the NocoBase KPI payloads. |
| [`vmware_esxi.sh`](./vmware_esxi.sh) | Connects to configured ESXi hosts over SSH, calculates current-month uptime from `esxcli`, writes a CSV report, and pushes rows to NocoBase. |

## Requirements

Install the tools required by the scripts you plan to run:

- Linux shell scripts: Bash and common utilities (`curl`, `jq`, `awk`, `sed`,
  `date`, and `column` as applicable).
- Linux uptime scripts: `tuptime` (some scripts attempt to install it if
  missing; installation may require administrator privileges).
- `vmware_esxi.sh`: SSH access to the ESXi hosts, `esxcli` on each host, and
  local `curl`, `jq`, and Bash.
- PostgreSQL backup scripts: PostgreSQL client utilities (`pg_dump`,
  `pg_restore`, and/or `pg_dumpall`, depending on the script), access to the
  server, and a protected `$HOME/.pgpass`.
- `monthly-maintenance.sh`: `smartctl`, `pgbackrest`, `curl`, and the relevant
  privileges/configuration.
- `backuppc_check_host_backup.pl`: Perl with the `BackupPC` and `CGI` modules,
  run in the appropriate BackupPC web-server environment.
- PowerShell uptime scripts: Windows PowerShell with access to the System
  event log. Use `-SkipNocoBase` to generate reports without a NocoBase push.

## Examples

Run Linux current-month reporting:

```bash
./uptime-current-month.sh [SERVER_NAME]
```

Run a NocoBase lookup diagnostic:

```bash
./test_lookup.sh <hostname>
./test_uuid.sh [hostname]
```

Run Windows current-month reporting without uploading:

```powershell
.\get-current-month-uptime.ps1 -SkipNocoBase
```

Run an ESXi or PostgreSQL task only after configuring its host/database
settings and credentials appropriately. Review each script's configuration
before running it: some scripts operate on production infrastructure and may
create backups, install packages, or send remote API/notification requests.

## Reports and generated data

Generated CSV files are ignored by Git. Review the report contents for
operational information before sharing them. The scripts currently use
per-file configuration for database/report paths and host names; `.env`
centralizes integration credentials and the ESXi SSH host list.
