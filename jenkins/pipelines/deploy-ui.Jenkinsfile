pipeline {
  agent {
    kubernetes {
      yamlFile 'jenkins/agents/docker-agent.yaml'   // ✅ Uses your Docker-enabled Kubernetes agent
    }
  }

  environment {
    REGISTRY       = "docker.io"
    DOCKER_USER    = "akashtripathi"
    IMAGE_NAME     = "platform-ui"
    BRANCH         = "v4"
    APP_REPO       = "https://github.com/akashpulsor/dalai-llama.git"
    ARGOCD_SERVER  = "http://argocd-server.argocd.svc.cluster.local:80"
  }

  stages {

    // =====================================================
    stage('Checkout Repo') {
      steps {
        echo "📦 Checking out dalai-llama repo (${BRANCH})..."
        git branch: "${BRANCH}", url: "${APP_REPO}"
      }
    }

    // =====================================================
stage('Build & Push Docker Image') {
  steps {
    container('docker') {
      withCredentials([usernamePassword(credentialsId: 'dockerhub-credentials', usernameVariable: 'USER', passwordVariable: 'TOKEN')]) {
        script {
          // Fix: allow Git to run inside Jenkins workspace
          sh 'git config --global --add safe.directory /home/jenkins/agent/workspace/deploy-platform-ui'

          // Capture commit hash
          env.GIT_COMMIT_SHORT = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
          env.IMAGE_TAG = "${BUILD_NUMBER}-${GIT_COMMIT_SHORT}"

          sh """
            echo "🔨 Building Docker image using root context..."
            docker build -t ${IMAGE_NAME}:${IMAGE_TAG} -f apps/platform-ui/Dockerfile .

            echo "🔑 Logging into Docker Hub..."
            echo \$TOKEN | docker login -u \$USER --password-stdin

            echo "🚀 Tagging and pushing image..."
            docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:${IMAGE_TAG}
            docker push ${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:${IMAGE_TAG}
          """
        }
      }
    }
  }
}

    // =====================================================
    stage('Update Deployment Manifest') {
      steps {
        withCredentials([string(credentialsId: 'github-pat', variable: 'GHTOKEN')]) {
          sh """
            echo "📝 Updating deployment image in k8s/homepage/deployment.yaml..."
            
            git config user.email "ci@${DOCKER_USER}.local"
            git config user.name "jenkins-ci"

            # Replace image tag in deployment.yaml
            sed -i 's#${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:.*#${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:${IMAGE_TAG}#' apps/platform-ui/k8s/homepage/deployment.yaml

            git add apps/platform-ui/k8s/homepage/deployment.yaml
            git commit -m "ci: bump ${IMAGE_NAME} image to ${IMAGE_TAG}" || echo "⚠️ Nothing to commit"

              git remote set-url origin https://akashpulsor:${GHTOKEN}@github.com/akashpulsor/dalai-llama.git
              git push origin ${BRANCH}

          """
        }
      }
    }

    // =====================================================
    stage('Trigger ArgoCD Sync') {
      steps {
        withCredentials([string(credentialsId: 'argocd-token', variable: 'ARGOCD_TOKEN')]) {
          sh """
            echo "🔁 Triggering ArgoCD sync..."
            curl -X POST -H "Authorization: Bearer $ARGOCD_TOKEN" \
                 -H "Content-Type: application/json" \
                 -d '{"name": "platform-ui-dev"}' \
                 ${ARGOCD_SERVER}/api/v1/applications/platform-ui-dev/sync || true
          """
        }
      }
    }
  }

  // =====================================================
  post {
    success {
      echo "✅ Platform UI built and deployed successfully!"
    }
    failure {
      echo "❌ Jenkins pipeline failed. Check logs above."
    }
  }
}
