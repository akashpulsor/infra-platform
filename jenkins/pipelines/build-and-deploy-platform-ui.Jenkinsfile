pipeline {
  agent any

  environment {
    REGISTRY = "docker.io"
    DOCKER_USER = "akashtripathi"
    IMAGE_NAME = "platform-ui"
    BRANCH = "v4"
    APP_REPO = "https://github.com/akashpulsor/dalai-llama.git"
    ARGOCD_SERVER = "http://localhost:8081"
  }

  stages {
    stage('Checkout app repo') {
      steps {
        git branch: "${BRANCH}", url: "${APP_REPO}"
      }
    }

    stage('Compute image tag') {
      steps {
        script {
          env.SHORT_SHA = sh(returnStdout: true, script: 'git rev-parse --short=7 HEAD').trim()
          env.IMAGE_TAG = "${SHORT_SHA}"
          echo "🧩 Using image tag: ${env.IMAGE_TAG}"
        }
      }
    }

    stage('Build & Push Docker image') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'dockerhub-credentials', usernameVariable: 'USER', passwordVariable: 'TOKEN')]) {
          sh """
            echo "🔧 Building Docker image..."
            docker build -t ${IMAGE_NAME}:${IMAGE_TAG} ./apps/platform-ui
            echo \$TOKEN | docker login -u \$USER --password-stdin
            docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:${IMAGE_TAG}
            docker push ${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:${IMAGE_TAG}
          """
        }
      }
    }

    stage('Update image tag in deployment.yaml') {
      steps {
        withCredentials([string(credentialsId: 'github-pat', variable: 'GHTOKEN')]) {
          sh """
            git config user.email "ci@${DOCKER_USER}.local"
            git config user.name "jenkins-ci"

            # ✅ Replace the image line properly
            sed -i "s|image: docker.io/${DOCKER_USER}/${IMAGE_NAME}:.*|image: docker.io/${DOCKER_USER}/${IMAGE_NAME}:${IMAGE_TAG}|" apps/platform-ui/k8s/homepage/deployment.yaml

            git add apps/platform-ui/k8s/homepage/deployment.yaml
            git commit -m "ci: bump ${IMAGE_NAME} to ${IMAGE_TAG}" || echo "No changes to commit"
            git remote set-url origin https://${GHTOKEN}:x-oauth-basic@github.com/akashpulsor/dalai-llama.git
            git push origin ${BRANCH}
          """
        }
      }
    }

    stage('Trigger ArgoCD Sync') {
      steps {
        withCredentials([string(credentialsId: 'argocd-token', variable: 'ARGOCD_TOKEN')]) {
          script {
            echo "🚀 Triggering ArgoCD sync for platform-ui-dev"
            sh """
              curl -X POST -H "Authorization: Bearer $ARGOCD_TOKEN" \
                   -H "Content-Type: application/json" \
                   ${ARGOCD_SERVER}/api/v1/applications/platform-ui-dev/sync || true
            """

            echo "🌐 Triggering ArgoCD sync for platform-ui-gateway (optional)"
            sh """
              curl -X POST -H "Authorization: Bearer $ARGOCD_TOKEN" \
                   -H "Content-Type: application/json" \
                   ${ARGOCD_SERVER}/api/v1/applications/platform-ui-gateway/sync || true
            """
          }
        }
      }
    }
  }

  post {
    success {
      echo "✅ Deployed ${IMAGE_NAME}:${IMAGE_TAG} successfully via Argo CD!"
    }
    failure {
      echo "❌ Build/deploy failed!"
    }
  }
}
