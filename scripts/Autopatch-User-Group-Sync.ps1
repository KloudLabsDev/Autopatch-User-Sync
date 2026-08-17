<#
    Autopatch User Ring Sync v1
    Connor Kirby
    KloudLabsDev
    August 2026

    Purpose:
    To provide automation for keeping the Autopatch user ring groups in sync with the Autopatch device ring groups. This is a common requirement for organizations 
    using Microsoft Autopatch, where devices are grouped into rings for phased deployment of updates, and users need to be placed into corresponding user groups 
    based on their devices ring assignments.

    Key features:
    - Automatically syncs users to the correct Autopatch user ring groups based on their devices
    - Convergent behavior: script is idempotent and will correct any drift
    - Safety mechanisms: dry run mode, circuit breakers, and exclusion groups
    - Detailed logging: comprehensive output for auditing and troubleshooting

    Safety Features:
    - Dry Run Mode: When enabled, the script will only simulate changes without making any modifications
    - Circuit Breaker: Stops execution if the number of planned removals exceeds a defined threshold
    - Exclusion Group: Users in this group are never added to any ring
    - Empty Group Check: Stops execution if any device group is found to be empty, preventing accidental clearing of user groups

    Permissions:
    - Requires read permissions for group membership and Intune devices
    - Requires ownership of the user ring groups to perform add/remove operations - can only update those specific groups, not others in your tenant.

    Graph Commands Used:
      Connect-MgGraph                        - sign in (or use existing connection if used in GitHub Actions)
      Get-MgGroup -GroupId X                 - get one group's details
      Get-MgGroupMember -GroupId X -All      - list everything in a group
      New-MgGroupMember                      - add one member to a group
      Remove-MgGroupMemberByRef              - remove one member from a group
      Get-MgDeviceManagementManagedDevice    - list Intune devices
#>

function Show-Banner {
    Write-Host ""
    Write-Host "################################################################"
    Write-Host "##                                                            ##"
    Write-Host "##   KloudLabsDev  //  Autopatch User Ring Sync               ##"
    Write-Host "##                                                            ##"
    Write-Host "################################################################"
    Write-Host ""
    Write-Host "  >> Version........ 1.0"
    Write-Host "  >> Source......... https://github.com/KloudLabsDev/Autopatch-User-Sync"
    Write-Host "  >> Author......... Connor Kirby"

    Write-Host " "
}

# --- Config: update these values to match your tenant's groups ---

# $DryRun - if set to $true, the script will not make any 
# changes, it will only print what it would do.
$DryRun = $false

# $emptygroupIsFatal - if set to $true, the script will stop 
# if any device group is empty. This is a safety feature to 
# prevent accidental removal of all users from a ring group.
$emptygroupIsFatal = $false 

# $runningInAutomation - if set to $true, the script will 
# not prompt for user input. This is useful for running the 
#script in an automation context (e.g. GitHub Actions). If 
# set to $false, the script will prompt for user input 
# before making any changes.
$runningInAutomation = $true 

# $MaxRemovals - if the script wants to remove more than this 
# number of users, it will stop without making any changes. 
$MaxRemovals = 10 

$RingMap = @(
    @{  # Devices-Test -> Users-Test
        DeviceGroupId = '11111111-1111-1111-1111-111111111111'
        UserGroupId   = '22222222-2222-2222-2222-222222222222'
    },
    @{  # Devices-Ring 1 -> Users-Ring1
        DeviceGroupId = '33333333-3333-3333-3333-333333333333'
        UserGroupId   = '44444444-4444-4444-4444-444444444444'
    },
    @{  # Devices-Ring2 -> Users-Ring2
        DeviceGroupId = '55555555-5555-5555-5555-555555555555'
        UserGroupId   = '66666666-6666-6666-6666-666666666666'
    },
    @{  # Devices-Ring 3 -> Users-Ring3
        DeviceGroupId = '77777777-7777-7777-7777-777777777777'
        UserGroupId   = '88888888-8888-8888-8888-888888888888'
    }
)

# Users-Ring-Exclusions
# Users in this group are never added to any ring.
$ExclusionGroupId = '99999999-9999-9999-9999-999999999999'

# Users-AllStaff (or similar)
# Users in this group are checked at the end: if they didn't get
# placed in a ring by their devices, they're added to the LAST ring.
$AllUsersGroupId = '00000000-0000-0000-0000-000000000000'



# --- Sign into Graph or validate existing connection ---
# If not running in automation, prompt for sign-in. If running in automation, 
# validate that a connection already exists.
    if ($runningInAutomation -ne $true) {
        Connect-MgGraph -NoWelcome -Scopes @(
            'GroupMember.Read.All',                    
            'DeviceManagementManagedDevices.Read.All',
            'Device.Read.All',
            'User.ReadBasic.All'  
        )
    }
    else {
        if (-not (Get-MgContext)) {
            throw "STOPPING: `$runningInAutomation is `$true but there is no active Graph connection. The workflow must call Connect-MgGraph before running this script."
        }
        Write-Host "Running in automation - using existing Graph connection." -ForegroundColor Cyan
    }


# --- Validate group IDs and get their names ---
# If an ID is wrong, Get-MgGroup errors and the script stops here, before
# anything has changed. 
Show-Banner
Write-Host 'Checking groups...' -ForegroundColor Cyan

foreach ($ring in $RingMap) {
    $ring.DeviceGroupName = (Get-MgGroup -GroupId $ring.DeviceGroupId).DisplayName
    $ring.UserGroupName   = (Get-MgGroup -GroupId $ring.UserGroupId).DisplayName
    Write-Host "  $($ring.DeviceGroupName) -> $($ring.UserGroupName)"
}

$exclusionGroupName = (Get-MgGroup -GroupId $ExclusionGroupId).DisplayName
Write-Host "  Exclusion list: $exclusionGroupName"

$allUsersGroupName = (Get-MgGroup -GroupId $AllUsersGroupId).DisplayName
Write-Host "  All-users scope: $allUsersGroupName"


# --- Load the exclusion list ---
# Get-MgGroupMember returns "directory objects" which can be users, devices,
# or nested groups. The '@odata.type' field tells us which kind each one is
# - we keep only the users, then keep only their IDs.
$excludedUsers = @(Get-MgGroupMember -GroupId $ExclusionGroupId -All |
    Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.user' } |
    Select-Object -ExpandProperty Id)
Write-Host "  $($excludedUsers.Count) users on the exclusion list"


# --- Load all Intune devices ---
# Builds a lookup table keyed by AzureAdDeviceId so we can find a device's
# primary user later without calling Get-MgDeviceManagementManagedDevice
# again for every device in every ring.
#   $deviceOwner['<device id>'] gives back that device's record.
Write-Host 'Loading Intune devices...' 

$deviceOwner = @{}

$allDevices = Get-MgDeviceManagementManagedDevice -All
foreach ($device in $allDevices) {
    # skip devices with no Entra identity or no primary user (kiosks etc.)
    if (-not $device.AzureAdDeviceId) { continue }
    if (-not $device.UserId)          { continue }

    $deviceOwner[$device.AzureAdDeviceId] = $device
}
Write-Host "  $($deviceOwner.Count) devices have a primary user"

# TEMP DEBUG
# Write-Host "`n  ---- `$deviceOwner (sample) ----" -ForegroundColor Cyan
# $deviceOwner.GetEnumerator() | Select-Object -First 5 @{N='DeviceId';E={$_.Key}}, @{N='UserPrincipalName';E={$_.Value.UserPrincipalName}}, @{N='DeviceName';E={$_.Value.DeviceName}} | Format-Table -AutoSize


# --- Determine which ring each user belongs in ---
# Go through device groups in order (Test first). The first ring a user is
# in is the one they keep - a second device in a later ring is a conflict,
# recorded for the report, not acted on.
#
# Safety: if a device group has zero devices in it, something is likely
# wrong, so the script stops rather than emptying the matching user group.
#
#   $userRing['<user id>'] = ring number they should be in (0-3)
#   $userName['<user id>'] = their UPN, only used for messages
$userRing   = @{}
$userName   = @{}
$conflicts  = @()
$ringNumber = 0

foreach ($ring in $RingMap) {
    Write-Host "Reading '$($ring.DeviceGroupName)'..." -ForegroundColor Cyan
    $deviceCount = 0

    $members = Get-MgGroupMember -GroupId $ring.DeviceGroupId -All
    foreach ($member in $members) {

        # ignore anything in the group that isn't a device
        if ($member.AdditionalProperties.'@odata.type' -ne '#microsoft.graph.device') { continue }
        $deviceCount++

        # find this device in the Intune lookup.
        # note: a group member's "deviceId" property is the same ID
        # that Intune calls "AzureAdDeviceId" - that's the link.
        $deviceId = $member.AdditionalProperties.deviceId
        if (-not $deviceId) {
            Write-Host "  WARNING: device in '$($ring.DeviceGroupName)' has no deviceId (likely a permission issue) - skipped" -ForegroundColor Red
            continue
        }
        $device = $deviceOwner[$deviceId]

        # not in Intune / no primary user -> nothing to do
        if (-not $device) { continue }

        # on the exclusion list -> skip them
        if ($excludedUsers -contains $device.UserId) { continue }

        if ($userRing.ContainsKey($device.UserId)) {
            # already placed by a device in an EARLIER ring -> conflict
            $conflicts += "$($device.UserPrincipalName): '$($device.DeviceName)' is in $($ring.DeviceGroupName), but they were already placed by a device in an earlier ring"
        }
        else {
            # first device we've seen for this user -> this is their ring
            $userRing[$device.UserId] = $ringNumber
            $userName[$device.UserId] = $device.UserPrincipalName
        }
    }

    if ($deviceCount -eq 0 -and $emptygroupIsFatal -eq $true) {
        throw "STOPPING: '$($ring.DeviceGroupName)' contains no devices. That almost certainly means an upstream problem, and continuing would empty '$($ring.UserGroupName)'. Nothing has been changed."
    }

    $ringNumber++
}

# --- Catch users who didn't get placed by a device ---
# Anyone in the all-users group who wasn't placed in a ring by their devices
# (e.g. long-term leave, mobile-only) is added to the last ring so their
# user policy stays applied.
$lastRingNumber = $RingMap.Count - 1 #the last loop will have increaed $ringNumber one too far, so subtract 1 to get the last ring number
$fallbackCount  = 0

$members = Get-MgGroupMember -GroupId $AllUsersGroupId -All
foreach ($member in $members) {

    # ignore anything in the group that isn't a user
    if ($member.AdditionalProperties.'@odata.type' -ne '#microsoft.graph.user') { continue }

    if ($excludedUsers -contains $member.Id)   { continue }   # excluded
    if ($userRing.ContainsKey($member.Id))     { continue }   # already placed by a device

    $userRing[$member.Id] = $lastRingNumber
    $userName[$member.Id] = $member.AdditionalProperties.userPrincipalName
    $fallbackCount++
}
Write-Host "  $fallbackCount users from '$allUsersGroupName' had no ring -> $($RingMap[$lastRingNumber].UserGroupName)"


# --- Plan the changes (nothing applied yet) ---
# For each user group, compare who should be in it against who is in it,
# and record the differences in $plannedAdds / $plannedRemoves. Each entry
# keeps the ring number, user ID, and UPN, so removals can be reported by
# name, not GUID.
$plannedAdds    = @()
$plannedRemoves = @()
$ringNumber     = 0

foreach ($ring in $RingMap) {
    Write-Host "Planning '$($ring.UserGroupName)'..." 

    # --- who SHOULD be in this group ---
    $wanted = @($userRing.Keys | Where-Object { $userRing[$_] -eq $ringNumber })

    # --- who IS in this group right now (ID + name) ---
    $members = Get-MgGroupMember -GroupId $ring.UserGroupId -All |
        Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.user' }
    $current = @($members | Select-Object -ExpandProperty Id)
    $ring.CurrentCount = $current.Count
    # remember their names too, so removals can show a UPN
    foreach ($member in $members) {
        $userName[$member.Id] = $member.AdditionalProperties.userPrincipalName
    }

    # --- differences ---
    foreach ($userId in $wanted) {
        if ($current -contains $userId) { continue }   # already in, skip
        $plannedAdds += @{ RingNumber = $ringNumber; UserId = $userId; Upn = $userName[$userId] }
    }

    foreach ($userId in $current) {
        if ($wanted -contains $userId) { continue }    # still belongs, skip
        $plannedRemoves += @{ RingNumber = $ringNumber; UserId = $userId; Upn = $userName[$userId] }
    }

    $ringNumber++
}


# --- Safety check: max removals ---
# Circuit breaker - if the plan wants to remove more users than
# $MaxRemovals, the script stops without changing anything.
if ($plannedRemoves.Count -gt $MaxRemovals) {
    if ($DryRun) {
        Write-Host "WARNING: plan wants to remove $($plannedRemoves.Count) users (limit $MaxRemovals). A live run would STOP here." -ForegroundColor Red
    }
    else {
        throw "STOPPING: plan wants to remove $($plannedRemoves.Count) users, which is over the `$MaxRemovals limit of $MaxRemovals. Nothing has been changed. If this is a genuine reshuffle, raise `$MaxRemovals and re-run."
    }
}


# --- Update groups ---
# One failed add/remove is logged and counted, but doesn't stop the run -
# the next scheduled run will catch it up.
Write-Host 'Applying changes...' -ForegroundColor Cyan
$failures = 0

foreach ($change in $plannedAdds) {
    $ring = $RingMap[$change.RingNumber]

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would ADD    $($change.Upn) -> $($ring.UserGroupName)"
        continue
    }

    try {
        New-MgGroupMember -GroupId $ring.UserGroupId -DirectoryObjectId $change.UserId
        Write-Host "  ADDED   $($change.Upn) -> $($ring.UserGroupName)"
    }
    catch {
        Write-Host "  FAILED to add $($change.Upn) to $($ring.UserGroupName): $_" -ForegroundColor Red
        $failures = $failures + 1
    }
}

foreach ($change in $plannedRemoves) {
    $ring = $RingMap[$change.RingNumber]

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would REMOVE $($change.Upn) from $($ring.UserGroupName)"
        continue
    }

    try {
        Remove-MgGroupMemberByRef -GroupId $ring.UserGroupId -DirectoryObjectId $change.UserId
        Write-Host "  REMOVED $($change.Upn) from $($ring.UserGroupName)"
    }
    catch {
        Write-Host "  FAILED to remove $($change.Upn) from $($ring.UserGroupName): $_" -ForegroundColor Red
        $failures = $failures + 1
    }
}

    if ($plannedRemoves.Count -eq 0 -and $plannedAdds.Count -eq 0) {
        Write-Host "  No changes needed - all groups are up to date."
    }


# --- Summary output ---
# Per-ring counts, conflicts, and anything that needs a human.
Write-Host "`n================ SUMMARY ================" -ForegroundColor Green
if ($DryRun) {
    Write-Host "DRY RUN ONLY - nothing was changed. Set `$DryRun = `$false to apply." -ForegroundColor Yellow
}

$ringNumber = 0
foreach ($ring in $RingMap) {
    $addCount    = 0
    $removeCount = 0
    foreach ($change in $plannedAdds)    { if ($change.RingNumber -eq $ringNumber) { $addCount    = $addCount    + 1 } }
    foreach ($change in $plannedRemoves) { if ($change.RingNumber -eq $ringNumber) { $removeCount = $removeCount + 1 } }

    Write-Host "  $($ring.UserGroupName): $($ring.CurrentCount) members (+$addCount / -$removeCount)"
    $ringNumber++
}

Write-Host "  Fallback placements into last ring: $fallbackCount"
Write-Host "  Failed operations this run: $failures"

if ($conflicts.Count -gt 0) {
    Write-Host "`nUSERS WITH DEVICES IN MULTIPLE RINGS (kept in earliest):" -ForegroundColor Yellow
    foreach ($conflict in $conflicts) {
        Write-Host "  $conflict"
    }
}
else {
    Write-Host "`nNo multi-ring conflicts." -ForegroundColor Green
}