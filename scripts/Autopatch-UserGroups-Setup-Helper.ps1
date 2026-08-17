<#
    Autopatch-UserGroups-Setup-Helper.ps1

    Helper script to get setup with using Autopatch User Sync GitHub Action. This is only required if you plan 
    to run this from a GitHub Action. If you want to run the script locally or elsewhere, you do not need to 
    run this script.


    GRAPH COMMANDS USED:
      Connect-MgGraph                              - sign in
      New-MgApplication / New-MgServicePrincipal    - create the app + SP
      New-MgApplicationFederatedIdentityCredential  - GitHub OIDC trust (optional)
      New-MgGroupOwnerByRef                         - add the SP as a group owner
      Get-MgServicePrincipal                        - look up the Microsoft Graph service principal
      New-MgServicePrincipalAppRoleAssignedTo        - grant + admin-consent a read permission
#>

function Show-Banner {
    Write-Host ""
    Write-Host "#################################################################" -ForegroundColor DarkGray
    Write-Host "##                                                             ##" -ForegroundColor DarkGray
    Write-Host "##   KloudLabsDev  //  Autopatch User Ring Sync Setup Helper   ##" -ForegroundColor DarkGray
    Write-Host "##                                                             ##" -ForegroundColor DarkGray
    Write-Host "#################################################################" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  >> Version........ 1.0" -ForegroundColor DarkGray
    Write-Host "  >> Source......... https://github.com/KloudLabsDev/Autopatch-User-Sync" -ForegroundColor DarkGray
    Write-Host "  >> Author......... Connor Kirby" -ForegroundColor DarkGray

    Write-Host " "
}

Show-Banner

# Connect to Graph with defined scopes
Connect-MgGraph -NoWelcome -Scopes @(
    'Application.ReadWrite.All',          # create the app + SP
    'Group.ReadWrite.All',                # add the SP as a group owner (one-time, by you)
    'AppRoleAssignment.ReadWrite.All'     # grant + consent the two read permissions
)


# Get Autopatch Group IDs
Write-Host 'Enter the Object ID for each (Autopatch) device group:' -ForegroundColor Cyan
$DeviceGroupIds = @(
    Read-Host '  Devices-Test'
    Read-Host '  Devices-Ring1'
    Read-Host '  Devices-Ring2'
    Read-Host '  Devices-Ring3'
) | Where-Object { $_ }

if ($DeviceGroupIds.Count -ne 4) {
    throw "STOPPING: expected 4 device group IDs but got $($DeviceGroupIds.Count) - one or more prompts were left blank."
}

Write-Host "Do the user groups already exist? (y/n): " -ForegroundColor Cyan -NoNewline
$UserGroupsExist = Read-Host

$GroupIds = @()

if ($UserGroupsExist -eq 'y') {
    Write-Host 'Enter the Object ID for each write-scoped group:' -ForegroundColor Cyan
    $GroupIds = @(
        Read-Host '  Users-Test'
        Read-Host '  Users-Ring1'
        Read-Host '  Users-Ring2'
        Read-Host '  Users-Ring3'
        Read-Host '  Users-Ring-Exclusions'
        Read-Host '  Users-AllStaff'
) | Where-Object { $_ }

    if ($GroupIds.Count -ne 6) {
    throw "STOPPING: expected 6 group IDs but got $($GroupIds.Count) - one or more prompts were left blank."
}
}

else {
    write-Host "Enter the names you'd like to create for the user groups:" -ForegroundColor Cyan
    $GroupNames = @(
        Read-Host '  Users-Test'
        Read-Host '  Users-Ring1'
        Read-Host '  Users-Ring2'
        Read-Host '  Users-Ring3'
        Read-Host '  Users-Ring-Exclusions'
        Read-Host '  Users-AllStaff'
) | Where-Object { $_ }

    if ($GroupNames.Count -ne 6) {
    throw "STOPPING: expected 6 group names but got $($WriteGroupIds.Count) - one or more prompts were left blank."
    }

    new-MgGroup -DisplayName $GroupNames[0] -MailEnabled:$false -SecurityEnabled -MailNickname $GroupNames[0] -Description "Autopatch user ring sync - Test group" | ForEach-Object { $GroupIds += $_.Id }
    new-MgGroup -DisplayName $GroupNames[1] -MailEnabled:$false -SecurityEnabled -MailNickname $GroupNames[1] -Description "Autopatch user ring sync - Ring 1" | ForEach-Object { $GroupIds += $_.Id }
    new-MgGroup -DisplayName $GroupNames[2] -MailEnabled:$false -SecurityEnabled -MailNickname $GroupNames[2] -Description "Autopatch user ring sync - Ring 2" | ForEach-Object { $GroupIds += $_.Id }
    new-MgGroup -DisplayName $GroupNames[3] -MailEnabled:$false -SecurityEnabled -MailNickname $GroupNames[3] -Description "Autopatch user ring sync - Ring 3" | ForEach-Object { $GroupIds += $_.Id }
    new-MgGroup -DisplayName $GroupNames[4] -MailEnabled:$false -SecurityEnabled -MailNickname $GroupNames[4] -Description "Autopatch user ring sync - Exclusions" | ForEach-Object { $GroupIds += $_.Id }
    new-MgGroup -DisplayName $GroupNames[5] -MailEnabled:$false -SecurityEnabled -MailNickname $GroupNames[5] -Description "Autopatch user ring sync - All Staff" | ForEach-Object { $GroupIds += $_.Id }
}

Write-host "Groups IDs are" $GroupIds

# The app registration / service principal that will run the sync script
Write-Host 'Provide a name for the app registration / service principal' -ForegroundColor Cyan
$AppName = Read-Host 
if (-not $AppName) {
    throw 'STOPPING: no name was entered for the app registration.'
}

# Optional: set up GitHub Actions OIDC federation (no client secret).
Write-Host 'Do you want to set up a GitHub Actions federated credential now? (y/n)' -ForegroundColor Cyan
$CreateFederatedCredential = Read-Host

if ($CreateFederatedCredential -eq 'y') {
    $GitHubOrg    = Read-Host '  GitHub org/owner e.g. KloudLabsDev'
    $GitHubOrgID  = Read-Host '  GitHub Org ID e.g. 12345'
    $GitHubRepo   = Read-Host '  GitHub repo e.g. AutoPatch-User-Sync'
    $GitHubRepoID = Read-Host '  GitHub Repo ID e.g. 56789'
    $GitHubBranch = Read-Host '  Branch to trust e.g. main'

    if (-not $GitHubOrg -or -not $GitHubRepo -or -not $GitHubBranch) {
        throw 'STOPPING: GitHub org, repo, and branch are all required to set up the federated credential.'
    }
}

# Create the app registration + SP
Write-Host "Creating app registration '$AppName'..." -ForegroundColor Cyan

$app = New-MgApplication -DisplayName $AppName
$sp  = New-MgServicePrincipal -AppId $app.AppId

Write-Host "  App (client) ID: $($app.AppId)"
Write-Host "  Service principal object ID: $($sp.Id)"


# Create GitHub Action OIDC Federation if selected yes
if ($CreateFederatedCredential) {
    Write-Host "Adding GitHub federated credential ($GitHubOrg/$GitHubRepo, branch $GitHubBranch)..." -ForegroundColor Cyan

    New-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -BodyParameter @{
        Name        = 'github-actions-oidc'
        Issuer      = 'https://token.actions.githubusercontent.com'
        Subject     = "repo:${GitHubOrg}@${GitHubOrgID}/${GitHubRepo}@${GitHubRepoID}:ref:refs/heads/$GitHubBranch"
        Audiences   = @('api://AzureADTokenExchange')
        Description = 'GitHub Actions OIDC - Autopatch user ring sync'
    }
}


# Add the service principal as owner of the user groups
Write-Host 'Adding SP as owner of the write-scoped groups...' -ForegroundColor Cyan

foreach ($groupId in $GroupIds) {
    New-MgGroupOwnerByRef -GroupId $groupId -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$($sp.Id)"
    Write-Host "  Owner added: group $groupId"
}


# Add and grant the read Graph permissions with admin consent
Write-Host 'Granting read permissions...' -ForegroundColor Cyan

# Microsoft Graph's own service principal
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

$readPermissions = @('GroupMember.Read.All', 'DeviceManagementManagedDevices.Read.All', 'Device.Read.All')
$appRoles = @($readPermissions | ForEach-Object {
    $permissionName = $_
    $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $permissionName }
    if (-not $appRole) { throw "Could not find the '$permissionName' app role on the Graph service principal." }
    $appRole
})

# Declare the permissions on the app registration's own manifest too - without
# this, the assignments below still work, but the portal lists them under
# "Other permissions granted" instead of "Configured permissions" because
# nothing on the app registration itself says it requires them.
Update-MgApplication -ApplicationId $app.Id -RequiredResourceAccess @(
    @{
        ResourceAppId  = $graphSp.AppId
        ResourceAccess = @($appRoles | ForEach-Object { @{ Id = $_.Id; Type = 'Role' } })
    }
)

foreach ($appRole in $appRoles) {
    New-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $graphSp.Id -BodyParameter @{
        PrincipalId = $sp.Id
        ResourceId  = $graphSp.Id
        AppRoleId   = $appRole.Id
    } | Out-Null
    Write-Host "  Granted (with admin consent): $($appRole.Value)"
}


# ============================================================
# STEP 6: SUMMARY
# ============================================================
Write-Host "`n================ SUMMARY ================" -ForegroundColor Green
Write-Host "App registration: $AppName"
Write-Host "  Application (client) ID: $($app.AppId)"
Write-Host "  Directory (tenant) ID:   $((Get-MgContext).TenantId)"
Write-Host ''
Write-Host "Write access (as group OWNER, no Graph permission):"
foreach ($groupId in $GroupIds) { Write-Host "  $groupId" }
Write-Host ''
Write-Host 'Read access (Graph application permissions, tenant-wide - see header note):'
Write-Host '  GroupMember.Read.All'
Write-Host '  DeviceManagementManagedDevices.Read.All'
Write-Host '  Device.Read.All'
Write-Host ''
Write-Host 'IMPORTANT: do NOT grant this app Group.Read.All, Group.ReadWrite.All, or' -ForegroundColor Yellow
Write-Host 'GroupMember.ReadWrite.All - any of these would give it write access to' -ForegroundColor Yellow
Write-Host 'every group in your tenant and override the ownership-based scoping above.' -ForegroundColor Yellow

if (-not $CreateFederatedCredential) {
    Write-Host "`nNo sign-in method was configured. Add either a federated credential"
    Write-Host '(recommended - set $CreateFederatedCredential = $true above and re-run)'
    Write-Host 'or a client secret before this app can authenticate.'
}


# Ring Map - copy and paste into main script

Write-Host "`n================ RING MAP ================" -ForegroundColor Green
Write-Host "Copy and paste the ouput below and directly"
Write-Host "paste over lines 74 to 101."
Write-Host ""

$RingLabels = @('Test', 'Ring 1', 'Ring2', 'Ring 3')

Write-Host '$RingMap = @('
for ($i = 0; $i -lt 4; $i++) {
    Write-Host "    @{  # Devices-$($RingLabels[$i]) -> Users-$($RingLabels[$i] -replace ' ', '')"
    Write-Host "        DeviceGroupId = '$($DeviceGroupIds[$i])'"
    $comma = if ($i -lt 3) { ',' } else { '' }
    Write-Host "        UserGroupId   = '$($GroupIds[$i])'"
    Write-Host "    }$comma"
}
Write-Host ')'
Write-Host ''
Write-Host '# Users-Ring-Exclusions'
Write-Host '# Users in this group are never added to any ring.'
Write-Host "`$ExclusionGroupId = '$($GroupIds[4])'"
Write-Host ''
Write-Host '# Users-AllStaff (or similar)'
Write-Host "# Users in this group are checked at the end: if they didn't get"
Write-Host "# placed in a ring by their devices, they're added to the LAST ring."
Write-Host "`$AllUsersGroupId = '$($GroupIds[5])'"