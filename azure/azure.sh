#!/bin/bash

# azure.sh Database Management Script
#
# Settings are split into two places:
# - Shared (non-secret) settings: azure-shared.yaml, next to this script.
#   Checked into GitHub -- resource group/server/database names, location,
#   tiers, SuiteCRM schema URL. Safe for the whole team to see.
# - Secrets (admin credentials, subscription id): the team's shared .env
#   file OUTSIDE webroot (e.g. safe/cloudroot.env), resolved through
#   automation/paths.yaml's env_file setting -- same file DBMonitor's
#   Program.cs and other scripts in this codebase already read from.
#   Never written into this repo.

set -e  # Exit on any error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_CONFIG_FILE="$SCRIPT_DIR/azure-shared.yaml"
PATHS_YAML="$SCRIPT_DIR/../../automation/paths.yaml"
ENV_FILE=""  # resolved by resolve_env_file, below

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check if curl is installed
check_curl() {
    if ! command -v curl &> /dev/null; then
        print_message $RED "curl is not installed. Please install it first:"
        print_message $YELLOW "Ubuntu/Debian: sudo apt-get install curl"
        print_message $YELLOW "macOS: curl is usually pre-installed"
        exit 1
    fi
}

# Detect platform
platform="$(uname)"
case "$platform" in
  Darwin*)
    os="macos"
    ;;
  Linux*)
    os="linux"
    ;;
  CYGWIN*|MINGW*|MSYS*)
    os="windows"
    ;;
  FreeBSD*|OpenBSD*|NetBSD*)
    os="bsd"  # Group BSD variants together
    ;;
  SunOS*)
    os="solaris"  # Keep separate due to significant differences
    ;;
  AIX*)
    os="aix"  # Keep separate due to significant differences
    ;;
  *)
    echo "Warning: Unrecognized platform: $platform" >&2
    echo "Assuming Unix-like system, using linux defaults" >&2
    os="linux"  # Safe fallback for most Unix-like systems
    ;;
esac

# Function to check if Azure CLI is installed
check_azure_cli() {
    if ! command -v az &> /dev/null; then
        print_message $RED "Azure CLI is not installed. Please install it first:"
        print_message $YELLOW "Visit: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        if [[ "$os" == "macos" ]]; then
            print_message $BLUE "Or run: brew update && brew install azure-cli"
        fi
        exit 1
    fi
}

# Collapse a path string's "." and ".." segments via pure string ops -- no
# filesystem access, so it also works to report an EXPECTED path that
# doesn't exist yet (for error messages), not just ones that already do.
normalize_path() {
    local path="$1"
    local result=""
    local part
    IFS='/' read -ra parts <<< "$path"
    for part in "${parts[@]}"; do
        case "$part" in
            "" | ".") continue ;;
            "..") result="${result%/*}" ;;
            *) result="$result/$part" ;;
        esac
    done
    echo "${result:-/}"
}

# Resolve the team's shared secrets .env file from automation/paths.yaml,
# the same file DBMonitor's Program.cs and other scripts in this codebase
# read env_file from. Sets the global ENV_FILE on success; otherwise prints
# a clear, actionable message and exits (there's nowhere safe to read/write
# Azure credentials without it).
resolve_env_file() {
    if [[ ! -f "$PATHS_YAML" ]]; then
        print_message $RED "automation/paths.yaml not found (looked at: $PATHS_YAML)."
        print_message $YELLOW "This script keeps Azure secrets (admin credentials, subscription id) in your"
        print_message $YELLOW "team's shared .env file OUTSIDE webroot (e.g. safe/cloudroot.env) instead of a"
        print_message $YELLOW "local config file. Copy automation/paths.example.yaml to automation/paths.yaml"
        print_message $YELLOW "and set env_file to that .env file's path, relative to the automation/ folder."
        exit 1
    fi

    local env_file_line raw_value base_dir resolved
    env_file_line=$(grep -i '^env_file:' "$PATHS_YAML" | tail -1)
    raw_value="${env_file_line#*:}"
    raw_value="$(echo "$raw_value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//")"

    if [[ -z "$raw_value" ]]; then
        print_message $RED "automation/paths.yaml has no env_file value set."
        print_message $YELLOW "Edit $PATHS_YAML and set env_file to your shared secrets .env file's path."
        exit 1
    fi

    base_dir="$(dirname "$PATHS_YAML")"
    resolved="$(normalize_path "$base_dir/$raw_value")"

    if [[ ! -f "$resolved" ]]; then
        print_message $RED "paths.yaml's env_file does not point at an existing file."
        print_message $YELLOW "Expected: $resolved  (from env_file: $raw_value in $PATHS_YAML)"
        print_message $YELLOW "Create that .env file (see automation/.env.example for the format used by this"
        print_message $YELLOW "codebase's other services) or fix env_file in paths.yaml."
        exit 1
    fi

    ENV_FILE="$resolved"
    print_message $GREEN "Using shared secrets file: $ENV_FILE"
}

# --- Shared (public) config: flat "key: value" lines in azure-shared.yaml ---

get_shared() {
    local key="$1" line value
    line=$(grep -E "^${key}:" "$SHARED_CONFIG_FILE" 2>/dev/null | tail -1)
    value="${line#*:}"
    echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}

set_shared() {
    local key="$1" value="$2" tmp
    tmp=$(mktemp)
    if grep -qE "^${key}:" "$SHARED_CONFIG_FILE" 2>/dev/null; then
        awk -v k="$key" -v v="$value" 'BEGIN{FS=":"} $1==k{print k": "v; next} {print}' \
            "$SHARED_CONFIG_FILE" > "$tmp"
    else
        cp "$SHARED_CONFIG_FILE" "$tmp" 2>/dev/null || true
        printf '%s: %s\n' "$key" "$value" >> "$tmp"
    fi
    mv "$tmp" "$SHARED_CONFIG_FILE"
}

create_shared_config_defaults() {
    cat > "$SHARED_CONFIG_FILE" << 'EOF'
# Shared (non-secret) Azure resource settings for the team.
# Checked into GitHub -- do not put admin credentials or subscription ids
# here. Those live in the team's shared .env file outside webroot, resolved
# through ../../automation/paths.yaml (see pipeline/README.md's Getting
# Started section, or run azure.sh, which will explain what's missing).
database_type: sql
resource_group: ""
location: eastus
sql_server_name: ""
sql_server_location: eastus
postgresql_server_name: ""
postgresql_server_location: eastus
postgresql_server_sku_name: B_Gen5_1
postgresql_server_storage_mb: 5120
postgresql_server_version: "11"
database_name: ""
database_service_tier: Basic
database_compute_size: Basic
suitecrm_schema_url: https://raw.githubusercontent.com/ModelEarth/profile/refs/heads/main/crm/sql/crm-postgres.sql
suitecrm_schema_auto_apply: false
EOF
    print_message $GREEN "Created default shared config: $SHARED_CONFIG_FILE"
}

load_shared_config() {
    if [[ ! -f "$SHARED_CONFIG_FILE" ]]; then
        create_shared_config_defaults
        read -p "Fill it in interactively now? (y/n) [y]: " fill_choice
        if [[ -z "$fill_choice" || "$fill_choice" == "y" || "$fill_choice" == "Y" ]]; then
            create_config_interactively
        else
            print_message $YELLOW "Edit $SHARED_CONFIG_FILE, then use this script's Update Configuration menu"
            print_message $YELLOW "to set admin credentials, before deploying."
        fi
    fi
    print_message $GREEN "Shared configuration: $SHARED_CONFIG_FILE"
}

# --- Secrets: KEY=VALUE lines in the resolved shared .env file ---
# Only ever touches the AZURE_* keys this script owns -- every other line
# in that shared, multi-purpose file (COMMONS_*, EXIOBASE_*, DBMONITOR_*,
# ...) is read back and written out untouched.

get_secret() {
    local key="$1" line
    line=$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1)
    echo "${line#*=}"
}

set_secret() {
    local key="$1" value="$2" tmp
    tmp=$(mktemp)
    if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
        awk -v k="$key" -v v="$value" 'BEGIN{FS="="} $1==k{print k"="v; next} {print}' \
            "$ENV_FILE" > "$tmp"
    else
        cp "$ENV_FILE" "$tmp"
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    mv "$tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
}

# One safety backup per run, before this script writes to the team's shared
# secrets file for the first time.
ENV_FILE_BACKED_UP=false
backup_env_file_once() {
    if [[ "$ENV_FILE_BACKED_UP" == false ]]; then
        cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%s)"
        ENV_FILE_BACKED_UP=true
    fi
}

# Function to create configuration interactively
create_config_interactively() {
    print_message $BLUE "=== Interactive Configuration Setup ==="
    print_message $YELLOW "Shared values are saved to $SHARED_CONFIG_FILE (checked into GitHub)."
    print_message $YELLOW "Admin credentials are saved to $ENV_FILE (never committed)."
    backup_env_file_once

    echo
    print_message $YELLOW "Select database type:"
    echo "1) Azure SQL Database"
    echo "2) Azure Database for PostgreSQL"

    read -p "Choose database type (1-2): " db_type_choice

    case $db_type_choice in
        1)
            database_type="sql"
            ;;
        2)
            database_type="postgresql"
            ;;
        *)
            print_message $YELLOW "Invalid choice, using SQL Database"
            database_type="sql"
            ;;
    esac
    set_shared 'database_type' "$database_type"

    echo
    read -p "Enter Azure resource group name: " rg_name
    read -p "Enter Azure location (e.g., eastus, westus2) [eastus]: " azure_location
    azure_location=${azure_location:-eastus}
    set_shared 'resource_group' "$rg_name"
    set_shared 'location' "$azure_location"

    echo
    if [[ "$database_type" == "sql" ]]; then
        read -p "Enter SQL server name: " server_name
        read -p "Enter SQL admin username: " admin_user
        read -s -p "Enter SQL admin password: " admin_password
        echo
        read -p "Enter SQL server location [eastus]: " sql_location
        sql_location=${sql_location:-eastus}

        set_shared 'sql_server_name' "$server_name"
        set_shared 'sql_server_location' "$sql_location"
        set_secret 'AZURE_SQL_ADMIN_USER' "$admin_user"
        set_secret 'AZURE_SQL_ADMIN_PASSWORD' "$admin_password"

        echo
        read -p "Enter database name: " db_name
        set_shared 'database_name' "$db_name"

        echo "Select service tier:"
        echo "1) Basic (for development/testing)"
        echo "2) Standard (for production workloads)"
        echo "3) Premium (for mission-critical workloads)"

        read -p "Choose service tier (1-3): " tier_choice

        case $tier_choice in
            1)
                service_tier="Basic"
                compute_size="Basic"
                ;;
            2)
                service_tier="Standard"
                read -p "Enter compute size (S0, S1, S2, S3) [S0]: " compute_size
                compute_size=${compute_size:-S0}
                ;;
            3)
                service_tier="Premium"
                read -p "Enter compute size (P1, P2, P4, P6, P11, P15) [P1]: " compute_size
                compute_size=${compute_size:-P1}
                ;;
            *)
                print_message $YELLOW "Invalid choice, using Basic tier"
                service_tier="Basic"
                compute_size="Basic"
                ;;
        esac
        set_shared 'database_service_tier' "$service_tier"
        set_shared 'database_compute_size' "$compute_size"
    else
        read -p "Enter PostgreSQL server name: " server_name
        read -p "Enter PostgreSQL admin username: " admin_user
        read -s -p "Enter PostgreSQL admin password: " admin_password
        echo
        read -p "Enter PostgreSQL server location [eastus]: " pg_location
        pg_location=${pg_location:-eastus}

        set_shared 'postgresql_server_name' "$server_name"
        set_shared 'postgresql_server_location' "$pg_location"
        set_secret 'AZURE_POSTGRESQL_ADMIN_USER' "$admin_user"
        set_secret 'AZURE_POSTGRESQL_ADMIN_PASSWORD' "$admin_password"

        echo
        read -p "Enter database name: " db_name
        set_shared 'database_name' "$db_name"

        echo "Select SKU (pricing tier):"
        echo "1) B_Gen5_1 (Basic, 1 vCore)"
        echo "2) B_Gen5_2 (Basic, 2 vCore)"
        echo "3) GP_Gen5_2 (General Purpose, 2 vCore)"
        echo "4) GP_Gen5_4 (General Purpose, 4 vCore)"

        read -p "Choose SKU (1-4): " sku_choice

        case $sku_choice in
            1)
                sku_name="B_Gen5_1"
                ;;
            2)
                sku_name="B_Gen5_2"
                ;;
            3)
                sku_name="GP_Gen5_2"
                ;;
            4)
                sku_name="GP_Gen5_4"
                ;;
            *)
                print_message $YELLOW "Invalid choice, using B_Gen5_1"
                sku_name="B_Gen5_1"
                ;;
        esac
        set_shared 'postgresql_server_sku_name' "$sku_name"

        read -p "Enter storage size in MB [5120]: " storage_mb
        storage_mb=${storage_mb:-5120}
        set_shared 'postgresql_server_storage_mb' "$storage_mb"

        read -p "Enter PostgreSQL version (11, 12, 13, 14) [11]: " pg_version
        pg_version=${pg_version:-11}
        set_shared 'postgresql_server_version' "$pg_version"
    fi

    echo
    read -p "Enter SuiteCRM schema URL (GitHub raw URL) [https://raw.githubusercontent.com/]: " suitecrm_schema_url
    suitecrm_schema_url=${suitecrm_schema_url:-"https://raw.githubusercontent.com/ModelEarth/profile/refs/heads/main/crm/sql/crm-postgres.sql"}
    set_shared 'suitecrm_schema_url' "$suitecrm_schema_url"

    read -p "Auto-apply SuiteCRM schema after database creation? (y/n) [n]: " suitecrm_schema_auto_apply
    if [[ "$suitecrm_schema_auto_apply" == "y" || "$suitecrm_schema_auto_apply" == "Y" ]]; then
        set_shared 'suitecrm_schema_auto_apply' "true"
    else
        set_shared 'suitecrm_schema_auto_apply' "false"
    fi

    print_message $GREEN "Shared settings saved to: $SHARED_CONFIG_FILE"
    print_message $GREEN "Secrets saved to: $ENV_FILE"
}

# Function to display menu
show_menu() {
    echo
    print_message $BLUE "=== Azure Database Management ==="
    echo "1) Deploy infrastructure from config"
    echo "2) Update existing resources"
    echo "3) View current configuration"
    echo "4) Update configuration"
    echo "5) Apply SuiteCRM schema from URL"
    echo "6) Delete resources"
    echo "7) Exit"
    echo
}

# Function to handle Azure login
azure_login() {
    print_message $YELLOW "Logging into Azure..."

    # Check if already logged in
    if az account show &>/dev/null; then
        current_account=$(az account show --query "name" -o tsv)
        print_message $GREEN "Already logged in to: $current_account"

        read -p "Do you want to use this account? (y/n): " use_current
        if [[ $use_current != "y" && $use_current != "Y" ]]; then
            az logout
            az login
        fi
    else
        az login
    fi

    # Save subscription ID to the shared secrets file if not already there
    subscription_id=$(az account show --query "id" -o tsv)
    config_sub_id=$(get_secret 'AZURE_SUBSCRIPTION_ID')

    if [[ -z "$config_sub_id" ]]; then
        backup_env_file_once
        set_secret 'AZURE_SUBSCRIPTION_ID' "$subscription_id"
        print_message $GREEN "Saved subscription ID to $ENV_FILE"
    fi

    # Display current subscription
    subscription=$(az account show --query "name" -o tsv)
    print_message $GREEN "Using subscription: $subscription ($subscription_id)"
}

# Function to ensure resource group exists
ensure_resource_group() {
    local rg_name=$(get_shared 'resource_group')
    local location=$(get_shared 'location')

    print_message $YELLOW "Checking resource group: $rg_name"

    if ! az group show --name "$rg_name" &>/dev/null; then
        print_message $YELLOW "Creating resource group: $rg_name"
        az group create --name "$rg_name" --location "$location"
        print_message $GREEN "Resource group created successfully!"
    else
        print_message $GREEN "Resource group already exists: $rg_name"
    fi
}

# Function to ensure SQL server exists
ensure_sql_server() {
    local server_name=$(get_shared 'sql_server_name')
    local rg_name=$(get_shared 'resource_group')
    local admin_user=$(get_secret 'AZURE_SQL_ADMIN_USER')
    local admin_password=$(get_secret 'AZURE_SQL_ADMIN_PASSWORD')
    local location=$(get_shared 'sql_server_location')

    if [[ -z "$admin_user" || -z "$admin_password" ]]; then
        print_message $RED "AZURE_SQL_ADMIN_USER / AZURE_SQL_ADMIN_PASSWORD not set in $ENV_FILE."
        print_message $YELLOW "Use menu option 4 (Update configuration) to set them first."
        exit 1
    fi

    print_message $YELLOW "Checking SQL server: $server_name"

    if ! az sql server show --name "$server_name" --resource-group "$rg_name" &>/dev/null; then
        print_message $YELLOW "Creating SQL server: $server_name"
        az sql server create \
            --name "$server_name" \
            --resource-group "$rg_name" \
            --location "$location" \
            --admin-user "$admin_user" \
            --admin-password "$admin_password"

        print_message $GREEN "SQL server created successfully!"

        # Configure firewall to allow Azure services
        print_message $YELLOW "Configuring firewall rules..."
        az sql server firewall-rule create \
            --resource-group "$rg_name" \
            --server "$server_name" \
            --name "AllowAzureServices" \
            --start-ip-address 0.0.0.0 \
            --end-ip-address 0.0.0.0
    else
        print_message $GREEN "SQL server already exists: $server_name"
    fi
}

# Function to ensure PostgreSQL server exists
ensure_postgresql_server() {
    local server_name=$(get_shared 'postgresql_server_name')
    local rg_name=$(get_shared 'resource_group')
    local admin_user=$(get_secret 'AZURE_POSTGRESQL_ADMIN_USER')
    local admin_password=$(get_secret 'AZURE_POSTGRESQL_ADMIN_PASSWORD')
    local location=$(get_shared 'postgresql_server_location')
    local sku_name=$(get_shared 'postgresql_server_sku_name')
    local storage_mb=$(get_shared 'postgresql_server_storage_mb')
    local version=$(get_shared 'postgresql_server_version')

    if [[ -z "$admin_user" || -z "$admin_password" ]]; then
        print_message $RED "AZURE_POSTGRESQL_ADMIN_USER / AZURE_POSTGRESQL_ADMIN_PASSWORD not set in $ENV_FILE."
        print_message $YELLOW "Use menu option 4 (Update configuration) to set them first."
        exit 1
    fi

    print_message $YELLOW "Checking PostgreSQL server: $server_name"

    if ! az postgres server show --name "$server_name" --resource-group "$rg_name" &>/dev/null; then
        print_message $YELLOW "Creating PostgreSQL server: $server_name"
        az postgres server create \
            --name "$server_name" \
            --resource-group "$rg_name" \
            --location "$location" \
            --admin-user "$admin_user" \
            --admin-password "$admin_password" \
            --sku-name "$sku_name" \
            --storage-size "$storage_mb" \
            --version "$version"

        print_message $GREEN "PostgreSQL server created successfully!"

        # Configure firewall to allow Azure services
        print_message $YELLOW "Configuring firewall rules..."
        az postgres server firewall-rule create \
            --resource-group "$rg_name" \
            --server "$server_name" \
            --name "AllowAzureServices" \
            --start-ip-address 0.0.0.0 \
            --end-ip-address 0.0.0.0
    else
        print_message $GREEN "PostgreSQL server already exists: $server_name"
    fi
}

# Function to ensure database exists
ensure_database() {
    local db_type=$(get_shared 'database_type')
    local db_name=$(get_shared 'database_name')
    local rg_name=$(get_shared 'resource_group')

    if [[ "$db_type" == "sql" ]]; then
        local server_name=$(get_shared 'sql_server_name')
        local compute_size=$(get_shared 'database_compute_size')

        print_message $YELLOW "Checking SQL database: $db_name"

        if ! az sql db show --name "$db_name" --server "$server_name" --resource-group "$rg_name" &>/dev/null; then
            print_message $YELLOW "Creating SQL database: $db_name"
            az sql db create \
                --name "$db_name" \
                --server "$server_name" \
                --resource-group "$rg_name" \
                --service-objective "$compute_size"

            print_message $GREEN "SQL database created successfully!"
        else
            print_message $GREEN "SQL database already exists: $db_name"
        fi
    else
        local server_name=$(get_shared 'postgresql_server_name')

        print_message $YELLOW "Checking PostgreSQL database: $db_name"

        if ! az postgres db show --name "$db_name" --server-name "$server_name" --resource-group "$rg_name" &>/dev/null; then
            print_message $YELLOW "Creating PostgreSQL database: $db_name"
            az postgres db create \
                --name "$db_name" \
                --server-name "$server_name" \
                --resource-group "$rg_name"

            print_message $GREEN "PostgreSQL database created successfully!"
        else
            print_message $GREEN "PostgreSQL database already exists: $db_name"
        fi
    fi
}

# Function to download and apply the SuiteCRM schema
apply_schema() {
    local suitecrm_schema_url=$(get_shared 'suitecrm_schema_url')
    local db_type=$(get_shared 'database_type')

    if [[ -z "$suitecrm_schema_url" || "$suitecrm_schema_url" == "https://raw.githubusercontent.com/" ]]; then
        print_message $YELLOW "No SuiteCRM schema URL configured. Skipping schema application."
        return
    fi

    print_message $BLUE "=== Applying SuiteCRM Database Schema ==="
    print_message $YELLOW "Downloading SuiteCRM schema from: $suitecrm_schema_url"

    local temp_schema_file=$(mktemp)

    if curl -s -f "$suitecrm_schema_url" -o "$temp_schema_file"; then
        print_message $GREEN "Schema downloaded successfully"

        # Display schema content for confirmation
        print_message $BLUE "Schema content preview:"
        echo "----------------------------------------"
        head -20 "$temp_schema_file"
        echo "----------------------------------------"

        read -p "Do you want to apply this schema? (y/n): " apply_confirm

        if [[ "$apply_confirm" == "y" || "$apply_confirm" == "Y" ]]; then
            if [[ "$db_type" == "sql" ]]; then
                apply_sql_schema "$temp_schema_file"
            else
                apply_postgresql_schema "$temp_schema_file"
            fi
        else
            print_message $YELLOW "Schema application cancelled"
        fi
    else
        print_message $RED "Failed to download SuiteCRM schema from: $suitecrm_schema_url"
        print_message $YELLOW "Please check the URL and try again"
    fi

    rm -f "$temp_schema_file"
}

# Function to apply SQL schema
apply_sql_schema() {
    local schema_file=$1
    local server_name=$(get_shared 'sql_server_name')
    local db_name=$(get_shared 'database_name')
    local admin_user=$(get_secret 'AZURE_SQL_ADMIN_USER')
    local admin_password=$(get_secret 'AZURE_SQL_ADMIN_PASSWORD')

    print_message $YELLOW "Applying schema to SQL database..."

    # Note: This requires sqlcmd to be installed
    if command -v sqlcmd &> /dev/null; then
        sqlcmd -S "$server_name.database.windows.net" -d "$db_name" -U "$admin_user" -P "$admin_password" -i "$schema_file"
        print_message $GREEN "Schema applied successfully to SQL database"
    else
        print_message $YELLOW "sqlcmd not found. You can apply the schema manually using:"
        print_message $BLUE "Server: $server_name.database.windows.net"
        print_message $BLUE "Database: $db_name"
        print_message $BLUE "Schema file: $schema_file"
    fi
}

# Function to apply PostgreSQL schema
apply_postgresql_schema() {
    local schema_file=$1
    local server_name=$(get_shared 'postgresql_server_name')
    local db_name=$(get_shared 'database_name')
    local admin_user=$(get_secret 'AZURE_POSTGRESQL_ADMIN_USER')
    local admin_password=$(get_secret 'AZURE_POSTGRESQL_ADMIN_PASSWORD')

    print_message $YELLOW "Applying schema to PostgreSQL database..."

    # Note: This requires psql to be installed
    if command -v psql &> /dev/null; then
        PGPASSWORD="$admin_password" psql -h "$server_name.postgres.database.azure.com" -U "$admin_user@$server_name" -d "$db_name" -f "$schema_file"
        print_message $GREEN "Schema applied successfully to PostgreSQL database"
    else
        print_message $YELLOW "psql not found. You can apply the schema manually using:"
        print_message $BLUE "Host: $server_name.postgres.database.azure.com"
        print_message $BLUE "Database: $db_name"
        print_message $BLUE "User: $admin_user@$server_name"
        print_message $BLUE "Schema file: $schema_file"
    fi
}

# Function to deploy infrastructure
deploy_infrastructure() {
    local db_type=$(get_shared 'database_type')

    print_message $BLUE "=== Deploying Infrastructure ==="
    print_message $YELLOW "Database type: $db_type"

    ensure_resource_group

    if [[ "$db_type" == "sql" ]]; then
        ensure_sql_server
    else
        ensure_postgresql_server
    fi

    ensure_database

    # Check if the SuiteCRM schema should be auto-applied
    local suitecrm_schema_auto_apply=$(get_shared 'suitecrm_schema_auto_apply')
    if [[ "$suitecrm_schema_auto_apply" == "true" ]]; then
        apply_schema
    fi

    print_message $GREEN "Infrastructure deployment completed!"
    display_connection_info
}

# Function to display connection information
display_connection_info() {
    echo
    print_message $BLUE "=== Connection Information ==="

    local db_type=$(get_shared 'database_type')
    local db_name=$(get_shared 'database_name')

    print_message $YELLOW "Database Type: $db_type"
    print_message $YELLOW "Database: $db_name"

    if [[ "$db_type" == "sql" ]]; then
        local server_name=$(get_shared 'sql_server_name')
        local server_fqdn="$server_name.database.windows.net"
        print_message $YELLOW "Server: $server_fqdn"
        print_message $YELLOW "SQL Connection String Template:"
        echo "Server=tcp:$server_fqdn,1433;Initial Catalog=$db_name;Persist Security Info=False;User ID={username};Password={password};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
    else
        local server_name=$(get_shared 'postgresql_server_name')
        local server_fqdn="$server_name.postgres.database.azure.com"
        print_message $YELLOW "Server: $server_fqdn"
        print_message $YELLOW "PostgreSQL Connection String Template:"
        echo "host=$server_fqdn port=5432 dbname=$db_name user={username}@$server_name password={password} sslmode=require"
    fi
}

# Function to view current configuration
view_configuration() {
    print_message $BLUE "=== Shared Configuration ($SHARED_CONFIG_FILE) ==="
    cat "$SHARED_CONFIG_FILE"

    echo
    print_message $BLUE "=== Secrets ($ENV_FILE, values hidden) ==="
    local key
    for key in AZURE_SUBSCRIPTION_ID AZURE_SQL_ADMIN_USER AZURE_SQL_ADMIN_PASSWORD \
               AZURE_POSTGRESQL_ADMIN_USER AZURE_POSTGRESQL_ADMIN_PASSWORD; do
        if [[ -n "$(get_secret "$key")" ]]; then
            print_message $GREEN "$key: [set]"
        else
            print_message $YELLOW "$key: [not set]"
        fi
    done
}

# Function to update configuration menu
update_configuration_menu() {
    echo
    print_message $BLUE "=== Update Configuration ==="
    echo "1) Update resource group"
    echo "2) Update server settings"
    echo "3) Update database settings"
    echo "4) Update SuiteCRM schema settings"
    echo "5) Back to main menu"

    read -p "Choose option (1-5): " update_choice

    case $update_choice in
        1)
            read -p "Enter new resource group name: " new_rg
            read -p "Enter new location: " new_location
            set_shared 'resource_group' "$new_rg"
            set_shared 'location' "$new_location"
            print_message $GREEN "Resource group configuration updated"
            ;;
        2)
            backup_env_file_once
            local db_type=$(get_shared 'database_type')
            if [[ "$db_type" == "sql" ]]; then
                read -p "Enter new SQL server name: " new_server
                read -p "Enter new admin username: " new_admin
                read -s -p "Enter new admin password: " new_password
                echo
                set_shared 'sql_server_name' "$new_server"
                set_secret 'AZURE_SQL_ADMIN_USER' "$new_admin"
                set_secret 'AZURE_SQL_ADMIN_PASSWORD' "$new_password"
            else
                read -p "Enter new PostgreSQL server name: " new_server
                read -p "Enter new admin username: " new_admin
                read -s -p "Enter new admin password: " new_password
                echo
                set_shared 'postgresql_server_name' "$new_server"
                set_secret 'AZURE_POSTGRESQL_ADMIN_USER' "$new_admin"
                set_secret 'AZURE_POSTGRESQL_ADMIN_PASSWORD' "$new_password"
            fi
            print_message $GREEN "Server configuration updated"
            ;;
        3)
            read -p "Enter new database name: " new_db
            set_shared 'database_name' "$new_db"

            local db_type=$(get_shared 'database_type')
            if [[ "$db_type" == "sql" ]]; then
                read -p "Enter new service tier (Basic/Standard/Premium): " new_tier
                read -p "Enter new compute size: " new_compute
                set_shared 'database_service_tier' "$new_tier"
                set_shared 'database_compute_size' "$new_compute"
            fi
            print_message $GREEN "Database configuration updated"
            ;;
        4)
            read -p "Enter new SuiteCRM schema URL: " new_suitecrm_schema_url
            read -p "Auto-apply SuiteCRM schema? (true/false): " new_suitecrm_schema_auto_apply
            set_shared 'suitecrm_schema_url' "$new_suitecrm_schema_url"
            set_shared 'suitecrm_schema_auto_apply' "$new_suitecrm_schema_auto_apply"
            print_message $GREEN "SuiteCRM schema configuration updated"
            ;;
        5)
            return
            ;;
        *)
            print_message $RED "Invalid option"
            ;;
    esac
}

# Function to delete resources
delete_resources() {
    local db_type=$(get_shared 'database_type')

    print_message $RED "=== Delete Resources ==="
    print_message $RED "WARNING: This will delete all resources!"

    echo "What would you like to delete?"
    echo "1) Database only"
    echo "2) Server and Database"
    echo "3) Entire Resource Group"
    echo "4) Cancel"

    read -p "Choose option (1-4): " delete_choice

    local rg_name=$(get_shared 'resource_group')
    local db_name=$(get_shared 'database_name')

    if [[ "$db_type" == "sql" ]]; then
        local server_name=$(get_shared 'sql_server_name')
    else
        local server_name=$(get_shared 'postgresql_server_name')
    fi

    case $delete_choice in
        1)
            read -p "Are you sure you want to delete database '$db_name'? (yes/no): " confirm
            if [[ "$confirm" == "yes" ]]; then
                if [[ "$db_type" == "sql" ]]; then
                    az sql db delete --name "$db_name" --server "$server_name" --resource-group "$rg_name" --yes
                else
                    az postgres db delete --name "$db_name" --server-name "$server_name" --resource-group "$rg_name" --yes
                fi
                print_message $GREEN "Database deleted successfully"
            fi
            ;;
        2)
            read -p "Are you sure you want to delete server '$server_name' and all its databases? (yes/no): " confirm
            if [[ "$confirm" == "yes" ]]; then
                if [[ "$db_type" == "sql" ]]; then
                    az sql server delete --name "$server_name" --resource-group "$rg_name" --yes
                else
                    az postgres server delete --name "$server_name" --resource-group "$rg_name" --yes
                fi
                print_message $GREEN "Server deleted successfully"
            fi
            ;;
        3)
            read -p "Are you sure you want to delete resource group '$rg_name' and ALL its resources? (yes/no): " confirm
            if [[ "$confirm" == "yes" ]]; then
                az group delete --name "$rg_name" --yes
                print_message $GREEN "Resource group deleted successfully"
            fi
            ;;
        4)
            print_message $YELLOW "Deletion cancelled"
            ;;
        *)
            print_message $RED "Invalid option"
            ;;
    esac
}

# Main script execution
main() {
    print_message $GREEN "Azure Database Management Script"
    print_message $YELLOW "Enhanced with PostgreSQL Support"
    print_message $YELLOW "===============================\n"

    # Check prerequisites
    check_azure_cli
    check_curl

    # Resolve the shared secrets .env file (exits with a message if missing)
    resolve_env_file

    # Load shared (non-secret) configuration
    load_shared_config

    # Azure login
    azure_login

    # Main menu loop
    while true; do
        show_menu
        read -p "Please select an option (1-7): " choice

        case $choice in
            1)
                deploy_infrastructure
                ;;
            2)
                print_message $YELLOW "Updating existing resources..."
                deploy_infrastructure
                ;;
            3)
                view_configuration
                ;;
            4)
                update_configuration_menu
                ;;
            5)
                apply_schema
                ;;
            6)
                delete_resources
                ;;
            7)
                print_message $YELLOW "Goodbye!"
                exit 0
                ;;
            *)
                print_message $RED "Invalid option. Please choose 1-7."
                ;;
        esac

        echo
        read -p "Press Enter to continue..."
    done
}

# Run main function
main "$@"
