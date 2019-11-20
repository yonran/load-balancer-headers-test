// Configure the Google Cloud provider
provider "google" {
  version = "~> 2.20.0" # 3.0.0-beta.1
  project = var.project
  region  = "us-central1"
}

terraform {
  #  backend "gcs" {
  #    bucket  = "my-bucket"
  #    prefix    = "echo-headers"
  #  }
}

variable "project" {
  description = "GCP Project. Suggestion: \"project = \\\"$(gcloud config list --format 'value(core.project)' 2>/dev/null)\\\"\" > terraform.tfvars"
  type = string
}

variable "bucket-name" {
  description = "Name of bucket to use to store install files"
  type = string
}

variable "ssl-certificates" {
  description = "SSL certificate resource names (e.g. projects/MY_PROJECT/global/sslCertificates/MY_CERT) for use by the target https proxy. If size is 0, then target https proxy is not created."
  type = list(string)
  default = []
}

resource "google_storage_bucket" "echo-headers" {
  name     = var.bucket-name
  location = "us-west1"
}

variable "install-files" {
  description = "Files to copy from "
  type        = list(string)
  default = [
    "echo-headers.py",
    "echo-headers.service",
    "google-load-balancer/echo-headers-startup-script.sh",
  ]
}

resource "google_storage_bucket_object" "install-files" {
  count  = length(var.install-files)
  name   = element(var.install-files, count.index)
  source = "../${element(var.install-files, count.index)}"
  bucket = google_storage_bucket.echo-headers.name
}

resource "google_service_account" "echo-headers-service-account" {
  account_id   = "echo-headers"
  display_name = "echo-headers"
}

resource "google_storage_bucket_iam_member" "echo-headers" {
  bucket = google_storage_bucket.echo-headers.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.echo-headers-service-account.email}"
}

# firewall to allow Google Load Balancer to contact this backend
# https://cloud.google.com/compute/docs/load-balancing/http/#firewall_rules
# Also needed for HTTP health check, even when the health check
# is used by the instance group manager
# https://cloud.google.com/compute/docs/load-balancing/health-checks#health_check_source_ips_and_firewall_rules
resource "google_compute_firewall" "echo-headers" {
  name          = "echo-headers"
  network       = "default"
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["echo-headers"]
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

# https://www.terraform.io/docs/providers/google/r/compute_instance_template.html
# https://cloud.google.com/compute/docs/reference/latest/instanceTemplates
resource "google_compute_instance_template" "echo-headers" {
  name_prefix          = "echo-headers-"
  tags                 = ["echo-headers"] # "http-server" allows all sources
  instance_description = "echo-headers"
  machine_type         = "f1-micro"

  # region is only needed if you reference regional resources
  # region       = "us-central1"

  labels = {
    app = "echo-headers"
  }

  // boot disk
  disk {
    device_name = "persistent-disk-0" # manually added auto-generated value to make terraform happy
    boot        = true
    auto_delete = true

    # List of public images: gcloud compute images list --standard-images
    # source_image = "ubuntu-os-cloud/ubuntu-1604-lts"
    # List of private images: gcloud compute images list --no-standard-images
    source_image = "ubuntu-os-cloud/ubuntu-1804-lts"
    disk_type    = "pd-standard"
    disk_size_gb = 10
  }

  // networking
  network_interface {
    network = "default"
    access_config {}     # specifying empty access_config means ephemeral external ip
  }

  lifecycle {
    create_before_destroy = true
  }
  service_account {
    email = google_service_account.echo-headers-service-account.email
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
  scheduling {
    preemptible       = false
    automatic_restart = true # must be false for preemptible=true
  }
  metadata = {
    startup-script-url = "${google_storage_bucket.echo-headers.url}/google-load-balancer/echo-headers-startup-script.sh"
    install-bucket = "${google_storage_bucket.echo-headers.name}"
  }
  depends_on = [
    google_storage_bucket_iam_member.echo-headers,
    google_compute_firewall.echo-headers,
    google_storage_bucket_object.install-files,
  ]
}

# https://cloud.google.com/compute/docs/reference/latest/instanceGroupManagers
resource "google_compute_instance_group_manager" "echo-headers" {
  name               = "echo-headers"
  base_instance_name = "echo-headers"
  version {
    name              = "main"
    instance_template = google_compute_instance_template.echo-headers.self_link
  }
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_unavailable_fixed = 1
  }
  zone = "europe-west1-b"

  #target_pools = ["${google_compute_target_pool.appserver.self_link}"]
  target_size = 1

  named_port {
    name = "http"
    port = 80
  }

  lifecycle {
    #prevent_destroy = true
  }
}

resource "google_compute_http_health_check" "echo-headers" {
  name                = "echo-headers"
  request_path        = "/"
  check_interval_sec  = 10
  timeout_sec         = 1
  unhealthy_threshold = 2
  healthy_threshold   = 1
}

resource "google_compute_backend_service" "http" {
  name        = "echo-headers"
  port_name   = "http"
  protocol    = "HTTP"
  timeout_sec = 30
  enable_cdn  = false

  backend {
    group = google_compute_instance_group_manager.echo-headers.instance_group
  }

  health_checks = [google_compute_http_health_check.echo-headers.self_link]
}

resource "google_compute_global_address" "echo-headers" {
  name       = "echo-headers"
  ip_version = "IPV4"
}

resource "google_compute_url_map" "echo-headers" {
  name            = "echo-headers"
  description     = ""
  default_service = google_compute_backend_service.http.self_link
}

resource "google_compute_target_http_proxy" "echo-headers-target-proxy" {
  name    = "echo-headers-target-proxy"
  url_map = google_compute_url_map.echo-headers.self_link
}

resource "google_compute_target_https_proxy" "echo-headers-target-proxy" {
  count      = length(var.ssl-certificates) == 0 ? 0 : 1
  name = "echo-headers-target-proxy"
  url_map = google_compute_url_map.echo-headers.self_link
  ssl_certificates = var.ssl-certificates
}

resource "google_compute_global_forwarding_rule" "http" {
  name       = "echo-headers-http-forwarding-rule"
  target     = google_compute_target_http_proxy.echo-headers-target-proxy.self_link
  ip_address = google_compute_global_address.echo-headers.address
  port_range = "80-80"
}

resource "google_compute_global_forwarding_rule" "https" {
  count      = length(var.ssl-certificates) == 0 ? 0 : 1
  name       = "echo-headers-forwarding-rule"
  target     = google_compute_target_https_proxy.echo-headers-target-proxy[0].self_link
  ip_address = google_compute_global_address.echo-headers.address
  port_range = "443-443"
}

output "echo-headers-service-account-email" {
  value = google_service_account.echo-headers-service-account.email
}

output "echo-headers-public-ip" {
  value = google_compute_global_address.echo-headers.address
}

