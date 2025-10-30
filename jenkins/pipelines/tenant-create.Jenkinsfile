pipeline {
  agent any
  parameters {
    string(name: "TENANT_ID", defaultValue: "acme", description: "Tenant name/id")
  }
  environment {
    KUBECONFIG = credentials("k3d-kubeconfig")
  }
  stages {
    stage("Create Tenant Namespace") {
      steps {
        sh "kubectl create ns tenant-${TENANT_ID} || true"
      }
    }
    stage("Deploy Tenant PBX") {
      steps {
        sh """
        kubectl apply -n tenant-${TENANT_ID} -f infra/environments/dev/manifests/shared-tenant/pbx-deployment.yaml
        kubectl apply -n tenant-${TENANT_ID} -f infra/environments/dev/manifests/shared-tenant/pbx-service.yaml
        """
      }
    }
  }
}
