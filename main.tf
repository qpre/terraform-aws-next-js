locals {
  # next-tf config
  config_dir = trimsuffix(var.next_tf_dir, "/")

  lambdas                   = lookup(var.config_file, "lambdas", {})
  static_files_archive_name = lookup(var.config_file, "staticFilesArchive", "")
  static_files_archive      = "${local.config_dir}/${local.static_files_archive_name}"

  # Build the proxy config JSON
  config_file_images  = lookup(var.config_file, "images", {})
  config_file_version = lookup(var.config_file, "version", 0)
  static_routes_json  = lookup(var.config_file, "staticRoutes", [])
  routes_json         = lookup(var.config_file, "routes", [])
  lambda_routes_json = flatten([
    for integration_key, integration in local.lambdas : [
      lookup(integration, "route", "/")
    ]
  ])
  prerenders_json = lookup(var.config_file, "prerenders", {})
  proxy_config_json = jsonencode({
    routes       = local.routes_json
    staticRoutes = local.static_routes_json
    lambdaRoutes = local.lambda_routes_json
    prerenders   = local.prerenders_json
  })
}

# Generates for each function a unique function name
resource "random_id" "function_name" {
  for_each = local.lambdas

  prefix      = "${each.key}-"
  byte_length = 4
}

#########
# Lambdas
#########

# Static deployment to S3 website and handles CloudFront invalidations
module "statics_deploy" {
  source = "./modules/statics-deploy"

  domain_name                  = var.domain_name
  expire_static_assets         = var.expire_static_assets
  static_files_archive         = local.static_files_archive
  static_files_archive_name    = local.static_files_archive_name
  lambda_logging_policy_arn    = aws_iam_policy.lambda_logging.arn
  lambda_attach_to_vpc         = var.lambda_attach_to_vpc
  lambda_environment_variables = var.lambda_environment_variables
  multiple_deployments         = var.multiple_deployments
  proxy_config_table_name      = module.proxy_config.table_name
  proxy_config_table_arn       = module.proxy_config.table_arn
  proxy_config_bucket_name     = module.proxy_config.bucket_name
  proxy_config_bucket_arn      = module.proxy_config.bucket_arn
  vpc_security_group_ids       = var.vpc_security_group_ids
  vpc_subnet_ids               = var.vpc_subnet_ids

  cloudfront_id  = var.cloudfront_create_distribution ? module.cloudfront_main[0].cloudfront_id : var.cloudfront_external_id
  cloudfront_arn = var.cloudfront_create_distribution ? module.cloudfront_main[0].cloudfront_arn : var.cloudfront_external_arn

  lambda_role_permissions_boundary = var.lambda_role_permissions_boundary
  use_awscli_for_static_upload     = var.use_awscli_for_static_upload

  deployment_name = var.deployment_name
  tags            = var.tags

  debug_use_local_packages = var.debug_use_local_packages
  tf_next_module_root      = path.module
}

# Lambda

resource "aws_lambda_function" "this" {
  for_each = local.lambdas

  function_name = random_id.function_name[each.key].hex
  description   = "Managed by Terraform-next.js"
  role          = aws_iam_role.lambda[each.key].arn
  handler       = lookup(each.value, "handler", "")
  runtime       = lookup(each.value, "runtime", var.lambda_runtime)
  memory_size   = lookup(each.value, "memory", var.lambda_memory_size)
  timeout       = var.lambda_timeout
  tags          = var.tags

  filename         = "${local.config_dir}/${lookup(each.value, "filename", "")}"
  source_code_hash = filebase64sha256("${local.config_dir}/${lookup(each.value, "filename", "")}")

  dynamic "environment" {
    for_each = length(var.lambda_environment_variables) > 0 ? [true] : []
    content {
      variables = var.lambda_environment_variables
    }
  }

  dynamic "vpc_config" {
    for_each = var.lambda_attach_to_vpc ? [true] : []
    content {
      security_group_ids = var.vpc_security_group_ids
      subnet_ids         = var.vpc_subnet_ids
    }
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_logs, aws_cloudwatch_log_group.this]
}

# Lambda invoke permission

resource "aws_lambda_permission" "current_version_triggers" {
  for_each = local.lambdas

  statement_id  = "AllowInvokeFromApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = random_id.function_name[each.key].hex
  principal     = "apigateway.amazonaws.com"

  source_arn = "${module.api_gateway.apigatewayv2_api_execution_arn}/*/*/*"
}

#############
# Api-Gateway
#############

locals {
  integrations_keys = flatten([
    for integration_key, integration in local.lambdas : [
      "ANY ${lookup(integration, "route", "")}/{proxy+}"
    ]
  ])
  integration_values = flatten([
    for integration_key, integration in local.lambdas : {
      lambda_arn             = aws_lambda_function.this[integration_key].arn
      payload_format_version = "2.0"
      timeout_milliseconds   = var.lambda_timeout * 1000
    }
  ])
  integrations = zipmap(local.integrations_keys, local.integration_values)
}

module "api_gateway" {
  source  = "terraform-aws-modules/apigateway-v2/aws"
  version = "1.1.0"

  name          = var.deployment_name
  description   = "Managed by Terraform-next.js"
  protocol_type = "HTTP"

  create_api_domain_name = false

  integrations = local.integrations

  tags = var.tags
}

############
# Next/Image
############

# Permission for image optimizer to fetch images from S3 deployment
data "aws_iam_policy_document" "access_static_deployment" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${module.statics_deploy.static_bucket_arn}/*"]
  }
}

module "next_image" {
  count = var.create_image_optimization ? 1 : 0

  source  = "milliHQ/next-js-image-optimization/aws"
  version = ">= 11.0.0"

  cloudfront_create_distribution = false

  # tf-next does not distinct between image and device sizes, because they
  # are eventually merged together on the image optimizer.
  # So we only use a single key (next_image_domains) to pass ALL (image &
  # device) sizes to the optimizer and by setting the other
  # (next_image_device_sizes) to an empty array which prevents the optimizer
  # from adding the default device settings
  next_image_domains      = lookup(var.config_file_images, "domains", [])
  next_image_image_sizes  = lookup(var.config_file_images, "sizes", [])
  next_image_device_sizes = []

  source_bucket_id = module.statics_deploy.static_bucket_id

  lambda_memory_size               = var.image_optimization_lambda_memory_size
  lambda_attach_policy_json        = true
  lambda_policy_json               = data.aws_iam_policy_document.access_static_deployment.json
  lambda_role_permissions_boundary = var.lambda_role_permissions_boundary

  deployment_name = var.deployment_name
  tags            = var.tags
}

#########################
# CloudFront Proxy Config
#########################

module "proxy_config" {
  source = "./modules/cloudfront-proxy-config"

  cloudfront_price_class = var.cloudfront_price_class
  proxy_config_json      = local.proxy_config_json
  proxy_config_version   = var.config_file_version
  multiple_deployments   = var.multiple_deployments

  deployment_name = var.deployment_name
  tags            = var.tags
}

#####################
# Proxy (Lambda@Edge)
#####################

resource "random_id" "policy_name" {
  prefix      = "${var.deployment_name}-"
  byte_length = 4
}

module "proxy" {
  source = "./modules/proxy"

  lambda_role_permissions_boundary = var.lambda_role_permissions_boundary

  deployment_name = var.deployment_name
  tags            = var.tags

  debug_use_local_packages = var.debug_use_local_packages
  tf_next_module_root      = path.module
  multiple_deployments     = var.multiple_deployments
  proxy_config_table_arn   = module.proxy_config.table_arn

  providers = {
    aws.global_region = aws.global_region
  }
}

#########################
# CloudFront distribution
#########################

# Origin & Cache Policies
#########################

# Managed origin policy
data "aws_cloudfront_origin_request_policy" "managed_cors_s3_origin" {
  name = "Managed-CORS-S3Origin"
}

# Managed cache policy
data "aws_cloudfront_cache_policy" "managed_caching_optimized" {
  name = "Managed-CachingOptimized"
}

##
# Origin request policy
#
# Determines which headers are forwarded to the S3 or Lambda origin.
# Is only used for the default cache behavior.
##
locals {
  # Default headers that should be forwarded to the origins
  cloudfront_origin_default_headers = ["x-nextjs-page"]
  cloudfront_origin_headers = sort(concat(
    local.cloudfront_origin_default_headers,
    var.cloudfront_origin_headers
  ))
}

resource "aws_cloudfront_origin_request_policy" "this" {
  name    = "${random_id.policy_name.hex}-origin"
  comment = "Managed by Terraform Next.js"

  cookies_config {
    cookie_behavior = "all"
  }

  headers_config {
    header_behavior = "whitelist"

    headers {
      items = local.cloudfront_origin_headers
    }
  }

  query_strings_config {
    query_string_behavior = "all"
  }
}

data "aws_region" "current" {}

resource "aws_cloudfront_cache_policy" "this" {
  name    = "${random_id.policy_name.hex}-cache"
  comment = "Managed by Terraform Next.js"

  # Default values (Should be provided by origin)
  min_ttl     = 0
  default_ttl = 86400
  max_ttl     = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "all"
    }

    headers_config {
      header_behavior = length(var.cloudfront_cache_key_headers) == 0 ? "none" : "whitelist"

      dynamic "headers" {
        for_each = length(var.cloudfront_cache_key_headers) == 0 ? [] : [true]
        content {
          items = var.cloudfront_cache_key_headers
        }
      }
    }

    query_strings_config {
      query_string_behavior = "all"
    }

    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

locals {
  # CloudFront default root object
  ################################
  cloudfront_default_root_object = ""

  # CloudFront Origins
  ####################

  # Default origin (With config for Lambda@Edge Proxy)
  cloudfront_origin_static_content = {
    domain_name = module.statics_deploy.static_bucket_endpoint
    origin_id   = "tf-next-s3-static-content"

    s3_origin_config = {
      origin_access_identity = module.statics_deploy.static_bucket_access_identity
    }

    custom_header = [
      {
        name  = "x-env-config-endpoint"
        value = "http://${module.proxy_config.config_endpoint}"
      },
      {
        name  = "x-env-config-table"
        value = var.multiple_deployments ? module.proxy_config.table_name : ""
      },
      {
        name  = "x-env-config-region"
        value = data.aws_region.current.name
      },
      {
        name  = "x-env-api-endpoint"
        value = trimprefix(module.api_gateway.apigatewayv2_api_api_endpoint, "https://")
      },
      {
        name  = "x-env-domain-name"
        value = var.domain_name != null ? var.domain_name : ""
      }
    ]
  }

  # Little hack here to create a dynamic object with different number of attributes
  # using filtering: https://www.terraform.io/docs/language/expressions/for.html#filtering-elements
  _cloudfront_origins = {
    static_content = merge(local.cloudfront_origin_static_content, { create = true })
    next_image = merge(
      var.create_image_optimization ? module.next_image[0].cloudfront_origin_image_optimizer : null, {
        create = var.create_image_optimization
    })
  }

  cloudfront_origins = {
    for key, origin in local._cloudfront_origins : key => origin
    if origin.create
  }

  # CloudFront behaviors
  ######################

  # Default CloudFront behavior
  # (Lambda@Edge Proxy)
  cloudfront_default_behavior = {
    default_behavior = {
      allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
      cached_methods   = ["GET", "HEAD"]
      target_origin_id = local.cloudfront_origin_static_content.origin_id

      compress               = true
      viewer_protocol_policy = "redirect-to-https"

      origin_request_policy_id = aws_cloudfront_origin_request_policy.this.id
      cache_policy_id          = aws_cloudfront_cache_policy.this.id

      lambda_function_association = {
        event_type   = "origin-request"
        lambda_arn   = module.proxy.lambda_edge_arn
        include_body = false
      }
    }
  }

  # Next.js static assets behavior
  cloudfront_ordered_cache_behavior_static_assets = {
    path_pattern     = "/_next/static/*"
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.cloudfront_origin_static_content.origin_id

    compress               = true
    viewer_protocol_policy = "redirect-to-https"

    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.managed_cors_s3_origin.id
    cache_policy_id          = data.aws_cloudfront_cache_policy.managed_caching_optimized.id
  }

  # next/image behavior
  cloudfront_ordered_cache_behavior_next_image = var.create_image_optimization ? module.next_image[0].cloudfront_cache_behavior : null

  # Little hack here to create a dynamic object with different number of attributes
  # using filtering: https://www.terraform.io/docs/language/expressions/for.html#filtering-elements
  _cloudfront_ordered_cache_behaviors = {
    static_assets = merge(local.cloudfront_ordered_cache_behavior_static_assets, { create = true })
    next_image = merge(local.cloudfront_ordered_cache_behavior_next_image, {
      create = var.create_image_optimization
    })
  }

  cloudfront_ordered_cache_behaviors = {
    for key, behavior in local._cloudfront_ordered_cache_behaviors : key => behavior
    if behavior.create
  }

  cloudfront_custom_error_response = {
    s3_failover = {
      error_caching_min_ttl = 60
      error_code            = 403
      response_code         = 404
      response_page_path    = "/404"
    }
  }
}

module "cloudfront_main" {
  count = var.cloudfront_create_distribution ? 1 : 0

  source = "./modules/cloudfront-main"

  cloudfront_price_class              = var.cloudfront_price_class
  cloudfront_aliases                  = var.cloudfront_aliases
  cloudfront_acm_certificate_arn      = var.cloudfront_acm_certificate_arn
  cloudfront_minimum_protocol_version = var.cloudfront_minimum_protocol_version

  cloudfront_default_root_object     = local.cloudfront_default_root_object
  cloudfront_origins                 = local.cloudfront_origins
  cloudfront_default_behavior        = local.cloudfront_default_behavior
  cloudfront_ordered_cache_behaviors = local.cloudfront_ordered_cache_behaviors
  cloudfront_custom_error_response   = local.cloudfront_custom_error_response

  deployment_name = var.deployment_name
  tags            = var.tags
}
