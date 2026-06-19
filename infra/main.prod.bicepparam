using './main.bicep'

param location = 'eastus2'
param env = 'prod'
param namePrefix = 'cmgr'

// TODO: replace with the object id + name of the Entra group that admins Postgres.
param entraAdminObjectId = '00000000-0000-0000-0000-000000000000'
param entraAdminPrincipalName = 'compliance-platform-admins'

// Sturdier defaults for production; tune to actual load.
param postgresSkuName = 'Standard_D2ds_v5'
param postgresSkuTier = 'GeneralPurpose'
param appServiceSkuName = 'P1v3'
param appServiceSkuTier = 'PremiumV3'
param backupRetentionDays = 35
