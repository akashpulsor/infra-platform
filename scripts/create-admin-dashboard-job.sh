#!/usr/bin/env bash
# set -e: Exit immediately if a command exits with a non-zero status.
# set -u: Treat unset variables as an error.
# set -o pipefail: The return value of a pipeline is the value of the last command
#                  to exit with a non-zero status, or zero if all commands exit successfully.
set -euo pipefail

# ==============================
# 1. CONFIGURATION & VARIABLES
# ==============================

# Jenkins Access Configuration
export JENKINS_URL=${JENKINS_URL:-http://localhost:8082}
export JENKINS_USER=${JENKINS_USER:-admin}
# NOTE: Using the token you provided. Ensure this is a valid API Token!
export JENKINS_TOKEN=${JENKINS_TOKEN:-1182652d570c31169b8a9db5ff1f3c4b61} 

# Repository & Directory Configuration (REQUIRED FOR SCRIPT LOGIC)
INFRA_REPO_URL="https://github.com/akashpulsor/infra-platform.git"
JOB_NAME="deploy-admin-dashboard-ui"

# Define temporary working directory (where job XML and Jenkinsfile are written)
WORK_DIR="_temp_jenkins_setup"
# Define a directory that mirrors where your infra code *would* be cloned, 
# for the purpose of constructing the absolute path used in the Jenkins XML template.
# This variable was missing and caused the "unbound variable" error.
INFRA_DIR="$WORK_DIR/infra-platform" 

# Ensure directories exist
mkdir -p "$WORK_DIR"
# The infra folder needs to be created because the rest of the logic tries to put
# the Jenkinsfile inside it.
mkdir -p "$INFRA_DIR/jenkins/pipelines"

# --- Job Setup Variables ---
JOB_XML_PATH="$WORK_DIR/job-config.xml"
JENKINSFILE_PATH="$INFRA_DIR/jenkins/pipelines/${JOB_NAME}.Jenkinsfile"


# ==============================
# 2. WRITE JENKINSFILE (Put this inside the INFRA_DIR structure for SCM pathing)
# ==============================
# ==============================
# WRITE JENKINSFILE
# ==============================
cat > "$WORK_DIR/${JOB_NAME}.Jenkinsfile" <<'EOF'
pipeline {
  agent { kubernetes { yamlFile 'jenkins/agents/docker-agent.yaml' } }

  parameters {
    choice(name: 'DEPLOY_ENV', choices: ['development', 'staging', 'production'], description: 'Select target environment')
    string(name: 'APP_BRANCH', defaultValue: 'v4', description: 'App repo branch')
    string(name: 'IMAGE_TAG',  defaultValue: '',   description: 'Optional image tag; leave empty to build new')
  }

  environment {
    REGISTRY      = "docker.io"
    DOCKER_USER   = "akashtripathi"
    IMAGE_NAME    = "admin-dashboard-ui"

    APP_REPO      = "https://github.com/akashpulsor/dalai-llama.git"
    INFRA_REPO    = "https://github.com/akashpulsor/infra-platform.git"
    INFRA_BRANCH  = "main"

    ARGOCD_SERVER = "http://argocd-server.argocd.svc.cluster.local:80"
    CHART_PATH    = "charts/admin-dashboard-ui"
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

            // Create or update ArgoCD Application dynamically
            sh """
              echo "Deploying ArgoCD Application: ${appName}"
              curl -s -X POST ${ARGOCD_SERVER}/api/v1/applications \
                   -H "Authorization: Bearer $ARGOCD_TOKEN" \
                   -H "Content-Type: application/json" \
                   -d '${argoAppSpec}' || true

              echo "Triggering ArgoCD sync..."
              curl -s -X POST \
                   -H "Authorization: Bearer $ARGOCD_TOKEN" \
                   -H "Content-Type: application/json" \
                   -d '{"name": "${appName}"}' \
                   ${ARGOCD_SERVER}/api/v1/applications/${appName}/sync || true
            """
          }
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

EOF

# ==============================
# 3. AUTOMATE JENKINS PIPELINE SETUP
# ==============================

echo "⚙️  Setting up Jenkins pipeline inside cluster..."

echo "📡 Creating Jenkins job configuration XML..."

# ==============================
# CREATE JOB XML (Pipeline from SCM) - FIX APPLIED HERE
# ==============================
# Using wildcards (@*) instead of specific plugin versions to avoid 500 Server Error
cat > "$JOB_XML_PATH" <<EOF
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job@*">
  <description>Deploys the Admin Dashboard UI via GitOps using ArgoCD and SCM.</description>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps@*">
    <scm class="hudson.plugins.git.GitSCM" plugin="git@*">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>$INFRA_REPO_URL</url>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="empty-list"/>
      <extensions/>
    </scm>
    <scriptPath>jenkins/pipelines/${JOB_NAME}.Jenkinsfile</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
EOF

echo "📡 Uploading Jenkins job definition..."

# ==============================
# GET JENKINS CRUMB (Using JENKINS_TOKEN)
# ==============================
CRUMB_JSON=$(curl -s -u "$JENKINS_USER:$JENKINS_TOKEN" "$JENKINS_URL/crumbIssuer/api/json")
CRUMB=$(echo "$CRUMB_JSON" | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p')
CRUMB_FIELD=$(echo "$CRUMB_JSON" | sed -n 's/.*"crumbRequestField":"\([^"]*\)".*/\1/p')

# Fallback check for crumb field name, though usually "Jenkins-Crumb"
CRUMB_FIELD=${CRUMB_FIELD:-"Jenkins-Crumb"} 

echo "🧩 Got Jenkins crumb: $CRUMB_FIELD=$CRUMB"


# ==============================
# CREATE OR UPDATE JOB (Using JENKINS_TOKEN)
# ==============================

# Attempt to create the item, if it fails (HTTP 400 likely), update it
curl -s -X POST -u "$JENKINS_USER:$JENKINS_TOKEN" \
  -H "$CRUMB_FIELD: $CRUMB" \
  -H "Content-Type: application/xml" \
  --data-binary @"$JOB_XML_PATH" \
  "$JENKINS_URL/createItem?name=$JOB_NAME" \
  && echo "✅ Jenkins pipeline '$JOB_NAME' created successfully." \
  || ( \
    echo "🔄 Job creation failed (likely exists or error). Attempting update..." && \
    curl -s -X POST -u "$JENKINS_USER:$JENKINS_TOKEN" \
      -H "$CRUMB_FIELD: $CRUMB" \
      -H "Content-Type: application/xml" \
      --data-binary @"$JOB_XML_PATH" \
      "$JENKINS_URL/job/$JOB_NAME/config.xml" \
      && echo "✅ Jenkins pipeline '$JOB_NAME' updated successfully." \
      || echo "❌ Failed to create or update job '$JOB_NAME'. Check Jenkins logs for 500 error details." \
  )

# ==============================
# TRIGGER INITIAL BUILD (Using JENKINS_TOKEN)
# ==============================
echo "🚀 Triggering initial build..."
curl -s -X POST -u "$JENKINS_USER:$JENKINS_TOKEN" \
  -H "$CRUMB_FIELD: $CRUMB" \
  "$JENKINS_URL/job/$JOB_NAME/build" \
  && echo "✅ Build triggered." \
  || echo "❌ Failed to trigger build."