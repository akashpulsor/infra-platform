param(
  [Parameter(Mandatory=$true)][string]$OrgName,
  [Parameter(Mandatory=$true)][string]$UIRepo
)

$root = "infra"
$envs = @("dev","qa","staging","prod")

function Write-Yaml($path, $content) {
  $dir = Split-Path $path
  if (!(Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $content | Out-File -Encoding utf8 -FilePath $path
}

Write-Host "Creating infra structure..."
New-Item -ItemType Directory -Force -Path "$root/jenkins/pipelines" | Out-Null

foreach ($env in $envs) {
  $base = "$root/environments/$env/manifests"
  New-Item -ItemType Directory -Force -Path "$base/shared-tenant" | Out-Null
  New-Item -ItemType Directory -Force -Path "$base/platform" | Out-Null

  # --- Namespaces ---
  Write-Yaml "$base/namespaces.yaml" @'
apiVersion: v1
kind: List
items:
  - kind: Namespace
    apiVersion: v1
    metadata: { name: argocd }
  - kind: Namespace
    apiVersion: v1
    metadata: { name: monitoring }
  - kind: Namespace
    apiVersion: v1
    metadata: { name: jenkins }
  - kind: Namespace
    apiVersion: v1
    metadata: { name: tenant-shared }
  - kind: Namespace
    apiVersion: v1
    metadata: { name: platform }
'@

  # --- ArgoCD Project ---
  Write-Yaml "$base/argocd-project-dalai-llama.yaml" @'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: dalai-llama
  namespace: argocd
spec:
  description: DalaiLlama multi-tenant admin project
  sourceRepos: [ "*" ]
  destinations:
    - { namespace: platform, server: https://kubernetes.default.svc }
    - { namespace: tenant-shared, server: https://kubernetes.default.svc }
  clusterResourceWhitelist:
    - { group: "*", kind: "*" }
'@

  # --- ArgoCD Application ---
  Write-Yaml "$base/argocd-app-dalai-llama-ui.yaml" @'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dalai-llama-ui
  namespace: argocd
spec:
  project: dalai-llama
  source:
    repoURL: REPO_PLACEHOLDER
    targetRevision: HEAD
    path: .
  destination:
    server: https://kubernetes.default.svc
    namespace: tenant-shared
  syncPolicy:
    automated: { prune: true, selfHeal: true }
'@ -replace 'REPO_PLACEHOLDER', $UIRepo

  # --- Shared Tenant PBX ---
  Write-Yaml "$base/shared-tenant/pbx-deployment.yaml" @'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: freepbx
  namespace: tenant-shared
spec:
  replicas: 1
  selector:
    matchLabels: { app: freepbx }
  template:
    metadata:
      labels: { app: freepbx }
    spec:
      containers:
      - name: freepbx
        image: tiredofit/freepbx:latest
        ports:
        - { containerPort: 80 }
        env:
        - { name: VIRTUAL_HOST, value: "dalaillama-tier1.localhost" }
        - { name: DB_EMBEDDED, value: "TRUE" }
'@

  Write-Yaml "$base/shared-tenant/pbx-service.yaml" @'
apiVersion: v1
kind: Service
metadata:
  name: freepbx
  namespace: tenant-shared
spec:
  selector: { app: freepbx }
  ports:
    - { name: http, port: 80, targetPort: 80 }
  type: ClusterIP
'@

  Write-Yaml "$base/shared-tenant/pbx-istio-gateway.yaml" @'
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: pbx-gateway
  namespace: tenant-shared
spec:
  selector: { istio: ingressgateway }
  servers:
  - port: { number: 80, name: http, protocol: HTTP }
    hosts: [ "dalaillama-tier1.localhost" ]
'@

  Write-Yaml "$base/shared-tenant/pbx-istio-virtualservice.yaml" @'
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: pbx-vs
  namespace: tenant-shared
spec:
  hosts: [ "dalaillama-tier1.localhost" ]
  gateways: [ pbx-gateway ]
  http:
  - route:
    - destination:
        host: freepbx.tenant-shared.svc.cluster.local
        port: { number: 80 }
'@

  # --- Platform Core Services ---
  Write-Yaml "$base/platform/auth-deployment.yaml" @'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: auth-service
  namespace: platform
spec:
  replicas: 1
  selector:
    matchLabels: { app: auth-service }
  template:
    metadata:
      labels: { app: auth-service }
    spec:
      containers:
      - name: auth-service
        image: nginx
        ports:
        - { containerPort: 8080 }
'@

  Write-Yaml "$base/platform/registration-deployment.yaml" @'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registration-service
  namespace: platform
spec:
  replicas: 1
  selector:
    matchLabels: { app: registration-service }
  template:
    metadata:
      labels: { app: registration-service }
    spec:
      containers:
      - name: registration-service
        image: nginx
        ports:
        - { containerPort: 8080 }
'@

  Write-Yaml "$base/platform/billing-deployment.yaml" @'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: billing-service
  namespace: platform
spec:
  replicas: 1
  selector:
    matchLabels: { app: billing-service }
  template:
    metadata:
      labels: { app: billing-service }
    spec:
      containers:
      - name: billing-service
        image: nginx
        ports:
        - { containerPort: 8080 }
'@
}

# Jenkins pipeline file
Write-Yaml "$root/jenkins/pipelines/tenant-create.Jenkinsfile" @'
pipeline {
  agent any
  parameters {
    string(name: "TENANT_ID", defaultValue: "acme", description: "Tenant name/id")
  }
  environment {
    KUBECONFIG = credentials("k3d-kubeconfig")
  }
  stages {
    stage("Create Tenant Namespace") {
      steps {
        sh "kubectl create ns tenant-${TENANT_ID} || true"
      }
    }
    stage("Deploy Tenant PBX") {
      steps {
        sh """
        kubectl apply -n tenant-${TENANT_ID} -f infra/environments/dev/manifests/shared-tenant/pbx-deployment.yaml
        kubectl apply -n tenant-${TENANT_ID} -f infra/environments/dev/manifests/shared-tenant/pbx-service.yaml
        """
      }
    }
  }
}
'@

Write-Host ""
Write-Host "Infra repo created successfully with tenant-shared + platform namespaces and Jenkins tenant-create pipeline."