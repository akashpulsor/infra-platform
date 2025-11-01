pipeline {
  agent { kubernetes { yamlFile 'jenkins/agents/docker-agent.yaml' } }

  parameters {
    choice(name: 'DEPLOY_ENV', choices: ['development', 'staging', 'production'], description: 'Select target environment')
    string(name: 'APP_BRANCH', defaultValue: 'v4', description: 'App repo branch')
    string(name: 'IMAGE_TAG',  defaultValue: '',  description: 'Optional image tag; leave empty to build new')
  }

  environment {
    REGISTRY        = "docker.io"
    DOCKER_USER     = "akashtripathi"
    IMAGE_NAME      = "admin-dashboard-ui"

    APP_REPO        = "https://github.com/akashpulsor/dalai-llama.git"
    INFRA_REPO      = "https://github.com/akashpulsor/infra-platform.git"
    INFRA_BRANCH    = "main"

    ARGOCD_SERVER   = "http://argocd-server.argocd.svc.cluster.local:80"
    CHART_PATH      = "charts/admin-dashboard-ui"
  }

  stages {

    stage('Set environment context') {
      steps {
        script {
          if (params.DEPLOY_ENV == 'development') {
            env.NAMESPACE     = "front-dev"
            env.DOMAIN_SUFFIX = "dev.localhost"
            env.ARGO_APP_NAME = "admin-dashboard-ui-dev"
            env.API_BASE_URL  = "https://api.dev.localhost"
            env.AUTH_ISSUER   = "https://auth.dev.localhost"
          } else if (params.DEPLOY_ENV == 'staging') {
            env.NAMESPACE     = "front-staging"
            env.DOMAIN_SUFFIX = "staging.localhost"
            env.ARGO_APP_NAME = "admin-dashboard-ui-staging"
            env.API_BASE_URL  = "https://api.staging.localhost"
            env.AUTH_ISSUER   = "https://auth.staging.localhost"
          } else {
            env.NAMESPACE     = "front-prod"
            env.DOMAIN_SUFFIX = "prod.localhost"
            env.ARGO_APP_NAME = "admin-dashboard-ui-prod"
            env.API_BASE_URL  = "https://api.prod.localhost"
            env.AUTH_ISSUER   = "https://auth.prod.localhost"
          }

          echo """
          Environment context:
          DEPLOY_ENV  = ${params.DEPLOY_ENV}
          Namespace   = ${env.NAMESPACE}
          Hostname    = admin.dashboard.${env.DOMAIN_SUFFIX}
          """
        }
      }
    }

    stage('Checkout infra repo') {
      steps { git branch: "${INFRA_BRANCH}", url: "${INFRA_REPO}" }
    }

    stage('Checkout app repo') {
      steps {
        dir('app-src') {
          git branch: "${params.APP_BRANCH}", url: "${APP_REPO}"
        }
      }
    }

    stage('Build & Push image (optional)') {
      when { expression { return !params.IMAGE_TAG?.trim() } }
      steps {
        container('docker') {
          withCredentials([usernamePassword(credentialsId: 'dockerhub-credentials', usernameVariable: 'USER', passwordVariable: 'TOKEN')]) {
            dir('app-src') {
              script {
                // FIX: Add current directory to Git's safe list to avoid "dubious ownership" error
                sh 'git config --global --add safe.directory "$PWD"' 
                
                env.SHORT_SHA = sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim()
                env.BUILD_TAG = "${env.BUILD_NUMBER}-${env.SHORT_SHA}"
              }
              sh """
                docker build -t ${IMAGE_NAME}:${BUILD_TAG} -f apps/admin-dashboard-ui/Dockerfile .
                echo \$TOKEN | docker login -u \$USER --password-stdin
                docker tag ${IMAGE_NAME}:${BUILD_TAG} ${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:${BUILD_TAG}
                docker push ${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:${BUILD_TAG}
              """
            }
          }
        }
      }
    }

    stage('Set final image tag') {
      steps {
        script {
          env.FINAL_TAG = params.IMAGE_TAG?.trim() ? params.IMAGE_TAG.trim() : env.BUILD_TAG
          echo "Using image tag: ${env.FINAL_TAG}"
        }
      }
    }

    stage('Create environment values override') {
      steps {
        script {
          def overrideFile = "/tmp/admin-dashboard-${params.DEPLOY_ENV}-override.yaml"
          def content = """
image:
  repository: ${env.REGISTRY}/${env.DOCKER_USER}/${env.IMAGE_NAME}
  tag: "${env.FINAL_TAG}"
env:
  NODE_ENV: "${params.DEPLOY_ENV}"
  API_BASE_URL: "${env.API_BASE_URL}"
  AUTH_ISSUER: "${env.AUTH_ISSUER}"
  CLIENT_ID: "admin-dashboard-ui-${params.DEPLOY_ENV}"
istio:
  enabled: true
  gatewayName: platform-ui-gateway
  host: admin.dashboard.${env.DOMAIN_SUFFIX}
auth:
  enabled: true
  issuer: ${env.AUTH_ISSUER}/
  jwksUri: ${env.AUTH_ISSUER}/.well-known/jwks.json
  audiences: ["admin-dashboard-ui"]
  roleClaim: "role"
  allowedRoles: ["super-admin","platform-admin","org-admin"]
  requiredScopes: ["dashboard:admin"]
"""
          writeFile file: overrideFile, text: content
          echo "Generated values override for ${params.DEPLOY_ENV}:"
          sh "cat ${overrideFile}"
        }
      }
    }

    stage('Deploy or Sync ArgoCD App') {
      steps {
        withCredentials([string(credentialsId: 'argocd-token', variable: 'ARGOCD_TOKEN')]) {
          script {
            def appName = "admin-dashboard-ui-${params.DEPLOY_ENV}"
            def namespace = env.NAMESPACE

            def argoAppSpec = """
{
  "metadata": { "name": "${appName}", "namespace": "argocd" },
  "spec": {
    "project": "dalai-llama",
    "source": {
      "repoURL": "${INFRA_REPO}",
      "targetRevision": "${INFRA_BRANCH}",
      "path": "${CHART_PATH}",
      "helm": {
        "parameters": [
          { "name": "image.repository", "value": "${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}" },
          { "name": "image.tag", "value": "${FINAL_TAG}" },
          { "name": "env.NODE_ENV", "value": "${params.DEPLOY_ENV}" },
          { "name": "env.API_BASE_URL", "value": "${env.API_BASE_URL}" },
          { "name": "env.AUTH_ISSUER", "value": "${env.AUTH_ISSUER}" },
          { "name": "istio.host", "value": "admin.dashboard.${env.DOMAIN_SUFFIX}" },
           // ✅ keep gateway intact
          { "name": "istio.gateway.create", "value": "false" },
          { "name": "istio.gateway.name",   "value": "platform-ui-gateway" }
        ]
      }
    },
    "destination": {
      "server": "https://kubernetes.default.svc",
      "namespace": "${namespace}"
    },
    "syncPolicy": {
      "automated": { "prune": true, "selfHeal": true }
    }
  }
}
"""

// Create or update ArgoCD Application dynamically (safe deployment)
sh """
  echo "Deploying ArgoCD Application: ${appName}"

  # Important: ensure gateway is NOT deployed again
  yq eval 'del(.spec.template.spec.gateways)' charts/admin-dashboard-ui/templates/virtualservice.yaml || true

  curl -s -X POST ${ARGOCD_SERVER}/api/v1/applications \
       -H "Authorization: Bearer \$ARGOCD_TOKEN" \
       -H "Content-Type: application/json" \
       -d '${argoAppSpec}' || true

  echo "Triggering ArgoCD sync..."
  curl -s -X POST \
       -H "Authorization: Bearer \$ARGOCD_TOKEN" \
       -H "Content-Type: application/json" \
       -d '{"name": "${appName}"}' \
       ${ARGOCD_SERVER}/api/v1/applications/${appName}/sync || true
"""

          }
        }
      }
    } 
  }

  post {
    success { echo "✅ Deployed Admin Dashboard (${env.FINAL_TAG}) to ${params.DEPLOY_ENV}" }
    failure { echo "❌ Pipeline failed" }
  }
}