{{/* Common Labels */}}
{{- define "dalai-backend.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: dalai-llama-backend
{{- end -}}

{{/* Database Environment Variables */}}
{{- define "dalai-backend.db-envs" -}}
- name: DB_HOST
  value: "postgres.{{ .Values.global.namespace }}.svc.cluster.local"
- name: DB_PORT
  value: "5432"
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.infra_secrets.postgres.name }}
      key: {{ .Values.infra_secrets.postgres.passwordKey }}
{{- end -}}

{{/* Redis Environment Variables */}}
{{- define "dalai-backend.redis-envs" -}}
- name: REDIS_HOST
  value: "redis.{{ .Values.global.namespace }}.svc.cluster.local"
- name: SPRING_DATA_REDIS_HOST
  value: "redis.{{ .Values.global.namespace }}.svc.cluster.local"
- name: REDIS_PORT
  value: "6379"
- name: SPRING_DATA_REDIS_PORT
  value: "6379"
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.infra_secrets.redis.name }}
      key: {{ .Values.infra_secrets.redis.passwordKey }}
- name: SPRING_DATA_REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.redis.name }}
      key: {{ .Values.secrets.redis.passwordKey }}
{{- end -}}

{{/* JWT Auth Environment Variables (Standard for all) */}}
{{- define "dalai-backend.auth-envs" -}}
- name: KEYCLOAK_ISSUER_URI
  value: {{ .Values.keycloak.issuerUrl | quote }}
- name: SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI
  value: {{ .Values.keycloak.issuerUrl | quote }}
- name: SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWK_SET_URI
  value: {{ .Values.keycloak.jwksUri | quote }}
{{- end -}}


{{/* Keycloak Admin (For managing Keycloak via API) */}}
{{- define "dalai-backend.keycloak-admin-envs" -}}
- name: KEYCLOAK_ADMIN_URL
  value: {{ .Values.keycloak.adminUrl | quote }}

- name: KEYCLOAK_ADMIN_REALM
  value: {{ .Values.keycloak.adminRealm | quote }}

- name: KEYCLOAK_ADMIN_USERNAME
  value: {{ .Values.keycloak.adminUsername | quote }}
- name: KEYCLOAK_ADMIN_PASSWORD
  valueFrom:
    secretKeyRef:
      name: keycloak-admin-secret  # Matches the Secret metadata.name in your Keycloak chart
      key: password                # Matches the key in stringData
{{- end -}}

{{/* Keycloak Client Secret (For Backend Services to Authenticate) */}}
{{- define "dalai-backend.keycloak-client-envs" -}}
- name: KEYCLOAK_CLIENT_ID
  value: "platform-api"
- name: KEYCLOAK_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: keycloak-client-secret # Matches the Secret metadata.name in your Keycloak chart
      key: client-secret           # Matches the key in stringData
{{- end -}}

{{/* Product Service Specific Integrations (SIP & DIDWW) */}}
{{- define "dalai-backend.product-integrations" -}}
- name: SIP_DOMAIN
  value: {{ .Values.services.productService.sip.domain | quote }}
- name: SIP_REALM
  value: {{ .Values.services.productService.sip.realm | quote }}
- name: DIDWW_API_URL
  value: {{ .Values.services.productService.didww.apiUrl | quote }}
- name: DIDWW_SYNC_ENABLED
  value: {{ .Values.services.productService.didww.syncEnabled | quote }}
- name: DIDWW_SYNC_INTERVAL
  value: {{ .Values.services.productService.didww.syncIntervalMinutes | quote }}
- name: DIDWW_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.didww.name }}
      key: {{ .Values.secrets.didww.apiKeyKey }}
- name: DIDWW_WEBHOOK_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.didww.name }}
      key: {{ .Values.secrets.didww.webhookSecretKey }}
- name: SERVER_SERVLET_CONTEXT_PATH
  value: "/"
{{- end -}}

{{/* K8s Provisioning Logic (Specifically for Tenant Service) */}}

{{- define "dalai-backend.provisioning-envs" -}}
- name: KUBERNETES_NAMESPACE
  value: {{ .Values.services.tenantService.kubernetes.namespace | default "dalai-llama" | quote }}
- name: KUBERNETES_TRUST_CERTS
  value: {{ .Values.services.tenantService.kubernetes.trustCerts | default "true" | quote }}
- name: PROVISIONING_MAX_RETRIES
  value: {{ .Values.services.tenantService.provisioning.maxRetries | quote }}
- name: PROVISIONING_RETRY_DELAY_SECONDS
  value: {{ .Values.services.tenantService.provisioning.retryDelaySeconds | quote }}
- name: PROVISIONING_IP_WAIT_TIMEOUT_MINUTES
  value: {{ .Values.services.tenantService.provisioning.ipWaitTimeoutMinutes | quote }}
- name: PROVISIONING_IP_POLL_INTERVAL_SECONDS
  value: {{ .Values.services.tenantService.provisioning.ipPollIntervalSeconds | quote }}
- name: PROVISIONING_MIN_WALLET_BALANCE
  value: {{ .Values.services.tenantService.provisioning.minWalletBalance | quote }}
- name: KUBERNETES_NAMESPACE
  value: {{ .Values.services.tenantService.kubernetes.namespace | default "dalai-llama" | quote }}
- name: KUBERNETES_TRUST_CERTS
  value: {{ .Values.services.tenantService.kubernetes.trustCerts | default "true" | quote }}
- name: PROVISIONING_MAX_RETRIES
  value: {{ .Values.services.tenantService.provisioning.maxRetries | quote }}
- name: PROVISIONING_RETRY_DELAY_SECONDS
  value: {{ .Values.services.tenantService.provisioning.retryDelaySeconds | quote }}
- name: PROVISIONING_IP_WAIT_TIMEOUT_MINUTES
  value: {{ .Values.services.tenantService.provisioning.ipWaitTimeoutMinutes | quote }}  
{{- end -}}

{{/* Kafka Environment Variables */}}
{{- define "dalai-backend.kafka-envs" -}}
- name: KAFKA_BOOTSTRAP_SERVERS
  value: "kafka.{{ .Values.global.namespace }}.svc.cluster.local:9092"
- name: SPRING_KAFKA_BOOTSTRAP_SERVERS
  value: "kafka.{{ .Values.global.namespace }}.svc.cluster.local:9092"
- name: KAFKA_CONSUMER_GROUP_ID
  value: "dalai-llama-backend"
{{- end -}}

{{/* Billing Service Specific Integrations (Razorpay & Thresholds) */}}
{{- define "dalai-backend.billing-integrations" -}}
# Billing Configuration
- name: GRACE_PERIOD_DAYS
  value: {{ .Values.services.billingService.billing.gracePeriodDays | quote }}
- name: LOW_BALANCE_THRESHOLD
  value: {{ .Values.services.billingService.billing.lowBalanceThreshold | quote }}
- name: DEFAULT_CURRENCY
  value: {{ .Values.services.billingService.billing.defaultCurrency | quote }}

# Razorpay Configuration
{{- if .Values.services.billingService.razorpay.enabled }}
- name: RAZORPAY_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.razorpay.name }}
      key: {{ .Values.secrets.razorpay.keyIdKey }}
- name: RAZORPAY_KEY_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.razorpay.name }}
      key: {{ .Values.secrets.razorpay.keySecretKey }}
- name: RAZORPAY_WEBHOOK_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.razorpay.name }}
      key: {{ .Values.secrets.razorpay.webhookSecretKey }}
{{- end }}
{{- end -}}