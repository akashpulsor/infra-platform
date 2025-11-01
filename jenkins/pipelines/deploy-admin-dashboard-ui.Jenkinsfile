pipeline {
  agent { kubernetes { yamlFile 'jenkins/agents/docker-agent.yaml' } }

  parameters {
    choice(name: 'DEPLOY_ENV', choices: ['development', 'staging', 'production'], description: 'Select target environment')
    string(name: 'APP_BRANCH', defaultValue: 'v4', description: 'App repo branch to build from')
    string(name: 'IMAGE_TAG',  defaultValue: '',  description: 'Optional image tag; leave empty to build new')
  }

  environment {
    REGISTRY        = "docker.io"
    DOCKER_USER     = "akashtripathi"
    IMAGE_NAME      = "admin-dashboard-ui"

    APP_REPO        = "https://github.com/akashpulsor/dalai-llama.git"
    INFRA_REPO      = "https://github.com/akashpulsor/infra-platform.git"
    INFRA_BRANCH    =  {$APP_BRANCH}

    ARGOCD_SERVER   = "https://argocd-server.argocd.svc.cluster.local:443"
    CHART_PATH      = "charts/admin-dashboard-ui"
  }

  stages {

    stage('Set Environment Context') {
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
          🌍 Environment context:
          DEPLOY_ENV  = ${params.DEPLOY_ENV}
          Namespace   = ${env.NAMESPACE}
          Hostname    = admin.dashboard.${env.DOMAIN_SUFFIX}
          """
        }
      }
    }

    stage('Checkout Infra Repo') {
      steps { git branch: "${INFRA_BRANCH}", url: "${INFRA_REPO}" }
    }

    stage('Checkout App Repo') {
      steps {
        dir('app-src') {
          git branch: "${params.APP_BRANCH}", url: "${APP_REPO}"
        }
      }
    }

    stage('Build & Push Docker Image (if IMAGE_TAG empty)') {
      when { expression { return !params.IMAGE_TAG?.trim() } }
      steps {
        container('docker') {
          withCredentials([usernamePassword(credentialsId: 'dockerhub-credentials', usernameVariable: 'USER', passwordVariable: 'TOKEN')]) {
            dir('app-src') {
              script {
                sh 'git config --global --add safe.directory "$PWD"'
                env.SHORT_SHA = sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim()
                env.BUILD_TAG = "${env.BUILD_NUMBER}-${env.SHORT_SHA}"
              }

              sh '''
                echo "🔧 Building Docker image ${IMAGE_NAME}:${BUILD_TAG}..."
                docker build -t ${IMAGE_NAME}:${BUILD_TAG} -f apps/admin-dashboard-ui/Dockerfile .

                echo "🔐 Logging in to Docker Hub..."
                echo "$TOKEN" | docker login -u "$USER" --password-stdin || exit 1

                echo "📦 Tagging and pushing image..."
                docker tag ${IMAGE_NAME}:${BUILD_TAG} ${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:${BUILD_TAG}
                docker push ${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:${BUILD_TAG} || exit 1

                echo "✅ Image pushed successfully to Docker Hub!"
              '''
            }
          }
        }
      }
    }

    stage('Set Final Image Tag') {
      steps {
        script {
          env.FINAL_TAG = params.IMAGE_TAG?.trim() ? params.IMAGE_TAG.trim() : env.BUILD_TAG
          echo "🧩 Using final image tag: ${env.FINAL_TAG}"
        }
      }
    }

    stage('Create Environment Override File') {
  steps {
    script {
      def overrideFile = "${env.WORKSPACE}/admin-dashboard-${params.DEPLOY_ENV}-override.yaml"
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

      echo "🧾 Generated Helm override file at: ${overrideFile}"
      sh "ls -l ${env.WORKSPACE} | grep override || true"
      sh "cat ${overrideFile}"

      // ✅ archiveArtifacts now can find it
      archiveArtifacts artifacts: "admin-dashboard-${params.DEPLOY_ENV}-override.yaml", onlyIfSuccessful: true
    }
  }
}


    stage('Deploy via ArgoCD API (HTTPS)') {
      steps {
        withCredentials([string(credentialsId: 'argocd-token', variable: 'ARGOCD_TOKEN')]) {
          script {
            def appName = "admin-dashboard-ui-${params.DEPLOY_ENV}"
            def namespace = env.NAMESPACE

            def argoAppSpec = """
{
  "metadata": { "name": "${appName}", "namespace": "argocd" },
  "spec": {
    "project": "default",
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
          { "name": "istio.enabled", "value": "true" },
          { "name": "istio.gatewayName", "value": "platform-ui-gateway" },
          { "name": "istio.host", "value": "admin.dashboard.${env.DOMAIN_SUFFIX}" }
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

            sh """
              echo "🚀 Creating or updating ArgoCD app: ${appName}"
              curl -k -s -X POST ${ARGOCD_SERVER}/api/v1/applications \
                -H "Authorization: Bearer ${ARGOCD_TOKEN}" \
                -H "Content-Type: application/json" \
                -d '${argoAppSpec}' || true

              echo "🔁 Triggering ArgoCD sync..."
              curl -k -s -X POST \
                -H "Authorization: Bearer ${ARGOCD_TOKEN}" \
                -H "Content-Type: application/json" \
                -d '{"name": "${appName}"}' \
                ${ARGOCD_SERVER}/api/v1/applications/${appName}/sync || true

              echo "⏳ Waiting 20s for sync to settle..."
              sleep 20
              curl -k -s -H "Authorization: Bearer ${ARGOCD_TOKEN}" ${ARGOCD_SERVER}/api/v1/applications/${appName} | grep -E '"sync|health"'
            """
          }
        }
      }
    }
  }

  post {
    success {
      echo "✅ Successfully deployed Admin Dashboard (${env.FINAL_TAG}) to ${params.DEPLOY_ENV}"
    }
    failure {
      echo "❌ Deployment failed. Check ArgoCD logs or API connectivity."
    }
  }
}
