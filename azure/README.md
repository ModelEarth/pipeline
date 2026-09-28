# Azure Database Management Script

A user-friendly bash script for managing Azure SQL and PostgreSQL databases using configuration file settings.

### 1. Initial Setup
```bash
chmod +x azure.sh
./azure.sh
```

### 2. Interactive Configuration
The script will guide you through:
- Database type selection (SQL or PostgreSQL)
- Azure resource configuration
- Server and database settings
- Schema URL configuration
- Auto-apply preferences

### 3. Menu Options

1. **Deploy infrastructure from config**: Creates all resources based on configuration
2. **Update existing resources**: Updates or ensures resources exist
3. **View current configuration**: Displays current settings (passwords hidden)
4. **Update configuration**: Modify settings interactively
5. **Apply SuiteCRM schema from URL**: Download and apply the SuiteCRM schema from GitHub
6. **Delete resources**: Remove databases, servers, or entire resource groups
7. **Exit**: Close the application

## Schema Management

This server is used for the [SuiteCRM](https://github.com/ModelEarth/profile/tree/main/crm)
schema specifically (reached at runtime via the `COMMONS_HOST`/`COMMONS_USER`/
`COMMONS_PASSWORD` connection in the team's shared `.env` file) -- hence `suitecrm_` in the
config key names below, not a generic "schema" setting.

### GitHub Schema URLs
The script supports GitHub raw URLs for [SQL schema files](https://github.com/ModelEarth/profile/tree/main/crm/sql):
```
https://raw.githubusercontent.com/ModelEarth/profile/refs/heads/main/crm/sql/crm-postgres.sql
```

### Schema Application Process
1. **Download**: The SuiteCRM schema is downloaded from the configured URL
2. **Preview**: First 20 lines are displayed for confirmation
3. **Confirmation**: User confirms before application
4. **Application**: Schema is applied using appropriate database client

### Auto-Apply Feature
- Set `suitecrm_schema_auto_apply: true` in `azure-shared.yaml`
- The SuiteCRM schema will be automatically applied after database creation
- Useful for CI/CD pipelines and automated deployments

## Database Type Comparison

| Feature | Azure SQL Database | Azure PostgreSQL |
|---------|-------------------|------------------|
| **Pricing Tiers** | Basic, Standard, Premium | Basic, General Purpose, Memory Optimized |
| **Compute Sizes** | S0-S12, P1-P15 | B_Gen5_1/2, GP_Gen5_2/4/8/16/32 |
| **Connection Port** | 1433 | 5432 |
| **Client Tool** | sqlcmd | psql |
| **SSL** | Encrypt=True | sslmode=require |


## Features

- **Split configuration**: shared (non-secret) settings vs. team secrets -- see below
- **Interactive setup**: Create configurations interactively or manually
- **Secure**: Admin credentials and subscription id never touch this repo
- **Comprehensive**: Deploy, update, and delete Azure resources
- **Connection info**: Automatically generates connection strings

## Prerequisites

- **Azure CLI**: [Install Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- **curl**: for downloading the SuiteCRM schema file


## Configuration Structure

Settings are split across two places, so secrets never end up in this (public) repo:

1. **[`azure-shared.yaml`](azure-shared.yaml)** -- non-secret settings (resource group,
   server/database names, location, tier, SuiteCRM schema URL). Checked into GitHub; the
   whole team shares and reviews this file like any other code.
2. **The team's shared `.env` file, outside `webroot`** -- admin usernames/passwords and
   the Azure subscription id. `azure.sh` finds this file the same way this codebase's
   other services do: it reads `env_file:` from
   [`../../automation/paths.yaml`](../../automation/paths.yaml) (copy
   `automation/paths.example.yaml` to `paths.yaml` and point `env_file` at your copy,
   e.g. `safe/cloudroot.env`, if you haven't already). If `paths.yaml` is missing, or its
   `env_file` doesn't point at a real file, `azure.sh` prints exactly what's wrong and
   stops -- it never guesses or creates a secrets file on its own. Secrets are stored as
   plain `KEY=VALUE` lines alongside this codebase's other credentials
   (`AZURE_SUBSCRIPTION_ID`, `AZURE_SQL_ADMIN_USER`, `AZURE_SQL_ADMIN_PASSWORD`,
   `AZURE_POSTGRESQL_ADMIN_USER`, `AZURE_POSTGRESQL_ADMIN_PASSWORD`) -- `azure.sh` only
   ever reads/writes those specific keys, leaving every other line in that shared file
   untouched.

`azure-shared.yaml` looks like this (flat keys, so it can be read/written with plain
`grep`/`awk` -- no `yq` dependency):

```yaml
database_type: sql          # sql | postgresql
resource_group: myapp-rg
location: eastus
sql_server_name: myapp-sql-server
sql_server_location: eastus
postgresql_server_name: myapp-pg-server
postgresql_server_location: eastus
postgresql_server_sku_name: B_Gen5_1
postgresql_server_storage_mb: 5120
postgresql_server_version: "11"
database_name: myapp-db
database_service_tier: Basic
database_compute_size: Basic
suitecrm_schema_url: https://raw.githubusercontent.com/ModelEarth/profile/refs/heads/main/crm/sql/crm-postgres.sql
suitecrm_schema_auto_apply: false
```

When no `azure-shared.yaml` exists yet, `azure.sh` creates one with these defaults and
offers to walk you through filling it in (and the matching secrets) interactively.

### Service Tiers and Compute Sizes

- **Basic**: `Basic` (for development/testing)
- **Standard**: `S0`, `S1`, `S2`, `S3` (for production workloads)
- **Premium**: `P1`, `P2`, `P4`, `P6`, `P11`, `P15` (for mission-critical workloads)

## Menu Options

1. **Deploy infrastructure from config**: Creates all resources based on configuration
2. **Update existing resources**: Updates resources with current configuration
3. **View current configuration**: Shows current settings (passwords hidden)
4. **Update configuration**: Modify settings interactively
5. **Delete resources**: Remove database, server, or entire resource group
6. **Exit**: Quit the script

## Security Features

- **Secrets never live in this repo**: admin credentials and the subscription id are
  read/written only in the team's shared `.env` file outside `webroot`
- **One safety backup per run**: before its first write to that shared `.env` file,
  `azure.sh` copies it to `<file>.bak.<timestamp>`
- **Password masking**: `View current configuration` shows only whether each secret is
  set, never its value
- **Secure input**: Password prompts use secure input (no echo)
- **Fails loudly, not silently**: a missing/misconfigured `automation/paths.yaml` stops
  the script with an explicit message instead of falling back to some default file

## File Structure

```
pipeline/
├── .gitignore                    # Excludes any leftover local azure-db-config* files
└── azure/
    ├── azure.sh                  # Main script
    ├── azure-shared.yaml         # Shared (non-secret) settings -- checked into GitHub
    └── README.md                 # This file

automation/
├── paths.yaml                    # Points azure.sh (and other scripts) at the shared .env file
└── .env.example                  # Format reference for that .env file's AZURE_* keys, among others
```

<!--
## Usage Examples

### Initial Setup
```bash
./azure.sh
# Choose option 1 for interactive configuration
# Follow prompts to set up your Azure resources
```

### Deploy Infrastructure
```bash
./azure.sh
# Choose option 1 to deploy all resources from config
```

### Update Database Tier
```bash
./azure.sh
# Choose option 4 to update configuration
# Choose option 3 to update database settings
# Then option 1 to deploy changes
```
-->

## Error Handling

The script includes comprehensive error handling:
- Validates Azure CLI installation
- Validates that `automation/paths.yaml` exists and its `env_file` resolves to a real file
- Checks Azure login status
- Verifies resource existence before operations

## Connection String

After deployment, the script provides:
- Server Fully Qualified Domain Name (FQDN)
- Database name
- Complete connection string template

Replace `{username}` and `{password}` in the connection string with your actual credentials.

## Troubleshooting

### Common Issues

1. **Azure CLI not found**: Install Azure CLI from Microsoft docs
2. **`automation/paths.yaml not found`**: copy `automation/paths.example.yaml` to
   `automation/paths.yaml` and set `env_file` to your shared secrets `.env` file's path
3. **`paths.yaml's env_file does not point at an existing file`**: create that `.env`
   file (see `automation/.env.example`) or fix `env_file` in `paths.yaml`
4. **Login expired**: Run `az login` to re-authenticate

### Getting Help

- Check Azure CLI version: `az --version`
- View resolved settings (secrets hidden): run `azure.sh`, choose option 3
- Check Azure login: `az account show`


### 1. PostgreSQL Support
- **Multi-Database Support**: Choose between Azure SQL Database and Azure Database for PostgreSQL
- **PostgreSQL-Specific Configuration**: SKU selection, storage sizing, and version management
- **Dedicated Connection Strings**: Separate connection string templates for each database type
- **PostgreSQL Firewall Rules**: Automatic configuration of firewall rules for Azure services

### 2. Automated SuiteCRM Schema Management
- **GitHub Integration**: Direct SuiteCRM schema deployment from GitHub raw URLs
- **Auto-Apply Option**: Automatically apply the SuiteCRM schema during infrastructure deployment
- **Manual Schema Application**: Dedicated menu option for applying the SuiteCRM schema on-demand
- **Schema Preview**: View schema content before application for confirmation
- **Multi-Format Support**: Works with both SQL and PostgreSQL SuiteCRM schema files

### 3. Enhanced Configuration System
- **Database Type Selection**: Interactive choice between SQL and PostgreSQL
- **PostgreSQL SKU Options**: 
  - B_Gen5_1 (Basic, 1 vCore)
  - B_Gen5_2 (Basic, 2 vCore) 
  - GP_Gen5_2 (General Purpose, 2 vCore)
  - GP_Gen5_4 (General Purpose, 4 vCore)
- **Storage Configuration**: Customizable storage size for PostgreSQL
- **Version Selection**: PostgreSQL version support (11, 12, 13, 14)


## Prerequisites

### Required Tools
- **Azure CLI**: For Azure resource management
- **curl**: For downloading schemas from GitHub
- **sqlcmd** (optional): For SQL Server schema application
- **psql** (optional): For PostgreSQL schema application


### Azure CLI Installation Commands

#### Ubuntu/Debian
```bash
sudo apt-get update
sudo apt-get install azure-cli curl postgresql-client mssql-tools
```

#### macOS
```bash
brew update
brew install azure-cli curl postgresql
```

#### Windows (WSL/Git Bash)
```bash
# Install Azure CLI from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli
# Install other tools through package managers or direct downloads
```


## Troubleshooting

### Common Issues

#### 1. Shared secrets file not found or misconfigured
See "automation/paths.yaml not found" / "env_file does not point at an existing file"
above -- `azure.sh` prints the exact expected path when this happens.

#### 2. Azure CLI not authenticated
```bash
az login
az account set --subscription "your-subscription-id"
```

#### 3. Schema application fails
- Ensure sqlcmd (SQL) or psql (PostgreSQL) is installed
- Check firewall rules allow your IP address
- Verify database credentials are correct

#### 4. Server name conflicts
- Server names must be globally unique across Azure
- Try adding random numbers or your organization prefix

---
<br>
Also see: [Script for installing SuiteCRM](https://github.com/ModelEarth/profile/tree/main/crm) (moved to the `profile` repo)