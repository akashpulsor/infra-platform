#!/usr/bin/env bash
set -euo pipefail

# ==============================
# CONFIG
# ==============================
export JENKINS_URL=${JENKINS_URL:-http://localhost:8082}
export JENKINS_USER=${JENKINS_USER:-admin}
export JENKINS_TOKEN=${JENKINS_TOKEN:-1182652d570c31169b8a9db5ff1f3c4b61}
JOB_NAME="toggle-admin-dashboard"

WORK_DIR="$(pwd)/_jenkins_jobs"
mkdir -p "$WORK_DIR"

echo "🚀 Creating Jenkins job: $JOB_NAME"
echo "🔗 Jenkins: $JENKINS_URL"

# ==============================
# WRITE JENKINSFILE
# ==============================
cat > "$WORK_DIR/${JOB_NAME}.Jenkinsfile" <<'EOF'
pipeline {
  agent {
    kubernetes {
      yamlFile 'jenkins/agents/docker-agent.yaml'
    }
  }

  parameters {
    choice(name: 'DEPLOY_ENV', choices: ['development', 'staging', 'production'], description: 'Environment to deploy to')
    choice(name: 'DEPLOY_ACTION', choices: ['deploy', 'destroy'], description: 'Deploy or destroy the admin dashboard')
  }

  environment {
    REGISTRY       = "docker.io"
    DOCKER_USER    = "akashtripathi"
    IMAGE_NAME     = "admin-dashboard-ui"
    ARGOCD_SERVER  = "http://argocd-server.argocd.svc.cluster.local:80"
  }

  stages {
    stage('Checkout Repo') {
      steps {
        git branch: 'main', url: 'https://github.com/akashpulsor/infra-platform.git'
      }
    }

    stage('Build & Push Docker Image') {
      when { expression { params.DEPLOY_ACTION == 'deploy' } }
      steps {
        container('docker') {
          withCredentials([usernamePassword(credentialsId: 'dockerhub-credentials', usernameVariable: 'USER', passwordVariable: 'TOKEN')]) {
            sh """
              docker build -t ${IMAGE_NAME}:${BUILD_NUMBER} -f apps/admin-dashboard-ui/Dockerfile .
              echo \$TOKEN | docker login -u \$USER --password-stdin
              docker tag ${IMAGE_NAME}:${BUILD_NUMBER} ${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:${BUILD_NUMBER}
              docker push ${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:${BUILD_NUMBER}
            """
          }
        }
      }
    }

    stage('Toggle Dashboard Deployment') {
      steps {
        sh """
          chmod +x ./infra-platform/scripts/toggle-admin-dashboard.sh
          ./infra-platform/scripts/toggle-admin-dashboard.sh ${params.DEPLOY_ACTION} ${params.DEPLOY_ENV}
        """
      }
    }
  }

  post {
    success {
      echo "✅ ${params.DEPLOY_ACTION} completed successfully for ${params.DEPLOY_ENV}"
    }
    failure {
      echo "❌ ${params.DEPLOY_ACTION} failed for ${params.DEPLOY_ENV}"
    }
  }
}

EOF

# Paste the toggle Jenkinsfile you shared earlier between <<'EOF' and EOF.

# ==============================
# CREATE JOB XML
# ==============================
cat > "$WORK_DIR/${JOB_NAME}.xml" <<EOF
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job@1265.v1675fa_64dceb_">
  <description>Deploy or Destroy the Admin Dashboard on demand</description>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps@3894.vd0f0248b_a_b_10">
    <script>$(sed 's/&/\&amp;/g' "$WORK_DIR/${JOB_NAME}.Jenkinsfile")</script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
EOF

# ==============================
# GET JENKINS CRUMB
# ==============================
CRUMB_JSON=$(curl -s -u "$JENKINS_USER:$JENKINS_TOKEN" "$JENKINS_URL/crumbIssuer/api/json" || true)
CRUMB=$(echo "$CRUMB_JSON" | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p')
CRUMB_FIELD=$(echo "$CRUMB_JSON" | sed -n 's/.*"crumbRequestField":"\([^"]*\)".*/\1/p')

echo "🧩 Got Jenkins crumb: $CRUMB_FIELD=$CRUMB"

# ==============================
# CREATE OR UPDATE JOB
# ==============================
EXISTS=$(curl -s -o /dev/null -w "%{http_code}" -u "$JENKINS_USER:$JENKINS_TOKEN" "$JENKINS_URL/job/$JOB_NAME/config.xml" || true)

if [[ "$EXISTS" == "200" ]]; then
  echo "🔄 Updating existing job..."
  curl -s -X POST -u "$JENKINS_USER:$JENKINS_TOKEN" \
       -H "$CRUMB_FIELD: $CRUMB" \
       -H "Content-Type: application/xml" \
       --data-binary @"$WORK_DIR/${JOB_NAME}.xml" \
       "$JENKINS_URL/job/$JOB_NAME/config.xml"
else
  echo "🆕 Creating new job..."
  curl -s -X POST -u "$JENKINS_USER:$JENKINS_TOKEN" \
       -H "$CRUMB_FIELD: $CRUMB" \
       -H "Content-Type: application/xml" \
       --data-binary @"$WORK_DIR/${JOB_NAME}.xml" \
       "$JENKINS_URL/createItem?name=$JOB_NAME"
fi

echo "✅ Jenkins job '$JOB_NAME' is ready."
