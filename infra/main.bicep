// =====================================================================
// NYC Compliance Manager — platform infrastructure (entry point)
// Subscription-scoped: creates the platform RG + a dedicated tenants RG,
// deploys the shared platform resources, and grants the provisioner
// (the Function app identity) a least-privilege custom role scoped to
// the tenants RG only.
//
// NOTE: authored in a sandbox without Azure access — NOT yet validated.
// Run `az bicep build` + `az deployment sub what-if` before deploying.
// =====================================================================
targetScope = 'subscription'

@description('Azure region for all resources.')
param location string = 'eastus2'

@description('Environment short name (dev / prod).')
@allowed(['dev', 'prod'])
param env string

@description('Short prefix used in resource names.')
param namePrefix string = 'cmgr'

@description('Object id of the Entra group that administers the Postgres servers (required — Postgres password auth is disabled).')
param entraAdminObjectId string

@description('Display name of that Entra admin group.')
param entraAdminPrincipalName string

@description('Catalog Postgres SKU.')
param postgresSkuName string = 'Standard_B1ms'
@allowed(['Burstable', 'GeneralPurpose', 'MemoryOptimized'])
param postgresSkuTier string = 'Burstable'

@description('App Service plan SKU.')
param appServiceSkuName string = 'B1'
param appServiceSkuTier string = 'Basic'

@description('Catalog Postgres PITR retention (days).')
param backupRetentionDays int = 7

var tags = {
  application: 'compliance-manager'
  environment: env
  managedBy: 'bicep'
}

var platformRgName = '${namePrefix}-${env}-platform-rg'
var tenantsRgName = '${namePrefix}-${env}-tenants-rg'

resource platformRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: platformRgName
  location: location
  tags: tags
}

// Tenant Flexible Servers are provisioned here, one per client, by the
// one-click orchestration. Kept separate so the provisioner's create
// rights scope to this RG only.
resource tenantsRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: tenantsRgName
  location: location
  tags: tags
}

module platform 'modules/platform.bicep' = {
  name: 'platform'
  scope: platformRg
  params: {
    location: location
    env: env
    namePrefix: namePrefix
    tags: tags
    entraAdminObjectId: entraAdminObjectId
    entraAdminPrincipalName: entraAdminPrincipalName
    postgresSkuName: postgresSkuName
    postgresSkuTier: postgresSkuTier
    appServiceSkuName: appServiceSkuName
    appServiceSkuTier: appServiceSkuTier
    backupRetentionDays: backupRetentionDays
  }
}

// Least-privilege custom role: create/manage Postgres Flexible Servers
// and run template deployments — nothing else, no delete of other resources.
resource provisionerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, 'tenant-provisioner', namePrefix, env)
  properties: {
    roleName: '${namePrefix}-${env}-tenant-provisioner'
    description: 'Create and manage tenant Postgres Flexible Servers in the tenants RG.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.DBforPostgreSQL/flexibleServers/*'
          'Microsoft.Resources/deployments/*'
          'Microsoft.Resources/subscriptions/resourceGroups/read'
          'Microsoft.Insights/*/read'
        ]
        notActions: []
      }
    ]
    assignableScopes: [
      subscription().id
    ]
  }
}

// Assign the provisioner role to the Function app identity, scoped to the tenants RG.
resource provisionerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: tenantsRg
  name: guid(tenantsRg.id, platform.outputs.functionAppPrincipalId, provisionerRole.id)
  properties: {
    roleDefinitionId: provisionerRole.id
    principalId: platform.outputs.functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output platformResourceGroup string = platformRg.name
output tenantsResourceGroup string = tenantsRg.name
output adminAppName string = platform.outputs.adminAppName
output mainAppName string = platform.outputs.mainAppName
output functionAppName string = platform.outputs.functionAppName
output catalogServerFqdn string = platform.outputs.catalogServerFqdn
output keyVaultUri string = platform.outputs.keyVaultUri
output documentsStorageAccount string = platform.outputs.documentsStorageAccount
