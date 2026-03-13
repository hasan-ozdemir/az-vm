# az-vm-task-meta: {"priority":133,"timeout":180,"enabled":true,"assets":[{"local":"app-state/managed-app-state-common.psm1","remote":"C:/Windows/Temp/az-vm-managed-app-state-common.psm1"},{"local":"app-state/managed-app-state-manifest.json","remote":"C:/Windows/Temp/az-vm-managed-app-state-manifest.json"}]}
$ErrorActionPreference = "Stop"
Write-Host "Update task started: restore-managed-app-state"

$manifestPath = 'C:\Windows\Temp\az-vm-managed-app-state-manifest.json'
$modulePath = 'C:\Windows\Temp\az-vm-managed-app-state-common.psm1'
$companyName = '__COMPANY_NAME__'
$employeeEmailAddress = '__EMPLOYEE_EMAIL_ADDRESS__'
$managerUser = '__VM_ADMIN_USER__'
$assistantUser = '__ASSISTANT_USER__'

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw ("Managed app-state manifest was not found: {0}" -f $manifestPath)
}
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw ("Managed app-state helper module was not found: {0}" -f $modulePath)
}

Import-Module $modulePath -Force -DisableNameChecking

$result = Invoke-ManagedAppStateRestore `
    -ManifestPath $manifestPath `
    -CompanyName $companyName `
    -EmployeeEmailAddress $employeeEmailAddress `
    -ManagerUser $managerUser `
    -AssistantUser $assistantUser

Write-Host ("managed-app-state-summary => apps={0}; machine-directories={1}; profile-directories={2}; profile-files={3}" -f `
    [int]$result.AppCount, `
    [int]$result.MachineDirectoryCount, `
    [int]$result.ProfileDirectoryCount, `
    [int]$result.ProfileFileCount)
Write-Host "restore-managed-app-state-completed"
Write-Host "Update task completed: restore-managed-app-state"
