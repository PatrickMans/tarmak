data "template_file" "vault" {
  template = "${file("${path.module}/templates/vault_user_data.yaml")}"
  count    = "${var.vault_instance_count}"

  vars {
    fqdn           = "vault-${count.index + 1}.${var.private_zone}"
    environment    = "${var.environment}"
    region         = "${var.region}"
    instance_count = "${var.vault_instance_count}"
    volume_id      = "${element(aws_ebs_volume.vault.*.id, count.index)}"
    private_ip     = "${cidrhost(element(var.private_subnets, count.index % length(var.availability_zones)),(10 + (count.index/length(var.availability_zones))))}"

    consul_version      = "${var.consul_version}"
    consul_master_token = "${random_id.consul_master_token.hex}"

    # We need to convert to the default base64 alphabet
    consul_encrypt = "${replace(replace(random_id.consul_encrypt.b64,"-","+"),"_","/")}=="

    vault_version       = "${var.vault_version}"
    vault_tls_cert_path = "s3://${var.secrets_bucket}/${element(aws_s3_bucket_object.node-certs.*.key, count.index)}"
    vault_tls_key_path  = "s3://${var.secrets_bucket}/${element(aws_s3_bucket_object.node-keys.*.key, count.index)}"
    vault_tls_ca_path   = "s3://${var.secrets_bucket}/${aws_s3_bucket_object.ca-cert.key}"

    vault_unsealer_kms_key_id     = "${var.secrets_kms_arn}"
    vault_unsealer_ssm_key_prefix = "${data.template_file.vault_unseal_key_name.rendered}"

    backup_bucket_prefix = "${var.backups_bucket}/${data.template_file.stack_name.rendered}-vault-${count.index+1}"

    # run backup once per instance spread throughout the day
    backup_schedule = "*-*-* ${format("%02d",count.index * (24/var.vault_instance_count))}:00:00"
  }
}

resource "aws_cloudwatch_metric_alarm" "vault-autorecover" {
  count               = "${var.vault_instance_count}"
  alarm_name          = "vault-autorecover-${var.environment}-${count.index+1}"
  namespace           = "AWS/EC2"
  evaluation_periods  = "2"
  period              = "60"
  alarm_description   = "This metric auto recovers Vault instances for the ${var.environment} cluster"
  alarm_actions       = ["arn:aws:automate:${var.region}:ec2:recover"]
  statistic           = "Minimum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = "1"
  metric_name         = "StatusCheckFailed_System"

  dimensions {
    InstanceId = "${element(aws_instance.vault.*.id, count.index)}"
  }
}

data "tarmak_bastion_instance" "bastion" {
  hostname = "bastion"
  username = "centos"
  instance_id = "${var.bastion_instance_id}"
}

resource "aws_instance" "vault" {
  ami                  = "${var.vault_ami}"
  instance_type        = "${var.vault_instance_type}"
  key_name             = "${var.key_name}"
  subnet_id            = "${element(var.private_subnet_ids, count.index % length(var.availability_zones))}"
  count                = "${var.vault_instance_count}"
  user_data            = "${element(data.template_file.vault.*.rendered, count.index)}"
  iam_instance_profile = "${element(aws_iam_instance_profile.vault.*.name, count.index)}"
  private_ip           = "${cidrhost(element(var.private_subnets, count.index % length(var.availability_zones)),(10 + (count.index/length(var.availability_zones))))}"

  vpc_security_group_ids = [
    "${aws_security_group.vault.id}",
  ]

  root_block_device = {
    volume_type = "gp2"
    volume_size = "${var.vault_root_size}"
  }

  tags {
    Name         = "${data.template_file.stack_name.rendered}-vault-${count.index+1}"
    Environment  = "${var.environment}"
    Project      = "${var.project}"
    Contact      = "${var.contact}"
    VaultCluster = "${var.environment}"
    tarmak_role  = "vault-${count.index+1}"
  }

  lifecycle {
    ignore_changes = ["volume_tags"]
  }

  depends_on = ["data.tarmak_bastion_instance.bastion"]
}

resource "aws_ebs_volume" "vault" {
  count             = "${var.vault_instance_count}"
  size              = "${var.vault_data_size}"
  availability_zone = "${element(var.availability_zones, count.index % length(var.availability_zones))}"

  tags {
    Name        = "${data.template_file.stack_name.rendered}-vault-${count.index+1}"
    Environment = "${var.environment}"
    Project     = "${var.project}"
    Contact     = "${var.contact}"
  }

  lifecycle = {
    #prevent_destroy = true
  }
}
