locals {
  istio_labels = {
    istio-injection = "enabled"
  }

  kubeconfig = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    current-context = "terraform"
    clusters = [{
      name = module.retail_app_eks.eks_cluster_id
      cluster = {
        certificate-authority-data = module.retail_app_eks.cluster_certificate_authority_data
        server                     = module.retail_app_eks.cluster_endpoint
      }
    }]
    contexts = [{
      name = "terraform"
      context = {
        cluster = module.retail_app_eks.eks_cluster_id
        user    = "terraform"
      }
    }]
    users = [{
      name = "terraform"
      user = {
        token = data.aws_eks_cluster_auth.this.token
      }
    }]
  })
}

resource "null_resource" "cluster_blocker" {
  triggers = {
    "blocker" = module.retail_app_eks.cluster_blocker_id
  }
}

resource "null_resource" "addons_blocker" {
  triggers = {
    "blocker" = module.retail_app_eks.addons_blocker_id
  }
}

resource "time_sleep" "workloads" {
  create_duration  = "30s"
  destroy_duration = "60s"

  depends_on = [ 
    null_resource.addons_blocker
  ]
}

resource "kubernetes_namespace_v1" "assets" {
  depends_on = [
    time_sleep.workloads
  ]

  metadata {
    name = "assets"

    labels = var.istio_enabled ? local.istio_labels : {}
  }
}

resource "helm_release" "assets" {
  name       = "assets"
  chart      = "../../../kubernetes/charts/assets"

  namespace  = kubernetes_namespace_v1.assets.metadata[0].name
  values = [
    templatefile("${path.module}/values/assets.yaml", { 
      opentelemetry_enabled = var.opentelemetry_enabled
    })
  ]
}

resource "kubernetes_namespace_v1" "catalog" {
  depends_on = [
    time_sleep.workloads
  ]

  metadata {
    name = "catalog"

    labels = var.istio_enabled ? local.istio_labels : {}
  }
}

resource "helm_release" "catalog" {
  name       = "catalog"
  chart      = "../../../kubernetes/charts/catalog"

  namespace  = kubernetes_namespace_v1.catalog.metadata[0].name

  values = [
    templatefile("${path.module}/values/catalog.yaml", { 
      opentelemetry_enabled = var.opentelemetry_enabled
      database_endpoint     = "${module.dependencies.catalog_db_endpoint}:${module.dependencies.catalog_db_port}"
      database_username     = module.dependencies.catalog_db_master_username
      database_password     = module.dependencies.catalog_db_master_password
      security_group_id     = aws_security_group.catalog.id
    })
  ]
}

resource "kubernetes_namespace_v1" "carts" {
  depends_on = [
    time_sleep.workloads
  ]

  metadata {
    name = "carts"

    labels = var.istio_enabled ? local.istio_labels : {}
  }
}

resource "helm_release" "carts" {
  name       = "carts"
  chart      = "../../../kubernetes/charts/carts"

  namespace  = kubernetes_namespace_v1.carts.metadata[0].name

  values = [
    templatefile("${path.module}/values/carts.yaml", { 
      opentelemetry_enabled = var.opentelemetry_enabled
      role_arn              = module.iam_assumable_role_carts.iam_role_arn
      table_name            = module.dependencies.carts_dynamodb_table_name 
    })
  ]
}

resource "kubernetes_namespace_v1" "checkout" {
  depends_on = [
    time_sleep.workloads
  ]

  metadata {
    name = "checkout"

    labels = var.istio_enabled ? local.istio_labels : {}
  }
}

resource "helm_release" "checkout" {
  name       = "checkout"
  chart      = "../../../kubernetes/charts/checkout"

  namespace  = kubernetes_namespace_v1.checkout.metadata[0].name

  values = [
    templatefile("${path.module}/values/checkout.yaml", { 
      opentelemetry_enabled = var.opentelemetry_enabled
      redis_address         = module.dependencies.checkout_elasticache_primary_endpoint
      redis_port            = module.dependencies.checkout_elasticache_port
      security_group_id     = aws_security_group.checkout.id
    })
  ]
}

resource "kubernetes_namespace_v1" "orders" {
  depends_on = [
    time_sleep.workloads
  ]

  metadata {
    name = "orders"

    labels = var.istio_enabled ? local.istio_labels : {}
  }
}

resource "helm_release" "orders" {
  name       = "orders"
  chart      = "../../../kubernetes/charts/orders"

  namespace  = kubernetes_namespace_v1.orders.metadata[0].name

  values = [
    templatefile("${path.module}/values/orders.yaml", { 
      opentelemetry_enabled = var.opentelemetry_enabled
      database_endpoint     = "jdbc:mariadb://${module.dependencies.orders_db_endpoint}:${module.dependencies.orders_db_port}/${module.dependencies.orders_db_database_name}"
      database_username     = module.dependencies.orders_db_master_username
      database_password     = module.dependencies.orders_db_master_password
      rabbitmq_endpoint     = module.dependencies.mq_broker_endpoint
      rabbitmq_username     = module.dependencies.mq_user
      rabbitmq_password     = module.dependencies.mq_password
      security_group_id     = aws_security_group.orders.id
    })
  ]
}

resource "kubernetes_namespace_v1" "ui" {
  depends_on = [
    time_sleep.workloads
  ]

  metadata {
    name = "ui"

    labels = var.istio_enabled ? local.istio_labels : {}
  }
}

resource "helm_release" "ui" {
  name       = "ui"
  chart      = "../../../kubernetes/charts/ui"

  namespace  = kubernetes_namespace_v1.ui.metadata[0].name

  values = [
    templatefile("${path.module}/values/ui.yaml", {
      opentelemetry_enabled = var.opentelemetry_enabled
      istio_enabled         = var.istio_enabled
    })
  ]
}

resource "time_sleep" "restart_pods" {
  create_duration = "30s"

  depends_on = [ 
    helm_release.ui,
    helm_release.opentelemetry
  ]
}

resource "null_resource" "restart_pods" {
  depends_on = [ time_sleep.restart_pods ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = base64encode(local.kubeconfig)
    }
  
    command = <<-EOT
      kubectl delete pod -A -l app.kuberneres.io/owner=retail-store-sample --kubeconfig <(echo $KUBECONFIG | base64 -d)
    EOT
  }
}