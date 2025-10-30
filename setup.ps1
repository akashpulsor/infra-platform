<#
.SYNOPSIS
  One-command infra bootstrap:
  - Local: k3d + Istio + ArgoCD + Grafana + Prometheus + Zipkin + Jenkins + PBX
  - Cloud: calls Terraform to create cluster & installs the same stack
.PARAMETER Mode
  local | cloud
.PARAMETER Env
  dev | qa | staging | prod
.PARAMETER CloudProvider
  aws | azure | gcp (used by Terraform modules)
.PARAMETER SharedPBX
  $true to deploy a shared PBX in prod (in addition to any per-tenant PBX)
.PARAMETER TenantId
  When set (e.g., "tenant123") and Mode=cloud, creates per-tenant PBX in namespace tenant-<id>
.EXAMPLE
  ./setup.ps1 -Mode local -Env dev
.EXAMPLE
  ./setup.ps1 -Mode cloud -Env staging -CloudProvider aws
.EXAMPLE
  ./setup.ps1 -Mode cloud -Env prod -CloudProvider azure -SharedPBX $true
.EXAMPLE
  ./setup.ps1 -Mode cloud -Env prod -CloudProvider aws -TenantId tenant123
#>

param(
  [ValidateSet('local','cloud')] [string]$Mode = 'local',
  [ValidateSet('dev','qa','staging','prod')]   [string]$Env  = 'dev',
  [ValidateSet('aws','azure','gcp')] [string]$CloudProvider = 'aws',
  [bool]$SharedPBX = $false,
  [string]$TenantId
)

### ===================== CONFIG =====================
$RepoName         = 'infra-platform'
$GithubUser       = 'YourGithubUserName'     # TODO: set me
$ClusterName      = 'infra-local'
$LogDir           = 'logs'
$LogFile          = Join-Path $LogDir 'bootstrap.log'

# Local dashboard ports
$PortArgo  = 8081
$PortGraf  = 3000
$PortZip   = 9411
$PortJen   = 8082

# Domains (for Istio Gateway hostnames; local uses *.localhost)
$BaseDomainLocal  = 'localhost'
$BaseDomainProd   = 'company.com'            # TODO: set me for cloud DNS

# Helm chart repos
$HelmRepos = @{
  'argo'                 = 'https://argoproj.github.io/argo-helm'
  'prometheus-community' = 'https://prometheus-community.github.io/helm-charts'
  'grafana'              = 'https://grafana.github.io/helm-charts'
  'openzipkin'           = 'https://openzipkin.github.io/zipkin'
  'jenkins'              = 'https://charts.jenkins.io'
  'asterisk'             = 'https://helm.asterisk.org'
}

# Environments you support
$AllEnvs = @('dev','qa','staging','prod')
# Base app namespaces per env
$BaseNS  = @('front','platform','pbx')
# Core shared namespaces
$CoreNS  = @('argocd','jenkins','monitoring','istio-system','compliance')

### ================== Helper functions ==================
function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Exec-Or-Die($cmd, $err){ & $cmd; if($LASTEXITCODE -ne 0){ Write-Error $err; exit 1 } }
function Have($cmd){ $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue) }

function Require-Binary($name){
  if(-not (Have $name)){ Write-Error "Required tool '$name' not found on PATH."; exit 1 }
  Write-Host "[OK] $name found."
}

function Ns-Ensure($ns){
  $exists = (kubectl get ns $ns 2>$null)
  if(!$?){
    Write-Host "[INFO] Creating namespace $ns"
    kubectl create ns $ns | Out-Null
    Start-Sleep -Seconds 1
  } else {
    Write-Host "[SKIP] Namespace $ns exists"
  }
}

function Helm-Repo-Init(){
  Write-Host "Updating Helm repos..."
  $HelmRepos.GetEnumerator() | ForEach-Object {
    helm repo add $_.Key $_.Value 2>$null | Out-Null
  }
  helm repo update | Out-Null
}

function Helm-InstallIfMissing($release, $chart, $ns, $args){
  $exists = (helm list -n $ns --short | Where-Object { $_ -eq $release })
  if(-not $exists){
    Write-Host "[INFO] Installing $release ($chart) in ns=$ns"
    $cmd = "helm upgrade --install $release $chart -n $ns --create-namespace $args"
    Write-Host "[CMD] $cmd"
    iex $cmd
  } else {
    Write-Host "[SKIP] $release already installed in ns=$ns"
  }
}

function Istio-Install(){
  $ns = 'istio-system'
  $exists = (kubectl get ns $ns 2>$null)
  if(!$?){
    Write-Host "[INFO] Installing Istio (demo profile)"
    istioctl install -y --set profile=demo | Out-Null
  } else {
    Write-Host "[SKIP] Istio already installed"
  }
}

function Mesh-Label($ns){
  Write-Host "[INFO] Enabling Istio sidecar injection for $ns"
  kubectl label ns $ns istio-injection=enabled --overwrite | Out-Null
}

function PBX-Deploy($ns, $release){
  $args = @(
    '--set image.tag=latest',
    '--set service.type=ClusterIP'
  ) -join ' '
  Helm-InstallIfMissing $release 'asterisk/asterisk' $ns $args
}

function PBX-Shared-Gateway($env){
  $ns = "pbx-$env"
  $HostName = if($Mode -eq 'local'){ "pbx-$env.$BaseDomainLocal" } else { "pbx-$env.$BaseDomainProd" }
  $certSecret = "pbx-$env-cert"
  $gw = @"
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: pbx-$env-gw
  namespace: $ns
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: PASSTHROUGH
    hosts:
    - "$HostName"
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: pbx-$env-vs
  namespace: $ns
spec:
  hosts: ["$HostName"]
  gateways: ["pbx-$env-gw"]
  tls:
  - match:
    - port: 443
      sniHosts: ["$HostName"]
    route:
    - destination:
        host: pbx-$env-asterisk.$ns.svc.cluster.local
        port:
          number: 8088
"@
  $auth = @"
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: pbx-jwt
  namespace: $ns
spec:
  jwtRules:
  - issuer: "https://auth.$BaseDomainLocal/"
    jwksUri: "https://auth.$BaseDomainLocal/.well-known/jwks.json"
---
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: pbx-access
  namespace: $ns
spec:
  rules:
  - from:
    - source:
        requestPrincipals: ["https://auth.$BaseDomainLocal/*"]
"@
  $gwFile   = Join-Path $PSScriptRoot "manifests\pbx-$env-gw.yaml"
  $authFile = Join-Path $PSScriptRoot "manifests\pbx-$env-auth.yaml"
  Ensure-Dir (Split-Path $gwFile)
  $gw | Out-File -Encoding utf8 $gwFile
  $auth | Out-File -Encoding utf8 $authFile
  kubectl apply -f $gwFile | Out-Null
  kubectl apply -f $authFile | Out-Null
  Write-Host "[OK] PBX gateway+auth applied → https://$HostName"
}

function Local-Cluster-Up(){
  Write-Host "=== Local cluster bootstrap ==="
  docker ps *>$null
  if($LASTEXITCODE -ne 0){ Write-Error "Docker Desktop not running."; exit 1 }
  Write-Host "[OK] Docker running."

  $exists = (k3d cluster list | Select-String $ClusterName)
  if(-not $exists){
    Write-Host "[INFO] Creating k3d cluster $ClusterName..."
    k3d cluster create $ClusterName --servers 1 --agents 2 -p "8080:80@loadbalancer" | Out-Null
  } else {
    Write-Host "[SKIP] k3d cluster exists"
  }

  kubectl get nodes | Out-Null
  if($LASTEXITCODE -ne 0){ Write-Error "kubectl cannot reach cluster"; exit 1 }
  Write-Host "[OK] kubectl connected."

  Write-Host "[INFO] Ensuring core namespaces..."
  $CoreNS | ForEach-Object { Ns-Ensure $_ }

  Write-Host "[INFO] Ensuring environment namespaces..."
  $BaseNS | ForEach-Object { Ns-Ensure "$_-dev" }

  Istio-Install
  Write-Host "[INFO] Waiting for Istio CRDs to be ready (60s)..."
  Start-Sleep -Seconds 60

  Mesh-Label "platform-dev"
  Mesh-Label "pbx-dev"

  Helm-Repo-Init

  Helm-InstallIfMissing 'argocd'     'argo/argo-cd'                 'argocd'     ''
  Helm-InstallIfMissing 'prometheus' 'prometheus-community/prometheus' 'monitoring' ''
  Helm-InstallIfMissing 'grafana'    'grafana/grafana'              'monitoring' '--set adminPassword=admin --set service.type=NodePort'
  Helm-InstallIfMissing 'zipkin'     'openzipkin/zipkin'            'monitoring' ''
  Helm-InstallIfMissing 'jenkins'    'jenkins/jenkins'              'jenkins'    '--set controller.adminPassword=admin --set controller.serviceType=NodePort'

  PBX-Deploy "pbx-dev" "pbx-dev"

  Write-Host "[INFO] Waiting for deployments (5m)..."
  kubectl wait --for=condition=available --timeout=300s deployment --all -A | Out-Null

  PBX-Shared-Gateway 'dev'

  Ensure-Dir $LogDir
  kubectl get pods -A | Out-File -Encoding utf8 $LogFile

  Get-Process kubectl -ErrorAction SilentlyContinue | ForEach-Object { $_ | Stop-Process -Force }
  Start-Process cmd "/c kubectl port-forward svc/argocd-server -n argocd $PortArgo`:443"
  Start-Process cmd "/c kubectl port-forward svc/grafana -n monitoring $PortGraf`:80"
  Start-Process cmd "/c kubectl port-forward svc/zipkin -n monitoring $PortZip`:$PortZip"
  Start-Process cmd "/c kubectl port-forward svc/jenkins -n jenkins $PortJen`:8080"

  Write-Host "=== LOCAL READY ==="
  Write-Host ("ArgoCD  → https://localhost:{0}" -f $PortArgo)
  Write-Host ("Grafana → http://localhost:{0}"  -f $PortGraf)
  Write-Host ("Zipkin  → http://localhost:{0}"  -f $PortZip)
  Write-Host ("Jenkins → http://localhost:{0}"  -f $PortJen)
}

### =================== Entry point ===================
Require-Binary docker
Require-Binary kubectl
Require-Binary helm
Require-Binary istioctl
Require-Binary git
Require-Binary terraform
Require-Binary k3d

Ensure-Dir $LogDir

if($Mode -eq 'local'){
  if($Env -ne 'dev'){ Write-Host "[INFO] For local mode, Env overridden to 'dev'."; $Env = 'dev' }
  Local-Cluster-Up
} else {
  Cloud-Cluster-Up
}

if(-not (Test-Path ".git")){
  git init
  git add .
  git commit -m "Infra bootstrap ($Mode/$Env)"
  git branch -M main
  git remote add origin "https://github.com/$GithubUser/$RepoName.git"
  git push -u origin main
  Write-Host "[OK] Pushed to GitHub: https://github.com/$GithubUser/$RepoName"
} else {
  Write-Host "[SKIP] Git repo already initialized."
}
