param(
    [string]$WorkspaceRoot = "C:\deploy\dalai-llama",
    [string]$InfraRepoUrl = "https://github.com/your-org/infra-platform.git",
    [string]$InfraRepoBranch = "main",
    [string]$CloudflareApiToken = "",
    [string]$AcmeEmail = "admin@dalaillama.in",
    [switch]$InstallKind,
    [switch]$CreateKindCluster,
    [string]$KindClusterName = "dalai-llama",
    [switch]$SkipToolInstall,
    [switch]$SkipClone,
    [switch]$SkipNamespaceSetup,
    [switch]$SkipCertManager,
    [switch]$SkipIstio,
    [switch]$SkipObservability,
    [switch]$SkipDeploy,
    [switch]$EnablePbxCore,
    [switch]$EnableAiService
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Install-WingetPackage {
    param(
        [string]$Id,
        [string]$DisplayName
    )

    $existing = winget list --id $Id --exact 2>$null
    if ($LASTEXITCODE -eq 0 -and $existing) {
        Write-Host "$DisplayName already installed"
        return
    }

    Write-Host "Installing $DisplayName via winget"
    winget install --id $Id --exact --accept-package-agreements --accept-source-agreements
}

function Ensure-Tools {
    Write-Step "Installing required tools"
    Assert-Command "winget"

    Install-WingetPackage -Id "Git.Git" -DisplayName "Git"
    Install-WingetPackage -Id "Kubernetes.kubectl" -DisplayName "kubectl"
    Install-WingetPackage -Id "Helm.Helm" -DisplayName "Helm"

    if ($InstallKind -or $CreateKindCluster) {
        Install-WingetPackage -Id "Kubernetes.kind" -DisplayName "kind"
    }

    if (-not (Get-Command istioctl -ErrorAction SilentlyContinue)) {
        Write-Warning "istioctl is not installed. Install it manually before running the Istio steps."
    }
}

function Clone-InfrastructureRepo {
    Write-Step "Cloning infrastructure repository"

    if (-not (Test-Path $WorkspaceRoot)) {
        New-Item -ItemType Directory -Path $WorkspaceRoot | Out-Null
    }

    $repoName = [System.IO.Path]::GetFileNameWithoutExtension($InfraRepoUrl)
    $repoPath = Join-Path $WorkspaceRoot $repoName

    if (Test-Path $repoPath) {
        Write-Host "Repository already exists at $repoPath"
        return $repoPath
    }

    Assert-Command "git"
    git clone --branch $InfraRepoBranch $InfraRepoUrl $repoPath
    return $repoPath
}

function Ensure-KindCluster {
    param([string]$RepoPath)

    if (-not $CreateKindCluster) {
        return
    }

    Write-Step "Creating local kind cluster"
    Assert-Command "kind"

    $clusters = kind get clusters
    if ($clusters -split "\r?\n" | Where-Object { $_ -eq $KindClusterName }) {
        Write-Host "kind cluster '$KindClusterName' already exists"
        return
    }

    kind create cluster --name $KindClusterName
}

function Apply-CloudflareIssuer {
    param([string]$RepoPath)

    if ([string]::IsNullOrWhiteSpace($CloudflareApiToken)) {
        throw "CloudflareApiToken is required to create the cert-manager secret and ClusterIssuer."
    }

    Write-Step "Configuring Cloudflare secret and ClusterIssuer"

    kubectl create secret generic cloudflare-api-token-secret `
        -n cert-manager `
        --from-literal=api-token=$CloudflareApiToken `
        --dry-run=client -o yaml | kubectl apply -f -

    $issuerYaml = @"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: $AcmeEmail
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - selector:
          dnsZones:
            - "dalaillama.in"
        dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token-secret
              key: api-token
"@

    $issuerPath = Join-Path $RepoPath "cloudflare-clusterissuer.generated.yaml"
    Set-Content -Path $issuerPath -Value $issuerYaml -Encoding ascii
    kubectl apply -f $issuerPath
}

function Configure-OptionalServices {
    param([string]$RepoPath)

    $valuesPath = Join-Path $RepoPath "charts\backend-service\values.yaml"
    $content = Get-Content $valuesPath -Raw

    if ($EnablePbxCore) {
        $content = $content -replace 'pbxCoreService:\r?\n(\s+)enabled: false', "pbxCoreService:`r`n`${1}enabled: true"
    }

    if ($EnableAiService) {
        $content = $content -replace 'aiService:\r?\n(\s+)enabled: false', "aiService:`r`n`${1}enabled: true"
    }

    Set-Content -Path $valuesPath -Value $content -Encoding ascii
}

function Cleanup-KeycloakJobs {
    Write-Host "[INFO] Cleaning up stale Keycloak jobs"
    kubectl delete job -n apps keycloak-realm-import --ignore-not-found=true | Out-Null
    kubectl delete job -n apps keycloak-realm-import-managed --ignore-not-found=true | Out-Null
}

function Run-Deployment {
    param([string]$RepoPath)

    Push-Location $RepoPath
    try {
        if (-not $SkipNamespaceSetup) {
            Write-Step "Creating namespaces"
            kubectl apply -f istio-namespaces.yaml
            kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
            kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
        }

        if (-not $SkipCertManager) {
            Write-Step "Installing cert-manager"
            helm repo add jetstack https://charts.jetstack.io
            helm repo update
            helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --set installCRDs=true
            Apply-CloudflareIssuer -RepoPath $RepoPath
        }

        if (-not $SkipIstio) {
            Write-Step "Installing Istio"
            Assert-Command "istioctl"
            istioctl install -y --set profile=default

            kubectl apply -f istio-namespaces.yaml
            kubectl label namespace infra istio-injection=disabled --overwrite
            kubectl label namespace apps istio-injection=enabled --overwrite
            kubectl rollout restart deployment --all -n apps
            kubectl rollout restart deployment --all -n infra
            kubectl rollout restart statefulset --all -n infra
        }

        if (-not $SkipObservability) {
            Write-Step "Installing Istio observability addons"
            kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/prometheus.yaml
            kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/grafana.yaml
            kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/kiali.yaml
            kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/jaeger.yaml
            kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/extras/zipkin.yaml
        }

        if ($EnablePbxCore -or $EnableAiService) {
            Write-Step "Enabling optional backend services"
            Configure-OptionalServices -RepoPath $RepoPath
        }

        if (-not $SkipDeploy) {
            Write-Step "Building infra chart dependencies"
            helm dependency build charts/infra

            Write-Step "Deploying infra"
            helm upgrade --install infra charts/infra -n infra -f charts/infra/values.yaml -f charts/infra/values-secret.yaml

            Write-Step "Deploying Keycloak"
            Cleanup-KeycloakJobs
            helm upgrade --install keycloak charts/keycloak -n apps -f charts/keycloak/values.yaml -f charts/keycloak/values-prod.yaml -f charts/keycloak/values-secret.yaml

            Write-Step "Deploying backend"
            helm upgrade --install backend charts/backend-service -n apps -f charts/backend-service/values.yaml -f charts/backend-service/values-secret.yaml

            Write-Step "Deploying platform UI"
            helm upgrade --install platform-ui charts/platform-ui -n apps -f charts/platform-ui/values.yaml

            Write-Step "Deploying dashboard UI"
            helm upgrade --install dashboard-ui charts/dashboard-ui -n apps -f charts/dashboard-ui/values.yaml

            Write-Step "Deploying creator UI"
            helm upgrade --install creator-ui charts/creator-ui -n apps -f charts/creator-ui/values.yaml

            Write-Step "Deploying gateway"
            helm upgrade --install gateway charts/gateway -n istio-system -f charts/gateway/values.yaml
        }
    }
    finally {
        Pop-Location
    }
}

Write-Host "Dalai LLAMA bootstrap + deploy script" -ForegroundColor Green
Write-Host "This script assumes your secret values files are already filled locally." -ForegroundColor Yellow
Write-Host "It also assumes Cloudflare DNS is already set up for dalaillama.in." -ForegroundColor Yellow

if (-not $SkipToolInstall) {
    Ensure-Tools
}

$repoPath = if ($SkipClone) { (Get-Location).Path } else { Clone-InfrastructureRepo }

Ensure-KindCluster -RepoPath $repoPath
Run-Deployment -RepoPath $repoPath

Write-Step "Done"
Write-Host "If you also need the telecom host stack, run ./tele_infra.sh separately on that host." -ForegroundColor Yellow
