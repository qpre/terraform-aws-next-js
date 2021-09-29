locals {
  config_dir = trimsuffix(var.next_tf_dir, "/")
}


output "config_dir" { value = local.config_dir }
output "lambdas" { value = lookup(var.config_file, "lambdas", {}) }
output "static_files_archive_name" { value = lookup(var.config_file, "staticFilesArchive", "") }
output "static_files_archive" { value = "${local.config_dir}/${local.static_files_archive_name}" }
output "config_file_images" { value = lookup(var.config_file, "images", {}) }
output "config_file_version" { value = lookup(var.config_file, "version", 0) }
output "static_routes_json" { value = lookup(var.config_file, "staticRoutes", []) }
output "routes_json" { value = lookup(var.config_file, "routes", []) }
output "prerenders_json" { value = lookup(var.config_file, "prerenders", {}) }
