pipeline {
  agent {
    kubernetes {
      label 'docker-agent'
      yamlFile 'jenkins/agents/docker-agent.yaml'
    }
  }

  environment {
    REGISTRY = "docker.io"
    DOCKER_USER = "akashtripathi"
    IMAGE_NAME = "platform-ui"
    BRANCH = "v4"
    APP_REPO = "https://github.com/akashpulsor/dalai-llama.git"
    ARGOCD_SERVER = "http://localhost:8081"
  }

  stages {
    stage('Checkout Repo') {
      steps {
        git branch: "${BRANCH}", url: "${APP_REPO}"
      }
    }

    stage('Build & Push Docker Image') {
      steps {
        container('docker') {
          withCredentials([usernamePassword(credentialsId: 'dockerhub-credentials', usernameVariable: 'USER', passwordVariable: 'TOKEN')]) {
            sh '''
              docker version
              docker build -t ${IMAGE_NAME}:${BUILD_NUMBER} -f apps/platform-ui/Dockerfile apps/platform-ui
              echo $TOKEN | docker login -u $USER --password-stdin
              docker tag ${IMAGE_NAME}:${BUILD_NUMBER} ${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:${BUILD_NUMBER}
              docker push ${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:${BUILD_NUMBER}
            '''
          }
        }
      }
    }

    stage('Update Deployment Manifest') {
      steps {
        container('docker') {
          withCredentials([string(credentialsId: 'github-pat', variable: 'GHTOKEN')]) {
            sh '''
              git config user.email "ci@${DOCKER_USER}.local"
              git config user.name "jenkins-ci"
              sed -i "s#${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:.*#${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:${BUILD_NUMBER}#" apps/platform-ui/k8s/homepage/deployment.yaml
              git add apps/platform-ui/k8s/homepage/deployment.yaml
              git commit -m "ci: bump ${IMAGE_NAME} image to ${BUILD_NUMBER}" || true
              git remote set-url origin https://${GHTOKEN}:x-oauth-basic@github.com/akashpulsor/dalai-llama.git
              git push origin ${BRANCH} || true
            '''
          }
        }
      }
    }

    stage('Trigger ArgoCD Sync') {
      steps {
        container('docker') {
          withCredentials([string(credentialsId: 'argocd-token', variable: 'ARGOCD_TOKEN')]) {
            sh '''
              curl -X POST -H "Authorization: Bearer $ARGOCD_TOKEN" \
                   -H "Content-Type: application/json" \
                   -d '{"name": "platform-ui-dev"}' \
                   ${ARGOCD_SERVER}/api/v1/applications/platform-ui-dev/sync || true
            '''
          }
        }
      }
    }
  }

  post {
    success {
      echo "✅ Platform UI deployed successfully!"
    }
    failure {
      echo "❌ Jenkins pipeline failed."
    }
  }
}
