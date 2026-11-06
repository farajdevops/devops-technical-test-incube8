{{/* Chart name, truncated to Kubernetes' 63-char limit. */}}
{{- define "auth-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified resource name: <release>-<chart>, or just the release if it already contains the chart name. */}}
{{- define "auth-api.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "auth-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Labels used in matchLabels/selectors. Immutable after first install - do not add to this. */}}
{{- define "auth-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "auth-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Common labels on every object. */}}
{{- define "auth-api.labels" -}}
helm.sh/chart: {{ include "auth-api.chart" . }}
{{ include "auth-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "auth-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "auth-api.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Name of the Secret holding DATABASE_URL / REDIS_URL. */}}
{{- define "auth-api.secretName" -}}
{{- if .Values.secret.create }}
{{- printf "%s-secrets" (include "auth-api.fullname" .) }}
{{- else }}
{{- required "secret.existingSecret must be set when secret.create=false" .Values.secret.existingSecret }}
{{- end }}
{{- end }}

{{- define "auth-api.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) }}
{{- end }}
