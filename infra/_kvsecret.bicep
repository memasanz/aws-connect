param kvName string
param secretName string
@secure()
param secretValue string
resource s 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  name: '${kvName}/${secretName}'
  properties: { value: secretValue }
}
