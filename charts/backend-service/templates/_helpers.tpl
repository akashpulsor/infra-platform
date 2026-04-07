{{/* Common Labels */}}
{{- define "dalai-backend.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: dalai-llama-backend
{{- end -}}

{{/* Database Environment Variables */}}
{{- define "dalai-backend.db-envs" -}}
- name: DB_HOST
  value: "postgres.{{ .root.Values.global.infraNamespace }}.svc.cluster.local"
- name: DB_PORT
  value: "5432"
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .serviceConfig.name }}-db-secret
      key: password
- name: SPRING_DATASOURCE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .serviceConfig.name }}-db-secret
      key: password
{{- end -}}

{{/* Redis Environment Variables */}}
{{- define "dalai-backend.redis-envs" -}}
- name: REDIS_HOST
  value: "redis.{{ .Values.global.infraNamespace }}.svc.cluster.local"
- name: SPRING_DATA_REDIS_HOST
  value: "redis.{{ .Values.global.infraNamespace }}.svc.cluster.local"
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
      name: {{ .Values.infra_secrets.redis.name }}
      key: {{ .Values.infra_secrets.redis.passwordKey }}
{{- end -}}

{{/* JWT Auth Environment Variables (Standard for all) */}}
{{- define "dalai-backend.auth-envs" -}}
# Spring Services
- name: KEYCLOAK_ISSUER_URI
  value: {{ .Values.keycloak.issuerUrl | quote }}
- name: SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI
  value: {{ .Values.keycloak.issuerUrl | quote }}
- name: SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWK_SET_URI
  value: {{ .Values.keycloak.jwksUri | quote }}
# AI Service (Python) - extra vars are harmless for Spring services
- name: KEYCLOAK_SERVER_URL
  value: {{ .Values.keycloak.adminUrl | quote }}
- name: KEYCLOAK_JWKS_URL
  value: {{ .Values.keycloak.jwksUri | quote }}
- name: KEYCLOAK_ISSUER
  value: {{ .Values.keycloak.issuerUrl | quote }}
- name: KEYCLOAK_REALM
  value: "dalai-llama"  
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
      name: {{ .Values.keycloak.adminSecretName }}
      key: {{ .Values.keycloak.adminPasswordKey }}
{{- end -}}

{{/* Keycloak Client Secret (For Backend Services to Authenticate) */}}
{{- define "dalai-backend.keycloak-client-envs" -}}
- name: KEYCLOAK_CLIENT_ID
  value: "platform-api"
- name: KEYCLOAK_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.keycloak.clientSecretName }}
      key: {{ .Values.keycloak.clientSecretKey }}
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

{{/* PBX-Core Telecom Infrastructure Integrations */}}
{{- define "dalai-backend.pbx-core-integrations" -}}
- name: TELECOM_PUBLIC_IP
  value: {{ .Values.services.pbxCoreService.telecom.publicIp | quote }}
- name: SIP_DOMAIN
  value: {{ .Values.services.pbxCoreService.telecom.sipDomain | quote }}
- name: TURN_DOMAIN
  value: {{ .Values.services.pbxCoreService.telecom.turnDomain | quote }}
- name: FREESWITCH_ESL_HOST
  value: {{ .Values.services.pbxCoreService.telecom.freeswitchEslHost | quote }}
- name: FREESWITCH_ESL_PORT
  value: {{ .Values.services.pbxCoreService.telecom.freeswitchEslPort | quote }}
- name: FREESWITCH_ESL_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.pbxCore.name }}
      key: {{ .Values.secrets.pbxCore.freeswitchEslPasswordKey }}
- name: COTURN_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.pbxCore.name }}
      key: {{ .Values.secrets.pbxCore.coturnSecretKey }}
{{- end -}}

{{/* AI Service Specific Integrations */}}
{{- define "dalai-backend.ai-service-integrations" -}}

- name: LOG_LEVEL
  value: {{ .Values.services.aiService.ai.logLevel | quote }}
- name: DEBUG
  value: {{ .Values.services.aiService.ai.debug | quote }}
- name: SERVICE_NAME
  value: {{ .Values.services.aiService.ai.serviceName | quote }}


- name: AUTH_ENABLED
  value: {{ .Values.services.aiService.ai.authEnabled | quote }}
- name: AUTH_ALLOW_UNSAFE_DEV_TOKENS
  value: {{ .Values.services.aiService.ai.authAllowUnsafeDevTokens | quote }}

- name: DEFAULT_STT_PROVIDER
  value: {{ .Values.services.aiService.ai.defaultSttProvider | quote }}
- name: DEFAULT_TTS_PROVIDER
  value: {{ .Values.services.aiService.ai.defaultTtsProvider | quote }}
- name: DEFAULT_LLM_PROVIDER
  value: {{ .Values.services.aiService.ai.defaultLlmProvider | quote }}
- name: OPENAI_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.openaiApiKeyKey }}
      optional: true
- name: DEEPGRAM_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.deepgramApiKeyKey }}
      optional: true
- name: GOOGLE_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.googleApiKeyKey }}
      optional: true
- name: GOOGLE_PROJECT_ID
  value: {{ .Values.services.aiService.ai.googleProjectId | quote }}
- name: GOOGLE_LOCATION
  value: {{ .Values.services.aiService.ai.googleLocation | quote }}
- name: GOOGLE_CREDENTIALS_PATH
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.googleCredentialsJsonPathKey }}
      optional: true
- name: GOOGLE_CREDENTIALS_JSON
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.googleCredentialsJsonKey }}
      optional: true
- name: OPENAI_STT_MODEL
  value: {{ .Values.services.aiService.ai.openai.sttModel | quote }}
- name: OPENAI_TTS_MODEL
  value: {{ .Values.services.aiService.ai.openai.ttsModel | quote }}
- name: OPENAI_TTS_VOICE
  value: {{ .Values.services.aiService.ai.openai.ttsVoice | quote }}
- name: OPENAI_LLM_MODEL
  value: {{ .Values.services.aiService.ai.openai.llmModel | quote }}
- name: OLLAMA_BASE_URL
  value: {{ .Values.services.aiService.ai.ollamaBaseUrl | quote }}
- name: OLLAMA_LLM_MODEL
  value: {{ .Values.services.aiService.ai.ollamaLlmModel | quote }}
- name: GOOGLE_LLM_MODEL
  value: {{ .Values.services.aiService.ai.google.llmModel | quote }}
- name: GOOGLE_GEMINI_LIVE_LLM_MODEL
  value: {{ .Values.services.aiService.ai.google.geminiLiveLlmModel | quote }}
- name: GOOGLE_GEMINI_LIVE_VOICE
  value: {{ .Values.services.aiService.ai.google.geminiLiveVoice | quote }}
- name: VERTEX_LLM_MODEL
  value: {{ .Values.services.aiService.ai.google.vertexLlmModel | quote }}
- name: GOOGLE_TTS_VOICE
  value: {{ .Values.services.aiService.ai.google.ttsVoice | quote }}
- name: GOOGLE_TTS_VOICE_MALE
  value: {{ .Values.services.aiService.ai.google.ttsVoiceMale | quote }}
- name: GOOGLE_TTS_VOICE_FEMALE
  value: {{ .Values.services.aiService.ai.google.ttsVoiceFemale | quote }}
- name: GOOGLE_TTS_MODE
  value: {{ .Values.services.aiService.ai.google.ttsMode | quote }}
- name: GOOGLE_GEMINI_TTS_MODEL
  value: {{ .Values.services.aiService.ai.google.geminiTtsModel | quote }}
- name: DEEPGRAM_STT_MODEL
  value: {{ .Values.services.aiService.ai.deepgram.sttModel | quote }}
- name: DEEPGRAM_TTS_MODEL
  value: {{ .Values.services.aiService.ai.deepgram.ttsModel | quote }}
- name: KOKORO_BASE_URL
  value: {{ .Values.services.aiService.ai.kokoroBaseUrl | quote }}
- name: KOKORO_TIMEOUT_SECONDS
  value: {{ .Values.services.aiService.ai.kokoro.timeoutSeconds | quote }}
- name: KOKORO_SAMPLE_RATE
  value: {{ .Values.services.aiService.ai.kokoro.sampleRate | quote }}
- name: KOKORO_VOICE_MALE
  value: {{ .Values.services.aiService.ai.kokoro.voiceMale | quote }}
- name: KOKORO_VOICE_FEMALE
  value: {{ .Values.services.aiService.ai.kokoro.voiceFemale | quote }}
- name: KOKORO_SPEED
  value: {{ .Values.services.aiService.ai.kokoro.speed | quote }}
- name: INDIC_TTS_BASE_URL
  value: {{ .Values.services.aiService.ai.indicTtsBaseUrl | quote }}
- name: INDIC_TTS_SAMPLE_RATE
  value: {{ .Values.services.aiService.ai.indicTts.sampleRate | quote }}
- name: INDIC_TTS_VOICE
  value: {{ .Values.services.aiService.ai.indicTts.voice | quote }}
- name: INDIC_TTS_VOICE_MALE
  value: {{ .Values.services.aiService.ai.indicTts.voiceMale | quote }}
- name: INDIC_TTS_VOICE_FEMALE
  value: {{ .Values.services.aiService.ai.indicTts.voiceFemale | quote }}
- name: INDIC_TTS_EMOTION
  value: {{ .Values.services.aiService.ai.indicTts.emotion | quote }}
- name: RVC_ENABLED
  value: {{ .Values.services.aiService.ai.rvc.enabled | quote }}
- name: RVC_SERVER_URL
  value: {{ .Values.services.aiService.ai.rvc.serverUrl | quote }}
- name: RVC_TIMEOUT_MS
  value: {{ .Values.services.aiService.ai.rvc.timeoutMs | quote }}
- name: SAMPLE_RATE
  value: {{ .Values.services.aiService.ai.audio.sampleRate | quote }}
- name: AUDIO_NORMALIZE
  value: {{ .Values.services.aiService.ai.audio.normalize | quote }}
- name: AUDIO_TARGET_LUFS
  value: {{ .Values.services.aiService.ai.audio.targetLufs | quote }}
- name: AUDIO_HIGHPASS_HZ
  value: {{ .Values.services.aiService.ai.audio.highpassHz | quote }}
- name: AUDIO_LIMITER_THRESHOLD
  value: {{ .Values.services.aiService.ai.audio.limiterThreshold | quote }}
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
{{- end -}}

{{/* Kafka Environment Variables */}}
{{- define "dalai-backend.kafka-envs" -}}
- name: KAFKA_BOOTSTRAP_SERVERS
  value: "kafka.{{ .Values.global.infraNamespace }}.svc.cluster.local:9092"
- name: SPRING_KAFKA_BOOTSTRAP_SERVERS
  value: "kafka.{{ .Values.global.infraNamespace }}.svc.cluster.local:9092"
- name: KAFKA_CONSUMER_GROUP_ID
  value: "dalai-llama-backend"
{{- end -}}

{{/* Internal Service URLs */}}
{{- define "dalai-backend.service-urls" -}}
- name: TENANT_SERVICE_URL
  value: "http://{{ .Values.services.tenantService.name }}.{{ .Values.services.tenantService.namespace }}.svc.cluster.local:8080"
- name: PRODUCT_SERVICE_URL
  value: "http://{{ .Values.services.productService.name }}.{{ .Values.services.productService.namespace }}.svc.cluster.local:8080"
- name: BILLING_SERVICE_URL
  value: "http://{{ .Values.services.billingService.name }}.{{ .Values.services.billingService.namespace }}.svc.cluster.local:8080"
- name: PBX_CORE_URL
  value: "http://{{ .Values.services.pbxCoreService.name }}.{{ .Values.services.pbxCoreService.namespace }}.svc.cluster.local:8080"
- name: AI_SERVICE_URL
  value: "http://{{ .Values.services.aiService.name }}.{{ .Values.services.aiService.namespace }}.svc.cluster.local:{{ .Values.services.aiService.service.port }}"
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


{{/* MinIO Environment Variables */}}
{{- define "dalai-backend.minio-envs" -}}
- name: MINIO_ENDPOINT
  value: "http://minio.{{ .Values.global.infraNamespace }}.svc.cluster.local:9000"
- name: MINIO_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.infra_secrets.minio.name }}
      key: {{ .Values.infra_secrets.minio.rootUserKey }}
- name: MINIO_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.infra_secrets.minio.name }}
      key: {{ .Values.infra_secrets.minio.rootPasswordKey }}
- name: MINIO_BUCKET_RECORDINGS
  value: {{ .Values.minio.buckets.recordings | default "call-recordings" | quote }}
- name: MINIO_BUCKET_VOICEMAIL
  value: {{ .Values.minio.buckets.voicemail | default "voicemail" | quote }}
- name: MINIO_BUCKET_EXPORTS
  value: {{ .Values.minio.buckets.exports | default "campaign-exports" | quote }}
- name: MINIO_BUCKET_KNOWLEDGE
  value: {{ .Values.minio.buckets.knowledge | default "bot-knowledge" | quote }}
- name: MINIO_BUCKET_CDR
  value: {{ .Values.minio.buckets.cdr | default "cdr-archives" | quote }}
{{- end -}}
