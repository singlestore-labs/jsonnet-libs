local tk = import "tk";
local k = import "github.com/grafana/jsonnet-libs/ksonnet-util/kausal.libsonnet";

local container = k.core.v1.container;
local secret = k.core.v1.secret;
local configMap = k.core.v1.configMap;
local serviceAccount = k.core.v1.serviceAccount;
local envVar = k.core.v1.envVar;
local role = k.rbac.v1.role;
local roleBinding = k.rbac.v1.roleBinding;
local policyRule = k.rbac.v1.policyRule;
local subject = k.rbac.v1.subject;
local volumeMount = k.core.v1.volumeMount;
local volume = k.core.v1.volume;

local deployment = k.apps.v1.deployment + {
  // configMapVolumeMount copied from upstream and tweaked to include a volumeMixin arg
  configMapVolumeMount(configMap, path, volumeMountMixin={}, volumeMixin={}):: (
    local name = configMap.metadata.name,
          hash = std.md5(std.toString(configMap)),
          addMount(c) = c + container.withVolumeMountsMixin(
            volumeMount.new(name, path) +
            volumeMountMixin,
          );

    super.mapContainers(addMount) +
    super.spec.template.spec.withVolumesMixin([
      volume.fromConfigMap(name, name) +
      volumeMixin,
    ]) +
    super.spec.template.metadata.withAnnotationsMixin({
      ["%s-hash" % name]: hash,
    })
  ),
};


{
  _config+:: {
    tailscale+: {

      // If you're using inline environments, or not using tanka at all, just
      // override this and set it directly
      namespace: tk.env.spec.namespace,

      // OPTIONAL: a tailscale api auth key to bootstrap the instance.  If you
      // leave this blank, tailscaled will print a login URL in its stderr logs
      // that you can click on to authenticate.
      auth_key: null,

      // List of CIDR ranges, e.g. ["192.168.0.1/24", "172.16.2.0/22"]
      routes: [],

      // Extra args passed to `tailscale up`
      extra_args: "",
    },
  },

  _images+:: {
    tailscale: "ghcr.io/tailscale/tailscale:v1.24.2",
  },

  tailscale+: {
    deployment: (
      deployment.new(
        name="tailscaled",
        replicas=1,
        containers=[
          container.new("tailscaled", $._images.tailscale) +
          container.withCommand("/config/run.sh") +
          container.withEnv(
            envVar.fromSecretRef("AUTH_KEY", self.stateSecret.metadata.name, "AUTH_KEY")
          ) +
          container.withEnvMap({
            USERSPACE: "true",
            ROUTES: std.join(",", $._config.tailscale.routes),
            KUBE_SECRET: $.tailscale.stateSecret.metadata.name,
            EXTRA_ARGS: $._config.tailscale.extra_args,
          }) +
          container.resources.withRequests({
            cpu: "100m",
            memory: "100Mi",
          }) +
          container.resources.withLimits({
            cpu: "1000m",
            memory: "300Mi",
          })
        ]
      ) +
      deployment.spec.template.spec.withServiceAccountName(self.serviceAccount.metadata.name) +
      deployment.spec.template.spec.securityContext.withRunAsUser(1000) +
      deployment.spec.template.spec.securityContext.withRunAsGroup(1000) +
      deployment.configMapVolumeMount(
        self.configMap, "/config",
        volumeMixin={configMap+: {defaultMode: std.parseOctal("0755")}}
      )
    ),


    stateSecret: secret.new(
      name="tailscale-state",
      data={
        [if $._config.tailscale.auth_key != null then "AUTH_KEY"]: std.base64($._config.tailscale.auth_key),
      }
    ),

    configMap: configMap.new(
      name="tailscale-entrypoint",
      data={
        "run.sh": importstr "run.sh",
      },
    ),

    serviceAccount: (
      serviceAccount.new("tailscale") +
      serviceAccount.metadata.withNamespace($._config.tailscale.namespace)
    ),

    role: (
      role.new("tailscale") +
      role.withRules([
        // let tailscaled create, get, and update its state secret
        ( policyRule.withApiGroups([""]) +
          policyRule.withVerbs(["create"]) +
          policyRule.withResources(["secrets"])
        ),
        ( policyRule.withApiGroups([""]) +
          policyRule.withVerbs(["get", "update"]) +
          policyRule.withResources(["secrets"]) +
          policyRule.withResourceNames([self.stateSecret.metadata.name])
        ),
      ])
    ),

    roleBinding: (
      roleBinding.new("tailscale") +
      roleBinding.bindRole(self.role) +
      roleBinding.withSubjects(
        subject.fromServiceAccount(self.serviceAccount)
      )
    )
  }
}
