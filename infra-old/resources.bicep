param location string
param principalId string = ''
param resourceToken string
param tags object

resource web 'Microsoft.Web/staticSites@2021-03-01' = {
  name: 'stapp-${resourceToken}'
  location: location
  tags: union(tags, {
      'azd-service-name': 'web'
    })
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    provider: 'Custom'
  }
}

resource api 'Microsoft.Web/sites@2022-03-01' = {
  name: 'app-api-${resourceToken}'
  location: location
  tags: union(tags, {
      'azd-service-name': 'api'
    })
  kind: 'functionapp,linux'
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      numberOfWorkers: 1
      linuxFxVersion: 'DOTNET|6.0'
      alwaysOn: false
      functionAppScaleLimit: 200
      minimumElasticInstanceCount: 0
      ftpsState: 'FtpsOnly'
      use32BitWorkerProcess: false
      cors: {
        allowedOrigins: [
          'https://ms.portal.azure.com'
          'https://${web.properties.defaultHostname}'
        ]
      }
    }
    reserved: true
    clientAffinityEnabled: false
    httpsOnly: true
  }

  identity: {
    type: 'SystemAssigned'
  }

  resource appSettings 'config' = {
    name: 'appsettings'
    properties: {
      'APPLICATIONINSIGHTS_CONNECTION_STRING': applicationInsightsResources.outputs.APPLICATIONINSIGHTS_CONNECTION_STRING
      'AzureWebJobsStorage': 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storage.listKeys().keys[0].value}'
      'SCM_DO_BUILD_DURING_DEPLOYMENT': 'false'
      'AZURE_COSMOS_CONNECTION_STRING_KEY': 'AZURE-COSMOS-CONNECTION-STRING'
      'CosmosDbConnectionString': '@Microsoft.KeyVault(SecretUri=${keyVault.properties.vaultUri}secrets/CosmosDbConnectionString)'
      'AZURE_COSMOS_DATABASE_NAME': cosmos::database.name
      'AZURE_KEY_VAULT_ENDPOINT': keyVault.properties.vaultUri
      'FUNCTIONS_WORKER_RUNTIME': 'dotnet'
      'FUNCTIONS_EXTENSION_VERSION': '~4'

    }
  }

  resource logs 'config' = {
    name: 'logs'
    properties: {
      applicationLogs: {
        fileSystem: {
          level: 'Verbose'
        }
      }
      detailedErrorMessages: {
        enabled: true
      }
      failedRequestsTracing: {
        enabled: true
      }
      httpLogs: {
        fileSystem: {
          enabled: true
          retentionInDays: 1
          retentionInMb: 35
        }
      }
    }
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2021-03-01' = {
  name: 'plan-${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
    size: 'Y1'
    family: 'Y'
  }
  kind: 'functionapp'
  properties: {
    reserved: true
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2021-10-01' = {
  name: 'keyvault${resourceToken}'
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    accessPolicies: concat([
        {
          objectId: api.identity.principalId
          permissions: {
            secrets: [
              'get'
              'list'
            ]
          }
          tenantId: subscription().tenantId
        }
      ], !empty(principalId) ? [
        {
          objectId: principalId
          permissions: {
            secrets: [
              'get'
              'list'
            ]
          }
          tenantId: subscription().tenantId
        }
      ] : [])
  }

  resource cosmosConnectionString 'secrets' = {
    name: 'AZURE-COSMOS-CONNECTION-STRING'
    properties: {
      value: cosmos.listConnectionStrings().connectionStrings[0].connectionString
    }
  }
  
  resource CosmosDbConnectionString 'secrets' = {
    name: 'CosmosDbConnectionString'
    properties: {
      value: cosmos.listConnectionStrings().connectionStrings[0].connectionString
    }
  }
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2020-03-01-preview' = {
  name: 'log-${resourceToken}'
  location: location
  tags: tags
  properties: any({
    retentionInDays: 30
    features: {
      searchVersion: 1
    }
    sku: {
      name: 'PerGB2018'
    }
  })
}

module applicationInsightsResources './applicationinsights.bicep' = {
  name: 'applicationinsights-${resourceToken}'
  params: {
    resourceToken: resourceToken
    location: location
    tags: tags
    workspaceId: logAnalyticsWorkspace.id
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2021-09-01' = {
  name: 'stor${resourceToken}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2021-10-15' = {
  name: 'cosmos-${resourceToken}'
  location: location
  tags: tags
  properties: {
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    databaseAccountOfferType: 'Standard'
    enableAutomaticFailover: false
    enableMultipleWriteLocations: false
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
  }

  resource database 'sqlDatabases' = {
    name: 'AzureResume'
    properties: {
      resource: {
        id: 'AzureResume'
      }
    }

    resource list 'containers' = {
      name: 'Counter'
      properties: {
        resource: {
          id: 'Counter'
          partitionKey: {
            paths: [
              '/id'
            ]
          }
        }
        options: {}
      }
    }
  }
  resource roleDefinition 'sqlroleDefinitions' = {
    name: guid(cosmos.id, resourceToken, 'sql-role')
    properties: {
      assignableScopes: [
        cosmos.id
      ]
      permissions: [
        {
          dataActions: [
            'Microsoft.DocumentDB/databaseAccounts/readMetadata'
            'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/*'
            'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/*'
          ]
          notDataActions: []
        }
      ]
      roleName: 'Reader Writer'
      type: 'CustomRole'
    }
  }

  resource userRole 'sqlRoleAssignments' = if (!empty(principalId)) {
    name: guid(roleDefinition.id, principalId, cosmos.id)
    properties: {
      principalId: principalId
      roleDefinitionId: roleDefinition.id
      scope: cosmos.id
    }
  }

  resource appRole 'sqlRoleAssignments' = {
    name: guid(roleDefinition.id, api.id, cosmos.id)
    properties: {
      principalId: api.identity.principalId
      roleDefinitionId: roleDefinition.id
      scope: cosmos.id
    }

    dependsOn: [
      userRole
    ]
  }
}


output AZURE_COSMOS_CONNECTION_STRING_KEY string = 'AZURE-COSMOS-CONNECTION-STRING'
output CosmosDbConnectionString string = 'CosmosDbConnectionString'
output AZURE_COSMOS_ENDPOINT string = cosmos.properties.documentEndpoint
output AZURE_COSMOS_DATABASE_NAME string = cosmos::database.name
output AZURE_KEY_VAULT_ENDPOINT string = keyVault.properties.vaultUri
output APPLICATIONINSIGHTS_CONNECTION_STRING string = applicationInsightsResources.outputs.APPLICATIONINSIGHTS_CONNECTION_STRING
output WEB_URI string = 'https://${web.properties.defaultHostname}'
output API_URI string = 'https://${api.properties.defaultHostName}'
