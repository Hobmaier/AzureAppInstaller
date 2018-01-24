# AzureAppInstaller
Deploys a typical Azure infrastructure

This includes 
- Azure Web App
- App Service Plan
- SQL Server
- SQL Database
- Storage Account. 

Use the XML file for parameters.

# XML
Should be self-explaining, but just in case:
- Provision: true/false = will be provisioned
- General Name and Prefix will be used as Application Name for all services and resource Group e.g. EU-West-DHApp2

# Usage
## Example 1
    .\Install-AppResources.ps1 -Path .\AppParameters.xml

    Default behaviour, it will read the parameters from XML such as App name, Region
## Example 2
    .\Install-AppResources.ps1 -Path .\AppParameters.xml -SubscriptionId e2264704-9eba-45e5-9130-c28fb5cbee02
    
    This will use the subscription ID as well