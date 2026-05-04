#https://medium.com/@charled.breteche/kind-keycloak-and-argocd-with-sso-9f3536dd7f61
#https://www.linkedin.com/pulse/keycloak-create-realm-terraform-young-gyu-kim-y7urc
#https://github.com/keycloak/terraform-provider-keycloak/tree/main/example

terraform {
  required_providers {
    keycloak = {
      source = "keycloak/keycloak"
      version = ">= 5.7.0"
    }
  }
}

locals {
  groups   = ["argo-admin-grp", "argo-dev-grp", "kf-user-grp"]  
  user_groups = {
    adura2abiona   = ["argo-admin-grp", "argo-dev-grp", "kf-user-grp"]
    oye2fimihan    = ["argo-dev-grp", "kf-user-grp"]
    iyin2oluwa     = ["argo-dev-grp", "kf-user-grp"]
  }
}

# configure keycloak provider
provider "keycloak" {
  client_id = "admin-cli"
  username  = "admin"
  password  = "Admin001"
  url       = "https://keycloak.util.lcl"
  realm     = "master"
}

# Create a new realm
resource "keycloak_realm" "k8s_realm" {
  realm             = "k8s-realm"
  enabled           = true
  display_name      = "K8s Realm"
  display_name_html = "<b>K8s Realm for ArgoCD, Kubeflow</b>"
}

# create groups openid client scope
resource "keycloak_openid_client_scope" "groups" {
  realm_id               = keycloak_realm.k8s_realm.id
  name                   = "groups"
  include_in_token_scope = true
  gui_order              = 1
}

resource "keycloak_openid_group_membership_protocol_mapper" "groups" {
  realm_id        = keycloak_realm.k8s_realm.id
  client_scope_id = keycloak_openid_client_scope.groups.id
  name            = "groups"
  claim_name      = "groups"
  full_path       = false
}

# create groups
resource "keycloak_group" "groups" {
  for_each   = toset(local.groups)
  realm_id   = keycloak_realm.k8s_realm.id
  name       = each.key
}

# create users
resource "keycloak_user" "users" {
  for_each   = local.user_groups
  realm_id   = keycloak_realm.k8s_realm.id
  username   = "${each.key}@util.lcl"
  enabled    = true
  email      = "${each.key}@util.lcl"
  first_name = each.key
  last_name  = each.key
  initial_password {
    value = each.key
  }
}

# configure use groups membership
resource "keycloak_user_groups" "user_groups" {
  for_each  = local.user_groups
  realm_id   = keycloak_realm.k8s_realm.id
  user_id   = keycloak_user.users[each.key].id
  group_ids = [for g in each.value : keycloak_group.groups[g].id]
}

#=========== ArgoCD Client ===================
# create argocd openid client
resource "keycloak_openid_client" "argocd_client" {
  realm_id              = keycloak_realm.k8s_realm.id
  client_id             = "argocd-client"
  name                  = "ArgoCD Client"  
  description           = "ArgoCD OIDC Client"

  enabled               = true
  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true  
  direct_access_grants_enabled = true

  root_url      = "https://argocd.k8s.lcl"
  base_url = "/applications"
  valid_redirect_uris = [
    "https://argocd.k8s.lcl/auth/callback"
  ]
  valid_post_logout_redirect_uris = [
    "https://argocd.k8s.lcl/applications"
  ]  
  web_origins   = ["+"]

  client_secret        = "Kokoro4Argocd"
  login_theme          = "customtheme"  
}

# configure argocd openid client default scopes
resource "keycloak_openid_client_default_scopes" "client_default_scopes_argocd" {
  realm_id        = keycloak_realm.k8s_realm.id
  client_id       = keycloak_openid_client.argocd_client.id
  default_scopes  = [
    "profile",
    "email",
    "roles",
    "web-origins",
    keycloak_openid_client_scope.groups.name,
  ]
}

# output argocd openid client secret
output "client-secret-argocd" {
  value     = keycloak_openid_client.argocd_client.client_secret
  sensitive = true
}

#=========== Kubeflow Client ===================
# create kubeflow openid client
resource "keycloak_openid_client" "kubeflow_client" {
  realm_id              = keycloak_realm.k8s_realm.id
  client_id             = "kubeflow-oidc-authservice"
  name                  = "Kubeflow Client"  
  description           = "Kubeflow OIDC Client"

  enabled               = true
  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true  
  direct_access_grants_enabled = true

  root_url              = "https://kubeflow.k8s.lcl"
  base_url              = "https://kubeflow.k8s.lcl"
  valid_redirect_uris   = [
    "https://kubeflow.k8s.lcl/oauth2/callback"
  ]
  valid_post_logout_redirect_uris = [
    "https://kubeflow.k8s.lcl/*"
  ]  
  web_origins   = ["+"]

  client_secret         = "Kokoro4Kubeflow"
  login_theme           = "customtheme"  
}

# configure kubeflow openid client default scopes
resource "keycloak_openid_client_default_scopes" "client_default_scopes_kubeflow" {
  realm_id        = keycloak_realm.k8s_realm.id
  client_id       = keycloak_openid_client.kubeflow_client.id
  default_scopes  = [
    "profile",
    "email",
    "roles",
    "web-origins",
    keycloak_openid_client_scope.groups.name,
  ]
}

# output kubeflow openid client secret
output "client-secret-kubeflow" {
  value     = keycloak_openid_client.kubeflow_client.client_secret
  sensitive = true
}

