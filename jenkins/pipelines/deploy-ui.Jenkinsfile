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
    stage('Checkout') {
      steps {
        git branch: "${BRANCH}", url: "${APP_REPO}"
      }
    }
    stage('Build & Push Docker image') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'dockerhub-credentials', usernameVariable: 'USER', passwordVariable: 'TOKEN')]) {
          sh '''
            docker build -t ${IMAGE_NAME}:${BUILD_NUMBER} .
            echo $TOKEN | docker login -u $USER --password-stdin
            docker tag ${IMAGE_NAME}:${BUILD_NUMBER} ${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:${BUILD_NUMBER}
            docker push ${REGISTRY}/${DOCKER_USER}/${IMAGE_NAME}:${BUILD_NUMBER}
          '''
        }
      }
    }
  }
}
