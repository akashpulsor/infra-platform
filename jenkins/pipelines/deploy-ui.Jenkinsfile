pipeline {
  agent any
  environment {
    APP_NAME = "platform-ui"
    ENV = "dev"
    REGISTRY = "docker.io"
    DOCKER_USER = "akashtripathi"
    IMAGE_TAG = "latest"
    ARGOCD_SERVER = "http://localhost:8081"
  }
  stages {
    stage('Build & Push Docker Image') {
      steps {
        dir('apps/platform-ui') {
          withCredentials([usernamePassword(credentialsId: 'dockerhub-credentials', usernameVariable: 'USER', passwordVariable: 'TOKEN')]) {
            sh '''
              echo "Building Docker image..."
              docker build -t ${REGISTRY}/${DOCKER_USER}/${APP_NAME}:${IMAGE_TAG} .
              echo $TOKEN | docker login -u $USER --password-stdin
              docker push ${REGISTRY}/${DOCKER_USER}/${APP_NAME}:${IMAGE_TAG}
            '''
          }
        }
      }
    }
    stage('Trigger ArgoCD Syncs') {
      steps {
        withCredentials([string(credentialsId: 'argocd-token', variable: 'ARGOCD_TOKEN')]) {
          sh '''
            curl -X POST -H "Authorization: Bearer $ARGOCD_TOKEN" -H "Content-Type: application/json" \
              ${ARGOCD_SERVER}/api/v1/applications/platform-ui-gateway/sync || true
            curl -X POST -H "Authorization: Bearer $ARGOCD_TOKEN" -H "Content-Type: application/json" \
              ${ARGOCD_SERVER}/api/v1/applications/platform-ui-dev/sync || true
          '''
        }
      }
    }
  }
  post {
    success { echo "✅ Deployed ${APP_NAME}-${ENV} via Argo CD" }
    failure { echo "❌ Deployment failed" }
  }
}
