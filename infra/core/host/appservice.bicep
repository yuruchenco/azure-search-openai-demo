param name string
param location string = resourceGroup().location
param tags object = {}
param vnetName string
param subnet0Name string
param subnet1Name string

// Reference Properties
param applicationInsightsName string = ''
param appServicePlanId string
param keyVaultName string = ''
param managedIdentity bool = !empty(keyVaultName)

// Runtime Properties
@allowed([
  'dotnet', 'dotnetcore', 'dotnet-isolated', 'node', 'python', 'java', 'powershell', 'custom'
])
param runtimeName string
param runtimeNameAndVersion string = '${runtimeName}|${runtimeVersion}'
param runtimeVersion string

// Microsoft.Web/sites Properties
param kind string = 'app,linux'

// Microsoft.Web/sites/config
param allowedOrigins array = []
param alwaysOn bool = true
param appCommandLine string = ''
param appSettings object = {}
param clientAffinityEnabled bool = false
param enableOryxBuild bool = contains(kind, 'linux')
param functionAppScaleLimit int = -1
param vnetRouteAllEnabled bool = true
param linuxFxVersion string = runtimeNameAndVersion
param minimumElasticInstanceCount int = -1
param numberOfWorkers int = -1
param scmDoBuildDuringDeployment bool = false
param use32BitWorkerProcess bool = false
param ftpsState string = 'FtpsOnly'
param healthCheckPath string = ''

param zones string = 'azurewebsites.net'

var PRIVATE_ENDPOINT_NAME = 'PE-AppService'

// Reference existing vNET
resource existingVnet 'Microsoft.Network/virtualNetworks@2020-05-01' existing = {
  name: vnetName
  resource existingsubnet0 'subnets' existing = {
    name: subnet0Name
  }
  resource existingsubnet1 'subnets' existing = {
    name: subnet1Name
  }
}

resource appService 'Microsoft.Web/sites@2022-03-01' = {
  name: name
  location: location
  tags: tags
  kind: kind
  properties: {
    virtualNetworkSubnetId: existingVnet.properties.subnets[1].id
    serverFarmId: appServicePlanId
    siteConfig: {
      vnetRouteAllEnabled: vnetRouteAllEnabled
      linuxFxVersion: linuxFxVersion
      alwaysOn: alwaysOn
      ftpsState: ftpsState
      appCommandLine: appCommandLine
      numberOfWorkers: numberOfWorkers != -1 ? numberOfWorkers : null
      minimumElasticInstanceCount: minimumElasticInstanceCount != -1 ? minimumElasticInstanceCount : null
      use32BitWorkerProcess: use32BitWorkerProcess
      functionAppScaleLimit: functionAppScaleLimit != -1 ? functionAppScaleLimit : null
      healthCheckPath: healthCheckPath
      cors: {
        allowedOrigins: union([ 'https://portal.azure.com', 'https://ms.portal.azure.com' ], allowedOrigins)
      }
    }
    clientAffinityEnabled: clientAffinityEnabled
    httpsOnly: true
  }

  identity: { type: managedIdentity ? 'SystemAssigned' : 'None' }

  resource configAppSettings 'config' = {
    name: 'appsettings'
    properties: union(appSettings,
      {
        SCM_DO_BUILD_DURING_DEPLOYMENT: string(scmDoBuildDuringDeployment)
        ENABLE_ORYX_BUILD: string(enableOryxBuild)
      },
      !empty(applicationInsightsName) ? { APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsights.properties.ConnectionString } : {},
      !empty(keyVaultName) ? { AZURE_KEY_VAULT_ENDPOINT: keyVault.properties.vaultUri } : {})
  }

  resource configLogs 'config' = {
    name: 'logs'
    properties: {
      applicationLogs: { fileSystem: { level: 'Verbose' } }
      detailedErrorMessages: { enabled: true }
      failedRequestsTracing: { enabled: true }
      httpLogs: { fileSystem: { enabled: true, retentionInDays: 1, retentionInMb: 35 } }
    }
    dependsOn: [
      configAppSettings
    ]
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' existing = if (!(empty(keyVaultName))) {
  name: keyVaultName
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = if (!empty(applicationInsightsName)) {
  name: applicationInsightsName
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2021-05-01' = {
  name: PRIVATE_ENDPOINT_NAME
  location: location
  properties: {
    subnet: {
      id: existingVnet::existingsubnet0.id
    }
    customNetworkInterfaceName: '${PRIVATE_ENDPOINT_NAME}-nic'
    privateLinkServiceConnections: [
      {
        name: PRIVATE_ENDPOINT_NAME
        properties: {
          privateLinkServiceId: appService.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
}

resource privateDnsZoneForAppService 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  location: 'global'
  name: 'privatelink.${zones}'
  properties: {
  }
}

resource vnetLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZoneForAppService
  name: '${privateDnsZoneForAppService.name}-${uniqueString(existingVnet.id)}' 
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: existingVnet.id
    }
  }
}

resource peDnsGroupForAmpls 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2021-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: privateDnsZoneForAppService.name
        properties: {
          privateDnsZoneId: privateDnsZoneForAppService.id
        }
      }
    ]
  }
}

output identityPrincipalId string = managedIdentity ? appService.identity.principalId : ''
output name string = appService.name
output uri string = 'https://${appService.properties.defaultHostName}'
