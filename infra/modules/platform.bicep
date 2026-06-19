// =====================================================================
// Platform module (resource-group scoped)
// Catalog Postgres, two App Services (admin + main), Flex Consumption
// Function app, Key Vault, document storage, monitoring, and the
// least-privilege RBAC that wires each identity.
//
// NOT yet validated — see infra/README.md.
// =====================================================================

param location string
param env string
param namePrefix string
param tags object
param entraAdminObjectId string
param entraAdminPrincipalName string
param postgresSkuName string
param postgresSkuTier string
param appServiceSkuName string
param appServiceSkuTier string
param backupRetentionDays int
param postgresVersion string = '16'

var token = take(uniqueString(resourceGroup().id), 6)
var base = '${namePrefix}-${env}'

// Built-in role definition GUIDs
var roleKeyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
var roleBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var roleBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var roleQueueDataContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var roleTableDataContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'

// ---------- Monitoring ----------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${base}-law'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${base}-appi'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ---------- Storage: documents ----------
resource documentsStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: '${namePrefix}${env}docs${token}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: false
  }
}

resource documentsBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: documentsStorage
  name: 'default'
}

resource documentsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: documentsBlob
  name: 'documents'
}

// ---------- Storage: Functions (deployment package + AzureWebJobs) ----------
resource funcStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: '${namePrefix}${env}func${token}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource funcBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: funcStorage
  name: 'default'
}

resource funcDeployContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: funcBlob
  name: 'deploymentpackage'
}

// ---------- Key Vault (RBAC mode, no access policies) ----------
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: '${base}-kv-${token}'
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: (env == 'prod') ? true : null // prod only; lets dev be torn down/recreated freely
    publicNetworkAccess: 'Enabled'
  }
}

// ---------- Catalog Postgres (its own server; Entra auth only) ----------
resource catalogPg 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: '${base}-catalog-${token}'
  location: location
  tags: tags
  sku: { name: postgresSkuName, tier: postgresSkuTier }
  properties: {
    version: postgresVersion
    storage: { storageSizeGB: 32 }
    createMode: 'Default'
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Disabled'
    }
    highAvailability: { mode: 'Disabled' }
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: 'Disabled'
    }
  }
}

resource catalogAadAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = {
  parent: catalogPg
  name: entraAdminObjectId
  properties: {
    principalType: 'Group'
    principalName: entraAdminPrincipalName
    tenantId: tenant().tenantId
  }
}

resource catalogDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: catalogPg
  name: 'catalog'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// ---------- App Service plan + the two apps ----------
resource appPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: '${base}-plan'
  location: location
  tags: tags
  sku: { name: appServiceSkuName, tier: appServiceSkuTier }
  kind: 'linux'
  properties: { reserved: true }
}

var commonSiteConfig = {
  linuxFxVersion: 'DOTNETCORE|10.0'
  alwaysOn: true
  webSocketsEnabled: true // Blazor Server (SignalR circuit)
  minTlsVersion: '1.2'
  http20Enabled: true
  ftpsState: 'Disabled'
}

resource adminApp 'Microsoft.Web/sites@2024-04-01' = {
  name: '${base}-admin-${token}'
  location: location
  tags: tags
  kind: 'app,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: appPlan.id
    httpsOnly: true
    clientAffinityEnabled: true // sticky sessions for Blazor Server
    siteConfig: union(commonSiteConfig, {
      appSettings: [
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'Catalog__ServerFqdn', value: catalogPg.properties.fullyQualifiedDomainName }
        { name: 'Catalog__Database', value: 'catalog' }
        { name: 'KeyVault__Uri', value: keyVault.properties.vaultUri }
        { name: 'Tenants__ResourceGroup', value: '${namePrefix}-${env}-tenants-rg' }
      ]
    })
  }
}

resource mainApp 'Microsoft.Web/sites@2024-04-01' = {
  name: '${base}-main-${token}'
  location: location
  tags: tags
  kind: 'app,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: appPlan.id
    httpsOnly: true
    clientAffinityEnabled: true
    siteConfig: union(commonSiteConfig, {
      appSettings: [
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'Catalog__ServerFqdn', value: catalogPg.properties.fullyQualifiedDomainName }
        { name: 'Catalog__Database', value: 'catalog' }
        { name: 'KeyVault__Uri', value: keyVault.properties.vaultUri }
        { name: 'Documents__StorageAccount', value: documentsStorage.name }
      ]
    })
  }
}

// ---------- Functions (Flex Consumption, .NET 10 isolated) ----------
resource flexPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: '${base}-flex'
  location: location
  tags: tags
  sku: { tier: 'FlexConsumption', name: 'FC1' }
  kind: 'functionapp'
  properties: { reserved: true }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: '${base}-func-${token}'
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: flexPlan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${funcStorage.properties.primaryEndpoints.blob}deploymentpackage'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      runtime: { name: 'dotnet-isolated', version: '10.0' }
      scaleAndConcurrency: {
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      appSettings: [
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'AzureWebJobsStorage__accountName', value: funcStorage.name }
        { name: 'Catalog__ServerFqdn', value: catalogPg.properties.fullyQualifiedDomainName }
        { name: 'Catalog__Database', value: 'catalog' }
        { name: 'KeyVault__Uri', value: keyVault.properties.vaultUri }
      ]
    }
  }
}

// ---------- Role assignments (control-plane / RBAC data-plane) ----------
// NOTE: Postgres data-plane logins for these identities are configured
// INSIDE Postgres via the Entra admin (CREATE ROLE / pgaadauth), not here.

// Key Vault Secrets User for all three identities
resource kvAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, adminApp.id, roleKeyVaultSecretsUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsUser)
    principalId: adminApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource kvMain 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, mainApp.id, roleKeyVaultSecretsUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsUser)
    principalId: mainApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource kvFunc 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, functionApp.id, roleKeyVaultSecretsUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsUser)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Documents blob access: main app (read/write) + function app
resource docsMain 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: documentsStorage
  name: guid(documentsStorage.id, mainApp.id, roleBlobDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleBlobDataContributor)
    principalId: mainApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource docsFunc 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: documentsStorage
  name: guid(documentsStorage.id, functionApp.id, roleBlobDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleBlobDataContributor)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Function host storage (AzureWebJobsStorage + deployment) via managed identity
resource funcBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: funcStorage
  name: guid(funcStorage.id, functionApp.id, roleBlobDataOwner)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleBlobDataOwner)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource funcQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: funcStorage
  name: guid(funcStorage.id, functionApp.id, roleQueueDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleQueueDataContributor)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource funcTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: funcStorage
  name: guid(funcStorage.id, functionApp.id, roleTableDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleTableDataContributor)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output adminAppName string = adminApp.name
output mainAppName string = mainApp.name
output functionAppName string = functionApp.name
output functionAppPrincipalId string = functionApp.identity.principalId
output catalogServerFqdn string = catalogPg.properties.fullyQualifiedDomainName
output keyVaultUri string = keyVault.properties.vaultUri
output documentsStorageAccount string = documentsStorage.name
