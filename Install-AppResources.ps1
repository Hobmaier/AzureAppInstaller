<#
 .SYNOPSIS
    Deploys a typical Azure infrastructure

 .DESCRIPTION
    This includes Azure Web App, App Service Plan, SQL Server, SQL Database, Storage Account. Use the XML file for parameters

 .PARAMETER subscriptionId
    The subscription id where the template will be deployed.

 .PARAMETER Path
    Physical File Path to deployment parameters xml, by default it uses AppParameters.xml.
.Example
    .\Install-AppResources.ps1 -Path .\AppParameters.xml

    Default behaviour, it will read the parameters from XML such as App name, Region
.Example
    .\Install-AppResources.ps1 -Path .\AppParameters.xml -SubscriptionId e2264704-9eba-45e5-9130-c28fb5cbee02
    
    This will use the subscription ID as well

#>
[cmdletBinding()]
param(
 [Parameter(Mandatory=$false)]
 [string]
 $subscriptionId,

 [Parameter(Mandatory=$false)]
 [string]
 [ValidateScript({Test-Path $_})]
 $Path

)

function Connect-App
{
    param(
        # Azure SubscriptionID
        [Parameter(Mandatory = $false)]
        [guid]
        $AzureSubscriptionID
    )

    Login-AzureRmAccount

    # Get all subscriptions
    # Get-AzureRmSubscription

    #Set default subscription for current session
    #Get-AzureRmSubscription -SubscriptionName 'Visual Studio Ultimate with MSDN' | Select-AzureRmSubscription
    if (!$AzureSubscriptionID)
    {
        $Subscription = Select-AppAzureSubscription
    } else {
        $Subscription = Select-AppAzureSubscription -AzureSubscriptionID $AzureSubscriptionID
    }
}
function Select-AppAzureSubscription
{
    [cmdletBinding()]
    param(
        # AzureSubscriptionID
        [Parameter(Mandatory = $False)]
        [guid]
        $AzureSubscriptionID
    )
    $Subscriptions = Get-AzureRmSubscription
    if (!$AzureSubscriptionID)
    {
        # if no parameter was passed
        $i = 1
        foreach ($Subscription in $Subscriptions) 
        {
            # Bug in Azure PowerShell >4.x $Subscription.SubscriptionName is now $Subscription.Name
            Write-Host $i '    ' $Subscription.SubscriptionId '    ' $Subscription.Name -ForegroundColor White
            $i++
        }
        
        $Prompt = Read-host "Select your Azure SubscriptionId by number"
        # Bug in Azure PowerShell 1.5 / should be fixed in 1.5.1 but is not. Subscription can be selected by name only in some cases.
        try
        {
            $Result = Select-AzureRmSubscription -SubscriptionId $Subscriptions[($prompt -1)] -ErrorAction Stop
        }
        catch
        {
            $Result = Select-AzureRmSubscription -SubscriptionName ($Subscriptions[($prompt -1)].SubscriptionName) -ErrorAction Stop
        }
        
        Write-Host 'Subscription selected ' $Subscriptions[($prompt -1)] -ForegroundColor Green
    } else {
        #Only if parameter was passed
        $Result = Select-AzureRmSubscription -SubscriptionId $AzureSubscriptionID -ErrorAction Stop
        Write-Host 'Subscription selected ' $AzureSubscriptionID -ForegroundColor Green
    }
    return $Result
}

#******************************************************************************
# Script body
# Execution begins here
#******************************************************************************
$ErrorActionPreference = "Stop"

#Load Azure
Write-Host 'Import Azure Modules'
Import-Module AzureRM.Storage -ErrorAction Stop
Import-Module AzureRM.Resources -ErrorAction Stop
Import-Module AzureRM.Profile -ErrorAction Stop
Import-module AzureRM.Websites -ErrorAction Stop
Import-Module AzureRM.SQL -ErrorAction Stop

Write-Output 'Check if already authenticated'
$ctx = Get-AzureRMContext
If ($ctx.Subscription.Id.length -gt 1)
{
    Write-Verbose 'Looks like context already valid'
} else {
    # sign in
    Write-Host "Logging in...";
    If ($subscriptionId)
    { Connect-App -AzureSubscriptionID $subscriptionId } else { Connect-App }
}

#Load XML for storage config
Write-Output 'Load XML'
if ($Path)
{
    Write-Verbose "Use provided Path $Path"
    [xml]$XMLconfig = Get-Content $Path -ErrorAction Inquire
} else {
    Write-Verbose 'Try AppParameters.xml'
    #If variable not provided, try with default name
    [xml]$XMLconfig = Get-Content (Join-Path -Path $PSScriptRoot -ChildPath 'AppParameters.xml') -ErrorAction Inquire
}
Write-Output 'Done'

[string]$ApplicationName = ($XMLconfig.AzureApplication.General.prefix + '-' + $XMLconfig.AzureApplication.General.name)
#Basic special character replacement
$ApplicationName = $ApplicationName.Replace(' ', '')
$CleanApplicationName = ($ApplicationName.Replace('-', '')).ToLower()
Write-Output "Application name will be $ApplicationName"

$StartTime = Get-Date

#Resource Group
Write-Output 'Create or check for existing resource group'
$resourceGroup = Get-AzureRmResourceGroup -Name $ApplicationName -ErrorAction SilentlyContinue
if(!$resourceGroup)
{
    Write-Host "Resource group '$ApplicationName' does not exist. To create a new resource group.";
    Write-Host "Creating resource group '$ApplicationName' in location $($XMLconfig.AzureApplication.General.Region)";
    $ResourceGroup = New-AzureRmResourceGroup -Name $ApplicationName -Location $XMLconfig.AzureApplication.General.Region
}
else{
    Write-Host "Using existing resource group $($ResourceGroup.resourceGroupName)";
}

Write-host 'Your resource group - remember it' $ResourceGroup.ResourceGroupName -ForegroundColor Green

#StorageAccount
If ($XMLconfig.AzureApplication.StorageAccount.Provision)
{
    Write-Verbose 'Try to get existing Storage Account'
    If (!(Get-AzureRmStorageAccount -Name $CleanApplicationName -ResourceGroupName $ResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue))
    {
        Write-Host 'Create Storage account'
        $AzureStorage = New-AzureRmStorageAccount `
            -Location $XMLconfig.AzureApplication.General.Region `
            -Name $CleanApplicationName `
            -ResourceGroupName $ResourceGroup.ResourceGroupName `
            -Type Standard_LRS
        #Get Storage Account Key
        $AzureStorageKey = Get-AzureRmStorageAccountKey `
            -ResourceGroupName $ResourceGroup.ResourceGroupName `
            -Name $AzureStorage.StorageAccountName
        Write-Output "Storage Account Name: $($AzureStorage.Name)"
        Write-Output "  Key: $($AzureStorageKey.Value[0])"
        
        If ($xmlconfig.AzureApplication.StorageAccount.CreateContainers -eq $true)
        {
            Write-Output 'Create Containers'
            foreach ($StorageContainer in $xmlconfig.AzureApplication.StorageAccount.Containers.Container)
            {
                #new container
                Write-Output "Create containers $($StorageContainer.Name)"
                Set-AzureRmCurrentStorageAccount -ResourceGroupName $ResourceGroup.ResourceGroupName -StorageAccountName $AzureStorage.StorageAccountName
                New-AzureStorageContainer -Name ($StorageContainer.Name).ToLower() -Permission $StorageContainer.Permission | Out-Null
            }
            
        }
        If ($xmlconfig.AzureApplication.StorageAccount.CreateQueues -eq $true)
        {
            Write-Output 'Create Queues'
            foreach ($Queue in $xmlconfig.AzureApplication.StorageAccount.Queues.Queue)
            {
                #new Queue
                Write-Output "Create Queue $($Queue)"
                Set-AzureRmCurrentStorageAccount -ResourceGroupName $ResourceGroup.ResourceGroupName -StorageAccountName $AzureStorage.StorageAccountName
                New-AzureStorageQueue -Name ($Queue.ToLower()) | Out-Null
            }            
        }
    }
}

#WebAppPlan
If ($XMLconfig.AzureApplication.WebAppServicePlan.Provision)
{
    Write-Verbose 'Try to get existing WebAppPlan'
    If (!(Get-AzureRmAppServicePlan -Name $ApplicationName -ResourceGroupName $ResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue))
    {
        Write-Output 'Create App Plan'
        $AzureAppPlan = New-AzureRmAppServicePlan `
            -Location $XMLconfig.AzureApplication.General.Region `
            -Name $ApplicationName `
            -ResourceGroupName $ResourceGroup.ResourceGroupName `
            -Tier $XMLconfig.AzureApplication.WebAppServicePlan.PricingTier `
            -WorkerSize $XMLconfig.AzureApplication.WebAppServicePlan.PricingWorkerSize `
            -ErrorAction Stop
    }
}

#SQL
If ($XMLconfig.AzureApplication.SQL.Provision)
{
    $SQLUser = $xmlconfig.AzureApplication.sql.SQLAdminUser
    If (!($xmlconfig.AzureApplication.sql.PromptforPassword -eq $true))
    {
    $SQLPwd = ConvertTo-SecureString $xmlconfig.AzureApplication.sql.SQLAdminPwd -AsPlainText -Force 
    $Credentials = New-Object System.Management.Automation.PSCredential `
        -ArgumentList $SQLUser, $SQLPwd
    } else {
        $Credentials = Get-Credential -Message 'SQL Admin Account' -UserName $SQLUser
    }
    Write-Verbose 'Try to get existing SQL'
    If (!(Get-AzureRmSqlServer -Name $ApplicationName -ResourceGroupName $ResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue))    
    {
        #Server
        Write-Output 'Create SQL Server'
        $AzureSQL = New-AzureRmSqlServer `
            -Location $XMLconfig.AzureApplication.General.Region `
            -ResourceGroupName $ResourceGroup.ResourceGroupName `
            -ServerName $ApplicationName `
            -SqlAdministratorCredentials $Credentials `
            -ErrorAction Stop
        Write-Output 'SQL created'
    }
    #DB
    Write-Verbose 'Try to get existing SQLDB'
    If (!(Get-AzureRmSqlDatabase -Name $ApplicationName -ResourceGroupName $ResourceGroup.ResourceGroupName -ServerName $AzureSQL.Servername -ErrorAction SilentlyContinue))
    {    
        [int32]$DBInMB = $xmlconfig.AzureApplication.sql.SizeinMB
        Write-Output 'Create SQL database'
        $AzureDB = New-AzureRmSqlDatabase `
            -DatabaseName $ApplicationName `
            -ResourceGroupName $ResourceGroup.ResourceGroupName `
            -ServerName $AzureSQL.Servername `
            -MaxSizeBytes ($DBInMB * 1024 * 1024)
        Write-Output "DB created: $($AzureDB.DatabaseName)"
    }
}

#WebApp
If ($XMLconfig.AzureApplication.WebApp.Provision)
{
    Write-Verbose 'Try to get existing WebApp'
    If (!(Get-AzureRmWebApp -Name $ApplicationName -ResourceGroupName $ResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue))
    {
        Write-Output 'Create Azure App'
        $AzureApp = New-AzureRmWebApp `
            -Location $XMLconfig.AzureApplication.General.Region `
            -Name $ApplicationName `
            -ResourceGroupName $ResourceGroup.ResourceGroupName `
            -AppServicePlan $AzureAppPlan.Name
        Write-Output "WebApp created $($AzureApp.Name)"
    }
    
    If ($XMLconfig.AzureApplication.WebApp.CreateAppSettings -eq $true)
    {
        Write-Output 'Set AppSettings'

        $appSettingList = $AzureApp.SiteConfig.AppSettings
 
        $hashAppSettings = @{}
        ForEach ($kvp in $appSettingList) {
        $hashAppSettings[$kvp.Name] = $kvp.Value
        }
        foreach ($AppSetting in $XMLconfig.AzureApplication.WebApp.AppSettings.AppSetting)
        {
            $hashAppSettings[$AppSetting.Name] = $AppSetting.Value
        }
    }

    If ($XMLconfig.AzureApplication.WebApp.CreateConnectionStrings -eq $true)
    {
        Write-Output 'Set ConnectionStrings'
        $ConnectionStringList = $AzureApp.SiteConfig.ConnectionStrings
        $hashItems = New-Object System.Collections.HashTable
        
        ForEach ($keyValuePair in $ConnectionStringList) {
            Write-Verbose 'Found existing connections'
            $setting =  @{Type=$keyValuePair.Type.ToString();Value=$keyValuePair.ConnectionString.ToString()}
            $hashItems.Add($keyValuePair.Name,$setting);
        }

        foreach ($connectionstring in $XMLconfig.AzureApplication.WebApp.ConnectionStrings.ConnectionString)
        {
            #Create Connection String
            switch ($connectionstring.Type) {
                AutoSQLAzure { 
                    #Get if not already loaded
                    If (!$AzureDB) { $AzureDB = Get-AzureRmSqlDatabase -Name $ApplicationName -ResourceGroupName $ResourceGroup.ResourceGroupName -ServerName $AzureSQL.Servername -ErrorAction SilentlyContinue }
                    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($credentials.Password)
                    $PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                    $autoSQL = "Server=tcp:$($AzureDB.ServerName).database.windows.net,1433;Initial Catalog=$($AzureDB.DatabaseName);Persist Security Info=False;User ID=$($SQLUser);Password=$($PlainPassword);MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
                    $PlainPassword = $null
                    $Type = "SQLAzure"
                    $setting =  @{Type=$Type.ToString();Value=$autoSQL.ToString()}
                }
                AutoCustom { 
                    #In case already created, get it anyway
                    If (!$AzureStorage) {$AzureStorage = Get-AzureRmStorageAccount -Name $CleanApplicationName -ResourceGroupName $ResourceGroup.ResourceGroupName -ErrorAction SilentlyContinue }
                    If (!$AzureStorageKey) {
                        #Get Storage Account Key
                        $AzureStorageKey = Get-AzureRmStorageAccountKey `
                        -ResourceGroupName $ResourceGroup.ResourceGroupName `
                        -Name $AzureStorage.StorageAccountName
                    }
                    $AutoCustom = "DefaultEndpointsProtocol=https;AccountName=$($CleanApplicationName);AccountKey=$($AzureStorageKey.Value[0]);EndpointSuffix=core.windows.net"
                    $Type = "Custom"
                    $setting =  @{Type=$Type.ToString();Value=$AutoCustom.ToString()}
                }
                Default {
                    #Use ConnectionString from XML
                    $connectionStringInfo = (@{Name = $connectionstring.Name; Type = "Custom"; ConnectionString = $connectionstring.ConnectionString})
                    $Type = $connectionstring.Type
                    $setting =  @{Type=$Type.ToString();Value=$connectionStringInfo.ToString()}

                }
            }
            $hashItems.Add($connectionstring.Name,$setting);
        }
    }
    Write-Output 'Commit changes to WebApp'
    Set-AzureRmWebApp $AzureApp.Name -AppSettings $hashAppSettings -ConnectionStrings $hashItems -ResourceGroupName $ResourceGroup.ResourceGroupName | Out-Null

    If ($XMLconfig.AzureApplication.WebApp.AlwaysOn -eq $true)
    {
        #Set Properties
        Write-Output 'Set Properties'
        If (($XMLconfig.AzureApplication.WebAppServicePlan.PricingTier -ne 'Free') -or ($XMLconfig.AzureApplication.WebAppServicePlan.PricingTier -ne 'Shared'))    
        { 
            Write-Output 'Enable AlwaysOn'
            $WebAppPropertiesObject = @{"siteConfig" = @{"AlwaysOn" = $true}}
            $WebAppResourceType = 'microsoft.web/sites'
            $webAppResource = Get-AzureRmResource -ResourceType $WebAppResourceType -ResourceGroupName $ResourceGroup.ResourceGroupName -ResourceName $AzureApp.Name
            $webAppResource | Set-AzureRmResource -PropertyObject $WebAppPropertiesObject -Force | Out-Null
        } else {
            Write-Output 'Always on should be enabled but this is not support in Free and Shared App Plan, skipping'
        }
    } 
}

$EndTime = Get-Date
Write-Host 'Deployment took ' $EndTime.Subtract($StartTime)