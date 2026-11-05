{{/* Labels shared by every resource in the release. */}}
{{- define "skywatch.labels" -}}
app.kubernetes.io/part-of: skywatch
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Selector labels for one component. Usage:
  include "skywatch.selectorLabels" (dict "root" $ "component" "backend")
*/}}
{{- define "skywatch.selectorLabels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}
