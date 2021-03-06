local k = import "github.com/grafana/jsonnet-libs/ksonnet-util/kausal.libsonnet";

local deployment = k.apps.v1.deployment;
local container = k.core.v1.container;
local port = k.core.v1.containerPort;
local networkV1 = k.networking.v1;
local networkV1B1 = k.networking.v1beta1;
local secret = k.core.v1.secret;
local envFromSource = k.core.v1.envFromSource;

local genFlags(xs) = [
  local v = xs[k];
  if v == null then null
  else if v == true then "--%s" % k
  else "--%s=%s" % [k, std.toString(v)]
  for k in std.objectFields(std.prune(xs))
];

// TODO: use --provider=keycloak-oidc for keycloak
// TODO: (maybe) generalize to other providers?

{
  _config:: {
    keycloak_realm_url: error "Must set keycloak_realm_url (e.g. https://auth.example.com/auth/realms/example)",

    ingress_class: "nginx",
    ingress_ssl_issuer: "letsencrypt-prod",
    ingress_fqdn: error "Must set ingress_fqdn (e.g. oauth2-proxy.example.com)",
    ingress_url: "https://%s" % self.ingress_fqdn,
    ingress_api_v1: true,

    oauth_client_id: error "Must set oauth_client_id",

    oauth_client_secret: if self.oauth_secret_name == "" then error "Must set oauth_client_secret",
    oauth_cookie_secret: if self.oauth_secret_name == "" then error "Must set oauth_cookie_secret (should be a base64-encoded random string)",

    oauth_secret_name: "",

    cookie_domain: null,
    cookie_name: null,
    email_domain: "*",
    whitelist_domain: null,

    nodeSelector: {},
    tolerations: [],

    replicas: 3,
    resources: {
      limits: {},
      requests: {
        cpu: "100m",
        memory: "300Mi",
      },
    },

    ports: {
      http: 4180,
      metrics: 9100,
    },

    // these get translated into --k=v commandline flags
    args: {
      "http-address": "0.0.0.0:%(http)s" % $._config.ports,
      "metrics-address": "0.0.0.0:%(metrics)s" % $._config.ports,
      "silence-ping-logging": true,
      "provider": "oidc",
      // "cookie-refresh": "1h",   // TODO: do we need this?
      "reverse-proxy": true,
      "pass-access-token": true,   // set X-Auth-Request-Access-Token (when --set-xauthrequest is also set)
      "set-xauthrequest": true,    // set X-Auth-Request-{User,Groups,Email,Preferred-Username} in response
      "set-authorization-header": true,
      "client-id": $._config.oauth_client_id,

      "redirect-url": "%(ingress_url)s/oauth2/callback" % $._config,

      "oidc-issuer-url": "%(keycloak_realm_url)s" % $._config,
      // The rest of these *-url flags might be unnecessary when --oidc-issuer-url is set
      "login-url": "%(keycloak_realm_url)s/protocol/openid-connect/auth" % $._config,
      "redeem-url": "%(keycloak_realm_url)s/protocol/openid-connect/token" % $._config,
      "profile-url": "%(keycloak_realm_url)s/protocol/openid-connect/userinfo" % $._config,
      "validate-url": "%(keycloak_realm_url)s/protocol/openid-connect/userinfo" % $._config,

      "email-domain": $._config.email_domain,
      "whitelist-domain": $._config.whitelist_domain,
      "cookie-domain": $._config.cookie_domain,
      "cookie-name": $._config.cookie_name,

    }
  },

  _images:: {
    oauth2_proxy: "quay.io/oauth2-proxy/oauth2-proxy:v7.1.3",
  },

  oauth2_proxy: {
    secret: if $._config.oauth_secret_name != "" then {} else (
      secret.new(name="oauth2-proxy", data={
        OAUTH2_PROXY_CLIENT_SECRET: std.base64($._config.oauth_client_secret),
        OAUTH2_PROXY_COOKIE_SECRET: std.base64($._config.oauth_cookie_secret),
      })
    ),
    local secretName = if $._config.oauth_secret_name != "" then
        $._config.oauth_secret_name
      else $.oauth2_proxy.secret.metadata.name,

    deployment: (
      deployment.new(
        name="oauth2-proxy",
        replicas=$._config.replicas,
        containers=[
          container.new("oauth2-proxy", $._images.oauth2_proxy) +
          container.withPorts(std.objectValues(std.mapWithKey(port.new, $._config.ports))) +
          container.withEnvFrom(
            envFromSource.secretRef.withName(secretName)
          ) +
          container.livenessProbe.httpGet.withPort($._config.ports.http) +
          container.livenessProbe.httpGet.withPath("/ping") +
          container.livenessProbe.withInitialDelaySeconds(0) +
          container.livenessProbe.withTimeoutSeconds(1) +
          container.readinessProbe.httpGet.withPort($._config.ports.http) +
          container.readinessProbe.httpGet.withPath("/ping") +
          container.readinessProbe.withInitialDelaySeconds(0) +
          container.readinessProbe.withTimeoutSeconds(1) +
          container.resources.withLimits($._config.resources.limits) +
          container.resources.withRequests($._config.resources.requests) +
          container.withArgs(genFlags($._config.args))
        ]
      ) + deployment.spec.template.spec.withNodeSelector($._config.nodeSelector)
        + deployment.spec.template.spec.withTolerations($._config.tolerations)
        + if $._config.oauth_secret_name != "" then {} else
          deployment.spec.template.metadata.withAnnotations({
            "checksum/secret": std.md5(std.toString($.oauth2_proxy.secret.data)),
          }) 
    ),

    service: k.util.serviceFor(self.deployment),

    serviceMonitor: {
      apiVersion: "monitoring.coreos.com/v1",
      kind: "ServiceMonitor",
      metadata: {
        name: "oauth2-proxy",
      },
      spec: {
        endpoints: [{
          targetPort: $._config.ports.metrics,
        }],
        selector: {
          matchLabels: {
            name: "oauth2-proxy",
          },
        },
      },
    },

    local network = if $._config.ingress_api_v1 then networkV1 else networkV1B1,
    local ingress = network.ingress,
    local httpIngressPath = network.httpIngressPath,
    ingress: (
      ingress.new("oauth2-proxy") +
      ingress.metadata.withAnnotationsMixin({
        "nginx.ingress.kubernetes.io/configuration-snippet": "subrequest_output_buffer_size 8k;",
        "nginx.ingress.kubernetes.io/proxy-buffer-size": "8k",
      }) +
      ingress.spec.withIngressClassName($._config.ingress_class) +
      ingress.spec.withRules([
        network.ingressRule.withHost($._config.ingress_fqdn) +
        network.ingressRule.http.withPaths([
          httpIngressPath.withPath("/") +
          httpIngressPath.withPathType("Prefix") +
          (if $._config.ingress_api_v1 then
            httpIngressPath.backend.service.withName($.oauth2_proxy.service.metadata.name) +
            httpIngressPath.backend.service.port.withNumber($._config.ports.http)
          else
            httpIngressPath.backend.withServiceName($.oauth2_proxy.service.metadata.name) +
            httpIngressPath.backend.withServicePort($._config.ports.http))
        ])
      ]) +
      ingress.metadata.withAnnotationsMixin({"cert-manager.io/cluster-issuer": $._config.ingress_ssl_issuer}) +
      ingress.spec.withTls([
        k.networking.v1.ingressTLS.withHosts([$._config.ingress_fqdn]) +
        k.networking.v1.ingressTLS.withSecretName("oauth2-proxy-ingress-cert")
      ])
    ),
  },

}
