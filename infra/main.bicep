// main.bicep — provisions the Azure resources for the aws-connect Fabric ingestion solution.
// Resources: Key Vault, Document Intelligence, Azure OpenAI (Foundry) + embedding deployment,
// Azure AI Search. Auth is KEYLESS (Entra ID): this subscription enforces disableLocalAuth=true on
// Cognitive Services, so we grant data-plane RBAC roles to the running identity instead of using keys.
//
// Deploy with infra/deploy.ps1 (recommended) or:
//   az deployment group create -g <rg> -f main.bicep -p baseName=<name> adminObjectId=<oid>

@description('Short base name used to derive resource names (3-11 lowercase alphanumerics).')
@minLength(3)
@maxLength(11)
param baseName string = 'awsconn'

@description('Location for Cognitive Services + Key Vault.')
param location string = resourceGroup().location

@description('Location for Azure AI Search (kept separate because some regions lack Search capacity).')
param searchLocation string = 'westus3'

@description('Object ID (GUID) of the user/service principal that RUNS the Fabric notebooks. It receives the data-plane roles and Key Vault access. Get via: az ad signed-in-user show --query id -o tsv')
param adminObjectId string

@description('Embedding model + deployment name.')
param embeddingModel string = 'text-embedding-3-large'
param embeddingModelVersion string = '1'
param embeddingDeploymentName string = 'text-embedding-3-large'
@description('Embedding deployment capacity (x1,000 TPM).')
param embeddingCapacity int = 50

@description('Azure AI Search SKU.')
@allowed(['basic', 'standard'])
param searchSku string = 'basic'

var suffix = uniqueString(resourceGroup().id)
var kvName = toLower('kv-${baseName}-${substring(suffix, 0, 6)}')
var diName = toLower('di-${baseName}-${substring(suffix, 0, 6)}')
var aoaiName = toLower('aoai-${baseName}-${substring(suffix, 0, 6)}')
var searchName = toLower('srch-${baseName}-${substring(suffix, 0, 6)}')

// Built-in role definition IDs (data-plane).
var roleCognitiveServicesUser = 'a97b65f3-24c7-4388-baec-2e87618e0e56'
var roleOpenAiUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var roleSearchIndexDataContributor = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'

// --- Document Intelligence (Cognitive Services, kind FormRecognizer) ---
resource di 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: diName
  location: location
  kind: 'FormRecognizer'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: diName
    publicNetworkAccess: 'Enabled'
  }
}

// --- Azure OpenAI (Cognitive Services, kind OpenAI) ---
resource aoai 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: aoaiName
  location: location
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: aoaiName
    publicNetworkAccess: 'Enabled'
  }
}

resource embedding 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aoai
  name: embeddingDeploymentName
  sku: {
    name: 'Standard'
    capacity: embeddingCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingModel
      version: embeddingModelVersion
    }
  }
}

// --- Azure AI Search (AAD/RBAC data-plane enabled) ---
resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: searchName
  location: searchLocation
  sku: { name: searchSku }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    semanticSearch: 'free'
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http403'
      }
    }
  }
}

// --- Key Vault (retained for any non-service secrets; no service keys under keyless auth) ---
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableSoftDelete: true
    enabledForTemplateDeployment: true
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: adminObjectId
        permissions: {
          secrets: ['get', 'list', 'set']
        }
      }
    ]
  }
}

// --- Data-plane role assignments for the notebook-running identity (keyless auth) ---
resource diRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(di.id, adminObjectId, roleCognitiveServicesUser)
  scope: di
  properties: {
    principalId: adminObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesUser)
  }
}

resource aoaiRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aoai.id, adminObjectId, roleOpenAiUser)
  scope: aoai
  properties: {
    principalId: adminObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleOpenAiUser)
  }
}

resource searchRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, adminObjectId, roleSearchIndexDataContributor)
  scope: search
  properties: {
    principalId: adminObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataContributor)
  }
}

// --- Outputs (feed these into the Fabric `config` table) ---
output kvName string = kv.name
output diEndpoint string = di.properties.endpoint
output aoaiEndpoint string = aoai.properties.endpoint
output embeddingDeployment string = embedding.name
output searchEndpoint string = 'https://${search.name}.search.windows.net'
output searchName string = search.name
