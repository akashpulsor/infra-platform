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

{{/* Creator Service AI Provider Integrations */}}
{{- define "dalai-backend.creator-ai-integrations" -}}
- name: OPENAI_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.openaiApiKeyKey }}
      optional: true
- name: GEMINI_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.geminiApiKeyKey }}
      optional: true
- name: GOOGLE_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.googleApiKeyKey }}
      optional: true
- name: LUMA_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.lumaApiKeyKey }}
      optional: true
- name: RUNWAY_API_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.runwayApiSecretKey }}
      optional: true
- name: SEEDANCE_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.falSecretName | default .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.falApiKeyKey }}
      optional: true
- name: FAL_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.falSecretName | default .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.falApiKeyKey }}
      optional: true
- name: OMINI_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.ominiApiKeyKey }}
      optional: true
- name: GOOGLE_VEO_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.googleVeoApiKeyKey }}
      optional: true
- name: DECART_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.decartApiKeyKey }}
      optional: true
- name: GOOGLE_CREDENTIALS_JSON
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.googleCredentialsJsonKey }}
      optional: true
- name: REDDIT_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.reddit.name }}
      key: {{ .Values.secrets.reddit.clientIdKey }}
      optional: true
- name: REDDIT_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.reddit.name }}
      key: {{ .Values.secrets.reddit.clientSecretKey }}
      optional: true
{{- end -}}

{{/* LLM Gateway -- reuses the already-provisioned Google API key from ai-service-secrets, no new secret needed */}}
{{- define "dalai-backend.llm-gateway-integrations" -}}
- name: GOOGLE_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.googleApiKeyKey }}
- name: FAL_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.falApiKeyKey }}
- name: ELEVENLABS_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.elevenLabsApiKeyKey }}
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
- name: GEMINI_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.geminiApiKeyKey }}
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
- name: AVATAR_GENERATION_ENABLED
  value: {{ .Values.services.aiService.ai.avatar.generationEnabled | quote }}
- name: AVATAR_LOCAL_RUNTIME_ENABLED
  value: {{ .Values.services.aiService.ai.avatar.localRuntimeEnabled | quote }}
- name: AVATAR_GENERATION_RUNNER_URL
  value: {{ .Values.services.aiService.ai.avatar.generationRunnerUrl | quote }}
- name: AVATAR_GENERATION_RUNNER_PATH
  value: {{ .Values.services.aiService.ai.avatar.generationRunnerPath | quote }}
- name: AVATAR_VOICE_RUNNER_PATH
  value: {{ .Values.services.aiService.ai.avatar.voiceRunnerPath | quote }}
- name: AVATAR_LIPSYNC_RUNNER_PATH
  value: {{ .Values.services.aiService.ai.avatar.lipSyncRunnerPath | quote }}
- name: AVATAR_STT_RUNNER_PATH
  value: {{ .Values.services.aiService.ai.avatar.sttRunnerPath | quote }}
- name: AVATAR_IMAGE_RUNNER_PATH
  value: {{ .Values.services.aiService.ai.avatar.imageRunnerPath | quote }}
- name: AVATAR_POSTPROCESS_RUNNER_PATH
  value: {{ .Values.services.aiService.ai.avatar.postprocessRunnerPath | quote }}
- name: AVATAR_GENERATION_TIMEOUT_SECONDS
  value: {{ .Values.services.aiService.ai.avatar.generationTimeoutSeconds | quote }}
- name: AVATAR_GENERATION_GPU_PROFILE
  value: {{ .Values.services.aiService.ai.avatar.gpuProfile | quote }}
- name: AVATAR_VOICE_MODEL
  value: {{ .Values.services.aiService.ai.avatar.voiceModel | quote }}
- name: AVATAR_TALKING_MODEL
  value: {{ .Values.services.aiService.ai.avatar.talkingModel | quote }}
- name: AVATAR_IMAGE_MODEL
  value: {{ .Values.services.aiService.ai.avatar.imageModel | quote }}
- name: AVATAR_LIGHTING_MODEL
  value: {{ .Values.services.aiService.ai.avatar.lightingModel | quote }}
- name: AVATAR_VIDEO_MODEL
  value: {{ .Values.services.aiService.ai.avatar.videoModel | quote }}
- name: AVATAR_LIPSYNC_MODEL
  value: {{ .Values.services.aiService.ai.avatar.lipSyncModel | quote }}
- name: FAL_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.falSecretName | default .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.falApiKeyKey }}
      optional: true
- name: AVATAR_FAL_VOICE_ENDPOINT
  value: {{ .Values.services.aiService.ai.avatar.fal.voiceEndpoint | quote }}
- name: AVATAR_FAL_TTS_ENDPOINT
  value: {{ .Values.services.aiService.ai.avatar.fal.ttsEndpoint | quote }}
- name: AVATAR_FAL_ELEVENLABS_TTS_ENDPOINT
  value: {{ .Values.services.aiService.ai.avatar.fal.elevenLabsTtsEndpoint | quote }}
- name: AVATAR_FAL_CHATTERBOX_ENDPOINT
  value: {{ .Values.services.aiService.ai.avatar.fal.chatterboxEndpoint | quote }}
- name: AVATAR_FAL_ECHOMIMIC_ENDPOINT
  value: {{ .Values.services.aiService.ai.avatar.fal.echoMimicEndpoint | quote }}
- name: AVATAR_FAL_ECHOMIMIC_USD_PER_SECOND
  value: {{ .Values.services.aiService.ai.avatar.fal.echoMimicUsdPerSecond | quote }}
- name: AVATAR_FAL_HAPPY_HORSE_ENDPOINT
  value: {{ .Values.services.aiService.ai.avatar.fal.happyHorseEndpoint | quote }}
- name: AVATAR_FAL_HAPPY_HORSE_720P_USD_PER_SECOND
  value: {{ .Values.services.aiService.ai.avatar.fal.happyHorse720pUsdPerSecond | quote }}
- name: AVATAR_FAL_HAPPY_HORSE_1080P_USD_PER_SECOND
  value: {{ .Values.services.aiService.ai.avatar.fal.happyHorse1080pUsdPerSecond | quote }}
- name: AVATAR_FAL_HEYGEN_AVATAR4_ENDPOINT
  value: {{ .Values.services.aiService.ai.avatar.fal.heygenAvatar4Endpoint | quote }}
- name: AVATAR_FAL_HEYGEN_AVATAR4_USD_PER_SECOND
  value: {{ .Values.services.aiService.ai.avatar.fal.heygenAvatar4UsdPerSecond | quote }}
- name: AVATAR_FAL_LIVEPORTRAIT_ENDPOINT
  value: {{ .Values.services.aiService.ai.avatar.fal.livePortraitEndpoint | quote }}
- name: AVATAR_FAL_LIPSYNC_ENDPOINT
  value: {{ .Values.services.aiService.ai.avatar.fal.lipSyncEndpoint | quote }}
- name: AVATAR_FAL_MUSETALK_ENDPOINT
  value: {{ .Values.services.aiService.ai.avatar.fal.museTalkEndpoint | quote }}
- name: AVATAR_FAL_VIDEO_EDIT_ENDPOINT
  value: {{ .Values.services.aiService.ai.avatar.fal.videoEditEndpoint | quote }}
- name: AVATAR_FAL_VIDEO_EDIT_USD_PER_SECOND
  value: {{ .Values.services.aiService.ai.avatar.fal.videoEditUsdPerSecond | quote }}
- name: AVATAR_FAL_MEDIA_EXPIRATION_SECONDS
  value: {{ .Values.services.aiService.ai.avatar.fal.mediaExpirationSeconds | quote }}
- name: AVATAR_FAL_STORE_IO
  value: {{ .Values.services.aiService.ai.avatar.fal.storeIo | quote }}
- name: AVATAR_PROPRIETARY_API_TIMEOUT_SECONDS
  value: {{ .Values.services.aiService.ai.avatar.proprietaryApiTimeoutSeconds | quote }}
- name: AVATAR_MODEL_ROOT
  value: {{ .Values.services.aiService.ai.avatar.modelRoot | quote }}
- name: AVATAR_WORK_ROOT
  value: {{ .Values.services.aiService.ai.avatar.workRoot | quote }}
- name: AVATAR_DOWNLOAD_TIMEOUT_SECONDS
  value: {{ .Values.services.aiService.ai.avatar.downloadTimeoutSeconds | quote }}
- name: AVATAR_STAGE_TIMEOUT_SECONDS
  value: {{ .Values.services.aiService.ai.avatar.stageTimeoutSeconds | quote }}
- name: AVATAR_ALLOW_TEST_FALLBACK
  value: {{ .Values.services.aiService.ai.avatar.allowTestFallback | quote }}
- name: AVATAR_COSYVOICE_REPO
  value: {{ .Values.services.aiService.ai.avatar.cosyVoice.repo | quote }}
- name: AVATAR_COSYVOICE2_MODEL_DIR
  value: {{ .Values.services.aiService.ai.avatar.cosyVoice.modelDir | quote }}
- name: AVATAR_COSYVOICE2_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.cosyVoice.command | quote }}
- name: AVATAR_ELEVENLABS_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.elevenLabsApiKeyKey }}
      optional: true
- name: AVATAR_ELEVENLABS_BASE_URL
  value: {{ .Values.services.aiService.ai.avatar.elevenLabs.baseUrl | quote }}
- name: AVATAR_ELEVENLABS_VOICE_ID
  value: {{ .Values.services.aiService.ai.avatar.elevenLabs.voiceId | quote }}
- name: AVATAR_ELEVENLABS_MODEL_ID
  value: {{ .Values.services.aiService.ai.avatar.elevenLabs.modelId | quote }}
- name: AVATAR_ELEVENLABS_OUTPUT_FORMAT
  value: {{ .Values.services.aiService.ai.avatar.elevenLabs.outputFormat | quote }}
- name: AVATAR_ELEVENLABS_REMOVE_BACKGROUND_NOISE
  value: {{ .Values.services.aiService.ai.avatar.elevenLabs.removeBackgroundNoise | quote }}
- name: AVATAR_ELEVENLABS_VOICE_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.elevenLabs.voiceCommand | quote }}
- name: AVATAR_SARVAM_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.sarvamApiKeyKey }}
      optional: true
- name: AVATAR_SARVAM_BASE_URL
  value: {{ .Values.services.aiService.ai.avatar.sarvam.baseUrl | quote }}
- name: AVATAR_SARVAM_VOICE_CLONE_PATH
  value: {{ .Values.services.aiService.ai.avatar.sarvam.voiceClonePath | quote }}
- name: AVATAR_SARVAM_TTS_PATH
  value: {{ .Values.services.aiService.ai.avatar.sarvam.ttsPath | quote }}
- name: AVATAR_SARVAM_VOICE_ID
  value: {{ .Values.services.aiService.ai.avatar.sarvam.voiceId | quote }}
- name: AVATAR_SARVAM_MODEL_ID
  value: {{ .Values.services.aiService.ai.avatar.sarvam.modelId | quote }}
- name: AVATAR_SARVAM_OUTPUT_CODEC
  value: {{ .Values.services.aiService.ai.avatar.sarvam.outputCodec | quote }}
- name: AVATAR_SARVAM_SAMPLE_RATE
  value: {{ .Values.services.aiService.ai.avatar.sarvam.sampleRate | quote }}
- name: AVATAR_VOICE_FALLBACK_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.voiceFallbackCommand | quote }}
- name: AVATAR_LIVEPORTRAIT_REPO
  value: {{ .Values.services.aiService.ai.avatar.livePortrait.repo | quote }}
- name: AVATAR_LIVEPORTRAIT_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.livePortrait.command | quote }}
- name: AVATAR_ECHOMIMIC_REPO
  value: {{ .Values.services.aiService.ai.avatar.echoMimic.repo | quote }}
- name: AVATAR_ECHOMIMIC_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.echoMimic.command | quote }}
- name: AVATAR_MUSETALK_REPO
  value: {{ .Values.services.aiService.ai.avatar.museTalk.repo | quote }}
- name: AVATAR_MUSETALK_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.museTalk.command | quote }}
- name: AVATAR_LATENTSYNC_REPO
  value: {{ .Values.services.aiService.ai.avatar.latentSync.repo | quote }}
- name: AVATAR_LATENTSYNC_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.latentSync.command | quote }}
- name: AVATAR_SYNC_LABS_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.aiService.name }}
      key: {{ .Values.secrets.aiService.syncLabsApiKeyKey }}
      optional: true
- name: AVATAR_SYNC_LABS_BASE_URL
  value: {{ .Values.services.aiService.ai.avatar.syncLabs.baseUrl | quote }}
- name: AVATAR_SYNC_LABS_MODEL
  value: {{ .Values.services.aiService.ai.avatar.syncLabs.model | quote }}
- name: AVATAR_SYNC_LABS_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.syncLabs.command | quote }}
- name: AVATAR_LIPSYNC_FALLBACK_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.lipSyncFallbackCommand | quote }}
- name: AVATAR_FLUX_MODEL_ID
  value: {{ .Values.services.aiService.ai.avatar.flux.modelId | quote }}
- name: AVATAR_FLUX_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.flux.command | quote }}
- name: AVATAR_STT_MODEL
  value: {{ .Values.services.aiService.ai.avatar.stt.model | quote }}
- name: AVATAR_STT_DEVICE
  value: {{ .Values.services.aiService.ai.avatar.stt.device | quote }}
- name: AVATAR_STT_COMPUTE_TYPE
  value: {{ .Values.services.aiService.ai.avatar.stt.computeType | quote }}
- name: AVATAR_CAPTION_ENGINE
  value: {{ .Values.services.aiService.ai.avatar.captions.engine | quote }}
- name: AVATAR_WHISPERX_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.captions.whisperxCommand | quote }}
- name: AVATAR_BIREFNET_MODEL_ID
  value: {{ .Values.services.aiService.ai.avatar.backgroundRemoval.modelId | quote }}
- name: AVATAR_BIREFNET_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.backgroundRemoval.command | quote }}
- name: AVATAR_REALESRGAN_EXECUTABLE
  value: {{ .Values.services.aiService.ai.avatar.upscaling.executable | quote }}
- name: AVATAR_REALESRGAN_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.upscaling.command | quote }}
- name: AVATAR_REALESRGAN_MODEL
  value: {{ .Values.services.aiService.ai.avatar.upscaling.model | quote }}
- name: AVATAR_CODEFORMER_REPO
  value: {{ .Values.services.aiService.ai.avatar.faceRestoration.repo | quote }}
- name: AVATAR_CODEFORMER_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.faceRestoration.command | quote }}
- name: AVATAR_VIDEO_BACKGROUND_REMOVAL_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.videoPostprocess.backgroundRemovalCommand | quote }}
- name: AVATAR_VIDEO_UPSCALE_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.videoPostprocess.upscaleCommand | quote }}
- name: AVATAR_VIDEO_FACE_RESTORE_COMMAND
  value: {{ .Values.services.aiService.ai.avatar.videoPostprocess.faceRestoreCommand | quote }}
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
# RTP fork target for RTPEngine (outside cluster) → ai-service (inside cluster)
{{- if .Values.services.tenantService.aiService }}
{{- if .Values.services.tenantService.aiService.rtpExternalHost }}
- name: DALAILLAMA_AI_SERVICE_RTP_EXTERNAL_HOST
  value: {{ .Values.services.tenantService.aiService.rtpExternalHost | quote }}
{{- end }}
- name: DALAILLAMA_AI_SERVICE_RTP_EXTERNAL_PORT
  value: {{ .Values.services.tenantService.aiService.rtpExternalPort | default 5555 | quote }}
{{- end }}
{{- end -}}

{{/* Tenant Service Credential Delivery */}}
{{- define "dalai-backend.tenant-credential-envs" -}}
- name: DALAI_CRED_ENCRYPTION_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.tenantServiceCredentials.name }}
      key: {{ .Values.secrets.tenantServiceCredentials.encryptionKeyKey }}
- name: DALAI_CRED_TTL_HOURS
  value: {{ .Values.services.tenantService.credentials.ttlHours | default 72 | quote }}
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
- name: CREATOR_SERVICE_URL
  value: "http://{{ .Values.services.creatorService.name }}.{{ .Values.services.creatorService.namespace }}.svc.cluster.local:{{ .Values.services.creatorService.service.port }}"
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
- name: RAZORPAY_MOCK_ENABLED
  value: {{ .Values.services.billingService.razorpay.mockEnabled | default false | quote }}
      
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
- name: MINIO_BUCKET_CREATOR_ASSETS
  value: {{ .Values.minio.buckets.creatorAssets | default "creator-assets" | quote }}
- name: MINIO_BUCKET_CREATOR_EXPORTS
  value: {{ .Values.minio.buckets.creatorExports | default "creator-exports" | quote }}
{{- end -}}
