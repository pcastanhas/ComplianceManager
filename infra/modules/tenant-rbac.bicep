// =====================================================================
// Assigns a role to a principal within the (tenants) resource group.
// Used as a module so a subscription-scoped template can grant RG-scoped
// access, and so the principalId (a module output passed as a param) is
// known at the start of this nested deployment.
// =====================================================================

@description('Object id of the principal to grant the role to.')
param principalId string

@description('Full resource id of the role definition.')
param roleDefinitionId string

@allowed(['ServicePrincipal', 'Group', 'User'])
param principalType string = 'ServicePrincipal'

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalId, roleDefinitionId)
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: principalType
  }
}
