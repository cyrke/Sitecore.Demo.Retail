Set-ExecutionPolicy Unrestricted �scope CurrentUser
if (-Not ($PSVersionTable.PSVersion.Major -ge 4)) { Write-Host "Update version of powershell"; exit }

#If Install-Module is not available - install https://www.microsoft.com/en-us/download/details.aspx?id=51451
if(-Not (Get-Module -ListAvailable -Name Carbon)) { Install-Module -Name Carbon -AllowClobber; Import-Module Carbon}

Import-Module $PSScriptRoot\Scripts\Commerce\ManageUser.psm1 -Force
Import-Module $PSScriptRoot\Scripts\Commerce\ManageFile.psm1 -Force
Import-Module $PSScriptRoot\Scripts\Commerce\ManageCommerceServer.psm1 -Force
Import-Module $PSScriptRoot\Scripts\Commerce\ManageIIS.psm1 -Force
Import-Module $PSScriptRoot\Scripts\Commerce\ManageRegistry.psm1 -Force
Import-Module $PSScriptRoot\Scripts\Commerce\ManageDotNet.psm1 -Force
Import-Module $PSScriptRoot\Scripts\Commerce\ManageWeb.psm1 -Force
Import-Module $PSScriptRoot\Scripts\Commerce\ManageSqlServer.psm1 -Force
cd $PSScriptRoot

If ((ManageUser\Confirm-Admin) -ne $true) { Write-Host "Please run script as administrator"; exit }
If ((ManageRegistry\Get-InternetExplorerEnhancedSecurityEnabled -Verbose) -eq $true) { Write-Host "Please disable Internet Explorer Enhanced Security"; exit }

$settings = ((Get-Content $PSScriptRoot\install-commerce-config.json -Raw) | ConvertFrom-Json)
$runTimeUserSetting = ($settings.accounts | Where { $_.id -eq "runTime" } | Select)

$installFolderSetting = ($settings.resources | Where { $_.id -eq "install" } | Select)
If ($installFolderSetting -eq $null) { Write-Host "Expected install resources" -ForegroundColor red; exit; }
  
$csResourceFolderSetting = ($settings.resources | Where { $_.id -eq "commerceServerResources" } | Select)
If ($csResourceFolderSetting -eq $null) { Write-Host "Expected dacpac resources" -ForegroundColor red; exit; }         
# Step 0: check if all files exist that are needed
Write-Host "`nStep 0: Checking if all needed files exist" -foregroundcolor Yellow
if ((ManageFile\Confirm-Resources $settings.resources -verbose) -ne 0) { Exit }

Import-Module CSPS -Force

# Step 5: Create IIS App Pools
Write-Host "`nStep 5: Create IIS App Pools" -foregroundcolor Yellow
If((ManageIIS\New-AppPool -appPoolSettingList $settings.iis.appPools -accountSettingList $settings.accounts -Verbose) -ne 0) { Exit }

# Step 6: Create IIS Websites
Write-Host "`nStep 6: Create IIS Websites" -foregroundcolor Yellow
If((ManageIIS\New-Website -websiteSettingList $settings.iis.websites -appPoolSettingList $settings.iis.appPools -Verbose) -ne 0) { Exit }

# Step 7: Configure host file
Write-Host "`nStep 7: Configure Host File" -foregroundcolor Yellow
If((ManageIIS\Set-HostFile -hostEntryList $settings.iis.hostEntries -Verbose) -ne 0) { Exit }

# Step 8: Create Commerce Server Site
Write-Host "`nStep 8: Create Commerce Server Site" -foregroundcolor Yellow
If((ManageCommerceServer\New-CSWebsite -csSiteSetting $settings.sitecoreCommerce.csSite -accountSettingList $settings.accounts -appPoolSettingList $settings.iis.appPools -websiteSettingList $settings.iis.websites -installFolderSetting $installFolderSetting -databaseSettingList $settings.databases -Verbose) -ne 0) { Exit }

# Step 9: Import Database Changes
Write-Host "`nStep 9: Import Database Changes" -foregroundcolor Yellow
If((ManageSqlServer\Import-DatabaseChanges -databaseSettingList $settings.databases -resourcesSettingList $settings.resources -resourceFolderId "foundationDatabaseScripts"  -Verbose) -ne 0) { Exit }
If((ManageSqlServer\Import-DatabaseChanges -databaseSettingList $settings.databases -resourcesSettingList $settings.resources -resourceFolderId "projectDatabaseScripts"  -Verbose) -ne 0) { Exit }

# Step 10: Import Commerce Server Resources
Write-Host "`nStep 10: Import Commerce Server Resources" -foregroundcolor Yellow
If((ManageCommerceServer\Import-CSSiteData -csSiteSetting $settings.sitecoreCommerce.csSite -csResourceFolderSetting $csResourceFolderSetting -Verbose) -ne 0) { Exit }

# Step 11: Disable-LoopbackCheck (for development machines)
Write-Host "`nStep 11: Disable-LoopbackCheck (for development machines)" -foregroundcolor Yellow
ManageRegistry\Disable-LoopbackCheck

# Step 12: Test Commerce Server WebServices
Write-Host "`nStep 12: Test Commerce Server WebServices" -foregroundcolor Yellow
If((ManageCommerceServer\Test-CSWebservices -csSiteSetting $settings.sitecoreCommerce.csSite -accountSettingList $settings.accounts -appPoolSettingList $settings.iis.appPools -websiteSettingList $settings.iis.websites -Verbose) -ne 0) { Exit }

# Step 13: Restore Solution Packages 
Write-Host "`nStep 13: Restore Solution Packages" -foregroundcolor Yellow
If((ManageDotNet\Restore-SolutionPackages -resourcesSettingList $settings.resources -resourceId "solutionRoot" -Verbose) -ne 0) { Exit }
cd $PSScriptRoot

# Step 14: Deploy Commerce Engine
Write-Host "`nStep 14: Deploy Commerce Engine" -foregroundcolor Yellow
If((ManageDotNet\Publish-Project -resourcesSettingList $settings.resources -websiteSettingList $settings.iis.websites -sourceResourceId "commerceEngineProject" -targetWebsiteId "commerceEngine" -Verbose) -ne 0) { Exit }

# Step 15: Test Commerce Engine
Write-Host "`nStep 15: Test Commerce Engine" -foregroundcolor Yellow
If((ManageWeb\Invoke-WebRequest -websiteSettingList $settings.iis.websites -websiteId "commerceEngine" -relativeUri "api/`$metadata" -Verbose) -ne 0) { Exit }

# Step 16: Create self signed certificate
Write-Host "`nStep 16: Create self signed certificates" -foregroundcolor Yellow
If((ManageIIS\New-Certificate -certificateSettingList $settings.iis.certificates -installFolderSetting $installFolderSetting -Verbose) -ne 0) { Exit }

# Step 17: Bootstrap Commerce Engine and Initialise Environments
Write-Host "`nStep 17: Test Commerce Engine" -foregroundcolor Yellow
If((ManageWeb\Invoke-WebRequest -websiteSettingList $settings.iis.websites -websiteId "commerceEngine" -relativeUri "commerceops/Bootstrap()" -errorString "*ResponseCode`":`"Error*" -Verbose) -ne 0) { Exit }
If((ManageWeb\Invoke-WebRequest -websiteSettingList $settings.iis.websites -websiteId "commerceEngine" -relativeUri "commerceops/InitializeEnvironment(environment='HabitatShops')" -errorString "*ResponseCode`":`"Error*" -Verbose) -ne 0) { Exit }
If((ManageWeb\Invoke-WebRequest -websiteSettingList $settings.iis.websites -websiteId "commerceEngine" -relativeUri "commerceops/InitializeEnvironment(environment='HabitatAuthoring')" -errorString "*ResponseCode`":`"Error*" -Verbose) -ne 0) { Exit }