#!/usr/bin/env pwsh

<#+
.SYNOPSIS
  Setup Entra ID Application Registration for diagramHub Self-Hosted (PowerShell).

.DESCRIPTION
  Creates (or patches) an application registration in Azure Entra ID and configures it per README.md:
  - Accounts in this organizational directory only (AzureADMyOrg)
  - Platform: Single-page application (SPA)
  - Redirect URI: <APP_SCHEME>://<APP_FQDN>
  - Expose an API: Application ID URI = api://<CLIENT_ID>
  - Add scope: user_impersonation
  - Add Microsoft Graph delegated permission: User.Read

  This script uses Azure CLI (az) and Microsoft Graph via `az rest`.

.PARAMETER AppName
  Application display name. Defaults to $env:APP_NAME or "diagramHub Self-Hosted".

.PARAMETER AppFqdn
  Application FQDN (host). Defaults to $env:APP_FQDN or "localhost".

.PARAMETER AppScheme
  URL scheme for redirect URI (http/https). Defaults to $env:APP_SCHEME or "http".

.PARAMETER ScopeDescription
  Description for the user_impersonation scope.

.PARAMETER ShowHelp
  Print usage similar to the Bash script.

.EXAMPLE
  ./setup-entra-id-app.ps1

.EXAMPLE
  ./setup-entra-id-app.ps1 -AppFqdn app.example.com -AppScheme https
#>

[CmdletBinding()]
param(
  [string] $AppName,
  [string] $AppFqdn,
  [string] $AppScheme,
  [string] $ScopeDescription,

  [Alias('h', 'help')]
  [switch] $ShowHelp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Usage {
  $scriptName = [System.IO.Path]::GetFileName($PSCommandPath)
  @"
Usage: $scriptName [options]

Options (or set equivalent env vars):
  -AppName NAME            (env: APP_NAME)   Default: "diagramHub Self-Hosted"
  -AppFqdn FQDN            (env: APP_FQDN)   Default: "localhost"
  -AppScheme SCHEME        (env: APP_SCHEME) Default: "http"
  -ScopeDescription TEXT   (env: SCOPE_DESCRIPTION)
  -h, -help                Show help

Examples:
  APP_FQDN=app.example.com APP_SCHEME=https pwsh -File $scriptName
  pwsh -File $scriptName -AppName "diagramHub Self-Hosted" -AppFqdn localhost -AppScheme http
"@ | Write-Host
}

if ($ShowHelp) {
  Write-Usage
  exit 0
}

function Resolve-Default {
  param(
    [AllowNull()] [string] $Value,
    [AllowNull()] [string] $EnvValue,
    [string] $Default
  )

  if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
  if (-not [string]::IsNullOrWhiteSpace($EnvValue)) { return $EnvValue }
  return $Default
}

$AppName = Resolve-Default -Value $AppName -EnvValue $env:APP_NAME -Default 'diagramHub Self-Hosted'
$AppFqdn = Resolve-Default -Value $AppFqdn -EnvValue $env:APP_FQDN -Default 'localhost'
$AppScheme = Resolve-Default -Value $AppScheme -EnvValue $env:APP_SCHEME -Default 'http'
$ScopeDescription = Resolve-Default -Value $ScopeDescription -EnvValue $env:SCOPE_DESCRIPTION -Default 'Allows the application to access diagramHub on behalf of the user'

$ScopeName = 'user_impersonation'

# Microsoft Graph (well-known IDs)
$MsGraphResourceAppId = '00000003-0000-0000-c000-000000000000'
# Delegated permission scope id for Microsoft Graph: User.Read
$MsGraphUserReadScopeId = 'e1fe6dd8-ba31-4d61-89e7-88639da4683d'

function Require-Command {
  param([string] $Name)

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Error: $Name is not installed or not on PATH."
  }
}

function Invoke-AzJson {
  param(
    [Parameter(Mandatory=$true)][string[]] $Args
  )

  $raw = & az @Args
  if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI command failed: az $($Args -join ' ')"
  }

  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $null
  }

  return $raw | ConvertFrom-Json
}

function Invoke-AzVoid {
  param(
    [Parameter(Mandatory=$true)][string[]] $Args
  )

  & az @Args | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI command failed: az $($Args -join ' ')"
  }
}

function Ensure-AzLogin {
  try {
    & az account show --output none | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'not logged in' }
  } catch {
    throw "You are not logged in to Azure. Please run 'az login' first."
  }
}

Write-Host "========================================" -ForegroundColor Blue
Write-Host "diagramHub Entra ID Setup" -ForegroundColor Blue
Write-Host "========================================" -ForegroundColor Blue
Write-Host ""

Require-Command -Name 'az'
Ensure-AzLogin

$redirectUri = "{0}://{1}" -f $AppScheme, $AppFqdn

Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Application Name: $AppName"
Write-Host "  App FQDN: $AppFqdn"
Write-Host "  App Scheme: $AppScheme"
Write-Host "  Redirect URI: $redirectUri"
Write-Host ""

# Step 1: Create or reuse the application
Write-Host "Step 1: Creating (or reusing) application registration..." -ForegroundColor Blue

$existingApps = Invoke-AzJson -Args @('ad','app','list','--display-name', $AppName,'--output','json')
$existingCount = 0
if ($null -ne $existingApps) {
  if ($existingApps -is [System.Array]) { $existingCount = $existingApps.Count }
  else { $existingCount = 1; $existingApps = @($existingApps) }
}

[string] $appId = ''
[string] $appObjId = ''

if ($existingCount -gt 0) {
  if ($existingCount -gt 1) {
    Write-Host "WARNING: Found multiple app registrations named '$AppName'. Using the first match." -ForegroundColor Yellow
  } else {
    Write-Host "WARNING: Found an existing application instance. We will patch it." -ForegroundColor Yellow
  }

  $appId = [string] $existingApps[0].appId
  $appObjId = [string] $existingApps[0].id
} else {
  $created = Invoke-AzJson -Args @('ad','app','create','--display-name', $AppName,'--sign-in-audience','AzureADMyOrg','--output','json')
  $appId = [string] $created.appId
  $appObjId = [string] $created.id
}

Write-Host "✓ Application ready" -ForegroundColor Green
Write-Host "  Client ID: $appId"
Write-Host "  Object ID: $appObjId"
Write-Host ""

# Step 2: Configure as Single-Page Application (SPA)
Write-Host "Step 2: Configuring as Single-Page Application..." -ForegroundColor Blue

$currentApp = Invoke-AzJson -Args @('ad','app','show','--id', $appId,'--output','json')
$redirectUris = @()
if ($null -ne $currentApp.spa -and $null -ne $currentApp.spa.redirectUris) {
  $redirectUris = @($currentApp.spa.redirectUris)
}

if (-not ($redirectUris -contains $redirectUri)) {
  $redirectUris = $redirectUris + @($redirectUri)
}

$spaPatch = @{ spa = @{ redirectUris = $redirectUris } } | ConvertTo-Json -Depth 6 -Compress
$spaPatch = $spaPatch -replace '"', '\"'
Invoke-AzVoid -Args @('rest','--method','PATCH','--uri',"https://graph.microsoft.com/v1.0/applications/$appObjId",'--headers','Content-Type=application/json','--body',$spaPatch)

Write-Host "✓ SPA configuration applied" -ForegroundColor Green
Write-Host ""

# Step 3: Expose an API and create scope
Write-Host "Step 3: Exposing API and creating scope..." -ForegroundColor Blue

$identifierUrisJson = @("api://$appId") | ConvertTo-Json -Compress
$identifierUrisJson = $identifierUrisJson -replace '"', '\"'
$identifierUrisJson="[$identifierUrisJson]"
Invoke-AzVoid -Args @('ad','app','update','--id',$appId,'--set',"identifierUris=$identifierUrisJson")

Write-Host "✓ API exposed with URI: api://$appId" -ForegroundColor Green
Write-Host ""

# Step 4: Add the user_impersonation scope
Write-Host "Step 4: Adding scope..." -ForegroundColor Blue

$currentApp = Invoke-AzJson -Args @('ad','app','show','--id', $appId,'--output','json')
$scopes = @()
if ($null -ne $currentApp.api -and $null -ne $currentApp.api.oauth2PermissionScopes) {
  $scopes = @($currentApp.api.oauth2PermissionScopes)
}

$scopeExists = ($scopes | Where-Object { $_.value -eq $ScopeName } | Measure-Object).Count -gt 0

if ($scopeExists) {
  Write-Host "✓ Scope '$ScopeName' already exists" -ForegroundColor Green
} else {
  $scopeUuid = [guid]::NewGuid().ToString().ToLowerInvariant()

  $newScope = [ordered]@{
    adminConsentDescription = $ScopeDescription
    adminConsentDisplayName = $ScopeName
    id = $scopeUuid
    isEnabled = $true
    type = 'User'
    userConsentDescription = $ScopeDescription
    userConsentDisplayName = $ScopeName
    value = $ScopeName
  }

  $updatedScopes = @($scopes + @($newScope))
  $scopePatch = @{ api = @{ oauth2PermissionScopes = $updatedScopes } } | ConvertTo-Json -Depth 12 -Compress
  $scopePatch = $scopePatch -replace '"', '\"'

  Invoke-AzVoid -Args @('rest','--method','PATCH','--uri',"https://graph.microsoft.com/v1.0/applications/$appObjId",'--headers','Content-Type=application/json','--body',$scopePatch)

  Write-Host "✓ Scope '$ScopeName' added" -ForegroundColor Green
}
Write-Host ""

# Step 5: Add default Microsoft Graph delegated permission User.Read
Write-Host "Step 5: Adding default Microsoft Graph permission (User.Read)..." -ForegroundColor Blue

$currentApp = Invoke-AzJson -Args @('ad','app','show','--id', $appId,'--output','json')
$requiredAccess = @()
if ($null -ne $currentApp.requiredResourceAccess) {
  $requiredAccess = @($currentApp.requiredResourceAccess)
}

$graphEntry = $requiredAccess | Where-Object { $_.resourceAppId -eq $MsGraphResourceAppId } | Select-Object -First 1
$graphResourceAccess = @()
if ($null -ne $graphEntry -and $null -ne $graphEntry.resourceAccess) {
  $graphResourceAccess = @($graphEntry.resourceAccess)
}

$userReadExists = ($graphResourceAccess | Where-Object { ($_.id -eq $MsGraphUserReadScopeId) -and ($_.type -eq 'Scope') } | Measure-Object).Count -gt 0

if ($userReadExists) {
  Write-Host "✓ Microsoft Graph delegated permission 'User.Read' already present" -ForegroundColor Green
} else {
  Invoke-AzVoid -Args @('ad','app','permission','add','--id',$appId,'--api',$MsGraphResourceAppId,'--api-permissions',"$MsGraphUserReadScopeId=Scope")

  Write-Host "✓ Microsoft Graph delegated permission 'User.Read' added" -ForegroundColor Green
  Write-Host "Note: Depending on your tenant policies, you may need to grant consent for this permission in the Entra portal." -ForegroundColor Yellow
  Write-Host "      Azure CLI may also suggest running: az ad app permission grant --id $appId --api $MsGraphResourceAppId" -ForegroundColor Yellow
}
Write-Host ""

# Step 6: Get tenant information
Write-Host "Step 6: Retrieving tenant information..." -ForegroundColor Blue
$tenantId = (& az account show --query tenantId --output tsv)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tenantId)) {
  throw 'Failed to retrieve tenant id from az account show.'
}

Write-Host "✓ Tenant ID: $tenantId" -ForegroundColor Green
Write-Host ""

# Step 7: Display summary
Write-Host "========================================" -ForegroundColor Blue
Write-Host "Setup Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Blue
Write-Host ""
Write-Host "Add the following to your .env file:"
Write-Host ""
Write-Host "ENTRA_TENANT_ID=$tenantId"
Write-Host "ENTRA_CLIENT_ID=$appId"
Write-Host ""
Write-Host "Additional Configuration:"
Write-Host "  - Application Name: $AppName"
Write-Host "  - Redirect URI: $redirectUri"
Write-Host ""
