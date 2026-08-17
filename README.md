# 🔄 Autopatch User Group Sync

Automation that keeps Autopatch **user** ring groups in sync with the
**device** ring groups in Intune/Entra, via `scripts/Autopatch-User-Group-Sync.ps1`.

## 🧭 What it does

For each ring, every device in the ring's *device* group has its primary
user looked up in Intune, and that user is placed in the ring's matching
*user* group. Only the difference between "who should be in the group" and
"who is in the group" is applied — the script never wipes a group outright.

Rules:
- A user with devices in two rings keeps the **earliest** ring; the
  conflict is reported, not silently resolved.
- A user in the all-users group whose devices didn't place them in any
  ring (e.g. long-term leave) falls back to the **last** ring.
- Users in the exclusion group are never placed in any ring.

See the script header in `scripts/user-group-syncv3.ps1` for the full
safety-feature list (dry run, circuit breaker on mass removals, empty-group
guard, convergent retries).

## ⚡ How it looks up users and devices

The script builds a few in-memory lookup tables (PowerShell hashtables) as
it runs, instead of calling Graph again every time it needs to check a
device or a user:

- `$deviceOwner` - every Intune device, keyed by device ID, fetched once.
- `$userRing` - which ring each user should be in, keyed by user ID.
- `$userName` - each user's display name (UPN), keyed by user ID.

A hashtable is just a key -> value lookup, so finding an entry is
near-instant regardless of how many devices or users are in it. Without
this, the script would need a fresh Graph API call every time it wanted to
check a single device or user - with a hashtable, it's one bulk request up
front, then everything else is a free, local lookup. That keeps the script
fast and avoids hitting Graph API request limits as your tenant grows.

## 👥 Groups it syncs

Configured in the `$RingMap` / `$ExclusionGroupId` / `$AllUsersGroupId`
variables at the top of `scripts/user-group-syncv3.ps1` (Entra group Object
IDs). The script re-resolves and prints each group's live display name at
the start of every run (Step 2), so that's the source of truth if this
table ever drifts:

| Ring | Device group (Autopatch) | User group |
|---|---|---|
| 0 (earliest) | Devices-Test | Users - Test Ring |
| 1 | Devices-Ring 1 | Users - First Ring |
| 2 | Devices-Ring2 | Users - Fast Ring |
| 3 (last / fallback) | Devices-Ring 3 | Users - Broad Ring |

Plus two supporting groups (not rings themselves):

| Purpose | Group |
|---|---|
| Exclusion list | Users-Ring-Exclusions |
| All-staff scope (drives the ring-3 fallback) | Users-AllStaff |

## 🚀 Running it

Runs via `.github/workflows/SyncGroups.yml`, authenticating to Microsoft
Graph with an OIDC-federated Entra app (no stored secrets). See that
workflow for the exact permission scopes requested.

## 📜 Run history

Every run is verbose. Check your job history to see what happened on each run.

## 🛠️🧰 Getting set up

### 💻 Running manually

1. 📦 Install the Graph PowerShell modules the script needs:
   ```powershell
   Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.DeviceManagement -Scope CurrentUser
   ```
2. ⚙️ In the Config block at the top of `scripts/user-group-syncv3.ps1`, set
   `$runningInAutomation = $false` (so it prompts an interactive sign-in)
   and start with `$DryRun = $true` 🧪 so nothing is changed on your first run.
3. 🆔 Update `$RingMap`, `$ExclusionGroupId`, and `$AllUsersGroupId` with your
   tenant's group Object IDs (Entra portal -> Groups -> copy Object ID).
4. ▶️ Run it:
   ```powershell
   ./scripts/user-group-syncv3.ps1
   ```
   🔐 You'll be prompted to sign in. Your account needs read access to group
   membership and Intune devices, plus ownership of the ring user groups
   once you're ready to turn `$DryRun` off.

### 🤖 Setting up in GitHub Actions

The workflow (`.github/workflows/SyncGroups.yml`) signs in via OIDC 🔑 - no
stored client secret. To help you get setup, a helper script
(`./scripts/Autopatch-UserGroups-Setup-Helper.ps1`) is included. This will
complete the following tasks (feel free to do manually if you prefer):

1. 📝 Register an Entra app registration (or reuse one) and grant it the
   Graph application permissions the script needs plus ownership of the
   user ring groups:
   `Device.Read.All`
   `DeviceManagementManagedDevices.Read.All`
   `GroupMember.Read.All`
   `User.ReadBasic.All`
2. 👥 Create (or use existing) user groups
3. 🔗 Add a federated credential on that app for GitHub Actions, scoped to
   this repo/branch.

Beyond the script itself, you'll also need to:
1. 🔒 Add two repository secrets (or vars): `AZURE_CLIENT_ID` and
   `AZURE_TENANT_ID`.

🚦 Trigger it manually first via **Actions -> Sync Groups -> Run workflow**
to confirm sign-in and permissions are correct before relying on the
⏰ `schedule` trigger.
