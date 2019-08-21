provider "packet" {
  auth_token = "${var.packet_api_key}"
}

provider "ct" {
  version = "0.4.0"
}

resource "tls_private_key" "ssh_key" {
  algorithm   = "RSA"
}

resource "packet_project_ssh_key" "ssh_key" {
  name       = "terraform"
  public_key = "${tls_private_key.ssh_key.public_key_openssh}"
  project_id = "${var.packet_project_id}"
}

resource "tls_private_key" "docker_key" {
  algorithm   = "ECDSA"
}

resource "tls_self_signed_cert" "docker_ca" {
  key_algorithm   = "ECDSA"
  private_key_pem = "${tls_private_key.docker_key.private_key_pem}"

  subject {
    common_name = "docker"
  }

  validity_period_hours = 43800
  is_ca_certificate = true

  allowed_uses = [
    "cert_signing",
  ]
}

resource "tls_cert_request" "docker_csr" {
  key_algorithm   = "ECDSA"
  private_key_pem = "${tls_private_key.docker_key.private_key_pem}"

  subject {
    common_name  = "docker"
  }
}

resource "tls_locally_signed_cert" "docker_cert" {
  cert_request_pem   = "${tls_cert_request.docker_csr.cert_request_pem}"
  ca_key_algorithm   = "ECDSA"
  ca_private_key_pem = "${tls_private_key.docker_key.private_key_pem}"
  ca_cert_pem        = "${tls_self_signed_cert.docker_ca.cert_pem}"

  validity_period_hours = 43800

  allowed_uses = [
    "server_auth",
  ]
}

data "ct_config" "container-linux-config" {
  content      = data.template_file.container-linux-config.rendered
  platform     = "packet"
  pretty_print = false
}

data "template_file" "container-linux-config" {
  template = file("${path.module}/templates/clc.yaml")

  vars = {
    discovery_url = "${file(var.discovery_url_file)}"
    docker_ca = "${tls_self_signed_cert.docker_ca.cert_pem}"
    docker_cert = "${tls_locally_signed_cert.docker_cert.cert_pem}"
    docker_key = "${tls_private_key.docker_key.private_key_pem}"
  }

  depends_on = [template_file.etcd_discovery_url]
}

resource "template_file" "etcd_discovery_url" {
  template = "/dev/null"

  provisioner "local-exec" {
    command = "curl https://discovery.etcd.io/new?size=${(var.node_count)} > ${var.discovery_url_file}"
  }
}

resource "packet_device" "node" {
  hostname         = "${format("node-%02d.bare-metal.cf", count.index + 1)}"
  # operating_system = "coreos_stable"
  operating_system = "coreos_alpha"
  plan             = "${var.node_type}"

  count            = "${var.node_count}"
  user_data        = data.ct_config.container-linux-config.rendered
  facilities       = ["${var.packet_facility}"]
  project_id       = "${var.packet_project_id}"
  billing_cycle    = "hourly"
  project_ssh_key_ids = ["${packet_project_ssh_key.ssh_key.id}"]
}
