// =====================================================================
// Tenant Postgres module (resource-group scoped)
// Provisions ONE tenant's compliance database on its own Flexible Server,
// with independent PITR. Deployed by the one-click provisioner into the
// tenants RG, once per client. This is the "model" template.
//
// Schema is applied afterward by the provisioner via EF Core migrations
// (CREATE DATABASE ... TEMPLATE can't cross servers).
//
// NOT yet validated — see infra/README.md.
// =====================================================================

param location string = resourceGroup().location

@description('Client slug — used in the server name. Lowercase, short.')
param tenantSlug string

@description('Object id of the Entra admin group for this server.')
param entraAdminObjectId string

@description('Display name of that Entra admin group.')
param entraAdminPrincipalName string

param skuName string = 'Standard_B1ms'
@allowed(['Burstable', 'GeneralPurpose', 'MemoryOptimized'])
param skuTier string = 'Burstable'
param postgresVersion string = '16'
param storageSizeGB int = 32

@description('Per-tenant PITR retention (days).')
param backupRetentionDays int = 7

param tags object = {}

var serverName = 'cmgr-tenant-${tenantSlug}-${take(uniqueString(resourceGroup().id, tenantSlug), 6)}'

resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: serverName
  location: location
  tags: union(tags, { tenant: tenantSlug })
  sku: { name: skuName, tier: skuTier }
  properties: {
    version: postgresVersion
    storage: { storageSizeGB: storageSizeGB }
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

resource aadAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = {
  parent: pg
  name: entraAdminObjectId
  properties: {
    principalType: 'Group'
    principalName: entraAdminPrincipalName
    tenantId: tenant().tenantId
  }
}

resource db 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: pg
  name: 'compliance'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

output serverName string = pg.name
output serverFqdn string = pg.properties.fullyQualifiedDomainName
output databaseName string = db.name
