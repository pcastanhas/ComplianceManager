using './main.bicep'

param location = 'eastus2'
param env = 'dev'
param namePrefix = 'cmgr'

// TODO: replace with the object id + name of the Entra group that admins Postgres.
param entraAdminObjectId = '00000000-0000-0000-0000-000000000000'
param entraAdminPrincipalName = 'compliance-platform-admins'

param postgresSkuName = 'Standard_B1ms'
param postgresSkuTier = 'Burstable'
param appServiceSkuName = 'B1'
param appServiceSkuTier = 'Basic'
param backupRetentionDays = 7
