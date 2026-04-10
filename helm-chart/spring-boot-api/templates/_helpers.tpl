{{/*
  Returns the chart base name. Defined once and reused so renaming the chart
  only requires changing it here.
*/}}
{{- define "spring-boot-api.name" -}}spring-boot-api{{- end }}

{{/*
  Produces the fully-qualified resource name: "<release>-<chart>".
  trunc 63: Kubernetes DNS label limit is 63 characters. Names exceeding this
            cause API server validation errors that are confusing to debug.
  trimSuffix "-": trunc can leave a trailing hyphen if the name is exactly 63
                  chars, which is invalid in Kubernetes names.
*/}}
{{- define "spring-boot-api.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "spring-boot-api.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
  Labels applied to every resource (Deployment, Service, etc.).
  Kept separate from selectorLabels because these can change between deploys
  (e.g. chart version bumps) without causing issues.

  replace "+" "_": SemVer build metadata uses "+", which is not valid in
                   Kubernetes label values. Replace to avoid validation errors.
*/}}
{{- define "spring-boot-api.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "spring-boot-api.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
  Selector labels used by Service.selector and Deployment.spec.selector.
  CRITICAL: these must NEVER change after the Deployment is created.
  Kubernetes selector fields are immutable - changing them requires deleting
  and recreating the Deployment, causing downtime. This is why selectorLabels
  are separated from the broader labels set: chart version, managed-by, etc.
  must not bleed into selectors.
*/}}
{{- define "spring-boot-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "spring-boot-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
