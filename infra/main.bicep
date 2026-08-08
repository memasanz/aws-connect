// main.bicep — provisions the Azure resources for the aws-connect Fabric ingestion solution.
// Resources: Key Vault, Document Intelligence, Azure OpenAI (Foundry) + embedding deployment,
// Azure AI Search. Service keys are written into Key Vault as secrets.
//
// Deploy with infra/deploy.ps1 (recommended) or:
//   az deployment group create -g <rg> -f main.bicep -p baseName=<name> adminObjectId=<oid>

@description('Short base name used to derive resource names (3-11 lowercase alphanumerics).')
@minLength(3)
@maxLength(11)
param baseName string = 'awsconn'

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Object ID (GUID) of the user/service principal that needs to read Key Vault secrets (e.g. the identity running the Fabric notebooks). Get via: az ad signed-in-user show --query id -o tsv')
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

// --- Azure AI Search ---
resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: searchName
  location: location
  sku: { name: searchSku }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    semanticSearch: 'free'
  }
}

// --- Key Vault (access-policy model; grants the admin identity secret get/list) ---
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

resource secretDi 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'doc-intelligence-key'
  properties: {
    value: di.listKeys().key1
  }
}

resource secretAoai 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'aoai-key'
  properties: {
    value: aoai.listKeys().key1
  }
}

resource secretSearch 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'search-admin-key'
  properties: {
    value: search.listAdminKeys().primaryKey
  }
}

// --- Outputs (feed these into the Fabric `config` table) ---
output kvName string = kv.name
output diEndpoint string = di.properties.endpoint
output aoaiEndpoint string = aoai.properties.endpoint
output embeddingDeployment string = embedding.name
output searchEndpoint string = 'https://${search.name}.search.windows.net'
output searchName string = search.name
