targetScope = 'subscription'

@description('Id of the user or app to assign application roles')
param principalId string

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

@description('The email address of the owner of the service')
@minLength(1)
param publisherEmail string

@description('The name of the owner of the service')
@minLength(1)
param publisherName string

param resourceGroupName string = ''

param vnetName string = ''

param apiManagementName string = ''

param appServicePlanName string = ''
param backendServiceName string = ''

param searchServicesName string = ''
param searchServicesSkuName string = 'standard'
param storageAccountName string = ''
param containerName string = 'content'
param searchIndexName string = 'gptkbindex'

param cognitiveServicesAccountName string = ''
param cognitiveServicesSkuName string = 'S0'
param gptDeploymentName string = 'davinci'
param gptModelName string = 'text-davinci-003'
param chatGptDeploymentName string = 'chat'
param chatGptModelName string = 'gpt-35-turbo'

var abbrs = loadJsonContent('abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'env-name': environmentName }


// Organize resources in a resource group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : '${environmentName}'
  location: location
  tags: tags
}

//Create an VNET
module vnet 'core/nw/vnet.bicep' = {
  name: 'VirtualNetwork'
  scope: rg
  params: {
    name: !empty(vnetName) ? vnetName : '${abbrs.networkVirtualNetworks}${resourceToken}'
    location: location
  }
}

// Create an API Managament
module apimanagement 'core/api/apimanagement.bicep' = {
  name: 'apimanagement'
  scope: rg
  params: {
    name: !empty(apiManagementName) ? apiManagementName : '${abbrs.apiManagementService}${resourceToken}'
    publisherEmail: publisherEmail
    publisherName: publisherName
    location: location
    tags: tags
  }
}


// Create an App Service Plan to group applications under the same payment plan and SKU
module appServicePlan 'core/host/appserviceplan.bicep' = {
  name: 'appserviceplan'
  scope: rg
  params: {
    name: !empty(appServicePlanName) ? appServicePlanName : '${abbrs.webServerFarms}${resourceToken}'
    location: location
    tags: tags
    sku: {
      name: 'B1'
      capacity: 1
    }
    kind: 'linux'
  }
}

// create a Web Apps for backend for backend apps
module backend 'core/host/appservice.bicep' = {
  name: 'web'
  scope: rg
  params: {
    name: !empty(backendServiceName) ? backendServiceName : '${abbrs.webSitesAppService}backend-${resourceToken}'
    location: location
    tags: union(tags, { 'service-name': 'backend' })
    vnetName: vnet.outputs.OUTPUT_VNET_NAME
    subnet0Name: vnet.outputs.OUTPUT_SUBNET0_NAME
    subnet1Name: vnet.outputs.OUTPUT_SUBNET1_NAME
    appServicePlanId: appServicePlan.outputs.id
    runtimeName: 'python'
    runtimeVersion: '3.10'
    scmDoBuildDuringDeployment: true
    managedIdentity: true
    appSettings: {
      AZURE_BLOB_STORAGE_ACCOUNT: storage.outputs.name
      AZURE_BLOB_STORAGE_CONTAINER: containerName
      AZURE_OPENAI_SERVICE: cognitiveServices.outputs.name
      AZURE_SEARCH_INDEX: searchIndexName
      AZURE_SEARCH_SERVICE: searchServices.outputs.name
      AZURE_OPENAI_GPT_DEPLOYMENT: gptDeploymentName
      AZURE_OPENAI_CHATGPT_DEPLOYMENT: chatGptDeploymentName
    }
  }
  dependsOn:[
    vnet
  ]
}

module cognitiveServices 'core/ai/cognitiveservices.bicep' = {
  scope: rg
  name: 'openai'
  params: {
    name: !empty(cognitiveServicesAccountName) ? cognitiveServicesAccountName : '${abbrs.cognitiveServicesAccounts}${resourceToken}'
    location: location
    tags: tags
    vnetName: vnet.outputs.OUTPUT_VNET_NAME
    subnet2Name: vnet.outputs.OUTPUT_SUBNET2_NAME 
    sku: {
      name: cognitiveServicesSkuName
    }
    deployments: [
      {
        name: gptDeploymentName
        model: {
          format: 'OpenAI'
          name: gptModelName
          version: '1'
        }
        scaleSettings: {
          scaleType: 'Standard'
        }
      }
      {
        name: chatGptDeploymentName
        model: {
          format: 'OpenAI'
          name: chatGptModelName
          version: '0301'
        }
        scaleSettings: {
          scaleType: 'Standard'
        }
      }
    ]
  }
  dependsOn:[
    vnet
  ]
}

module searchServices 'core/search/search-services.bicep' = {
  scope: rg
  name: 'search-services'
  params: {
    name: !empty(searchServicesName) ? searchServicesName : 'gptkb-${resourceToken}'
    location: location
    tags: tags
    vnetName: vnet.outputs.OUTPUT_VNET_NAME
    subnet2Name: vnet.outputs.OUTPUT_SUBNET2_NAME  
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
    sku: {
      name: searchServicesSkuName
    }
    semanticSearch: 'free'
  }
  dependsOn:[
    vnet
  ]
}

module storage 'core/storage/storage-account.bicep' = {
  name: 'storage'
  scope: rg
  params: {
    name: !empty(storageAccountName) ? storageAccountName : '${abbrs.storageStorageAccounts}${resourceToken}'
    location: location
    tags: tags
    vnetName: vnet.outputs.OUTPUT_VNET_NAME
    subnet2Name: vnet.outputs.OUTPUT_SUBNET2_NAME  
    publicNetworkAccess: 'Disabled'
    sku: {
      name: 'Standard_ZRS'
    }
    deleteRetentionPolicy: {
      enabled: true
      days: 2
    }
    containers: [
      {
        name: 'content'
        publicAccess: 'None'
      }
    ]
  }
  dependsOn:[
    vnet
  ]
}

// USER ROLES
module openAiRoleUser 'core/security/role.bicep' = {
  scope: rg
  name: 'openai-role-user'
  params: {
    principalId: principalId
    roleDefinitionId: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
    principalType: 'User'
  }
}

module storageRoleUser 'core/security/role.bicep' = {
  scope: rg
  name: 'storage-role-user'
  params: {
    principalId: principalId
    roleDefinitionId: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
    principalType: 'User'
  }
}

module storageContribRoleUser 'core/security/role.bicep' = {
  scope: rg
  name: 'storage-contribrole-user'
  params: {
    principalId: principalId
    roleDefinitionId: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    principalType: 'User'
  }
}

module searchRoleUser 'core/security/role.bicep' = {
  scope: rg
  name: 'search-role-user'
  params: {
    principalId: principalId
    roleDefinitionId: '1407120a-92aa-4202-b7e9-c0e197c71c8f'
    principalType: 'User'
  }
}

module searchContribRoleUser 'core/security/role.bicep' = {
  scope: rg
  name: 'search-contrib-role-user'
  params: {
    principalId: principalId
    roleDefinitionId: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
    principalType: 'User'
  }
}

// SYSTEM IDENTITIES
module openAiRoleBackend 'core/security/role.bicep' = {
  scope: rg
  name: 'openai-role-backend'
  params: {
    principalId: backend.outputs.identityPrincipalId
    roleDefinitionId: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
    principalType: 'ServicePrincipal'
  }
}

module storageRoleBackend 'core/security/role.bicep' = {
  scope: rg
  name: 'storage-role-backend'
  params: {
    principalId: backend.outputs.identityPrincipalId
    roleDefinitionId: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
    principalType: 'ServicePrincipal'
  }
}

module searchRoleBackend 'core/security/role.bicep' = {
  scope: rg
  name: 'search-role-backend'
  params: {
    principalId: backend.outputs.identityPrincipalId
    roleDefinitionId: '1407120a-92aa-4202-b7e9-c0e197c71c8f'
    principalType: 'ServicePrincipal'
  }
}


output AZURE_LOCATION string = location
output AZURE_OPENAI_SERVICE string = cognitiveServices.outputs.name
output AZURE_SEARCH_INDEX string = searchIndexName
output AZURE_SEARCH_SERVICE string = searchServices.outputs.name
output AZURE_STORAGE_ACCOUNT string = storage.outputs.name
output AZURE_STORAGE_CONTAINER string = containerName
output BACKEND_URI string = backend.outputs.uri
