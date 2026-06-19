using './modules/tenant-postgres.bicep'

// Example: provisioning one tenant. The one-click orchestration generates
// these parameters per client and deploys this module into the tenants RG.
param location = 'eastus2'
param tenantSlug = 'acme'
param entraAdminObjectId = '00000000-0000-0000-0000-000000000000'
param entraAdminPrincipalName = 'compliance-platform-admins'
param skuName = 'Standard_B1ms'
param skuTier = 'Burstable'
param backupRetentionDays = 7
