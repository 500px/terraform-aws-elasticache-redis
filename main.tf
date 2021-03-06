# Define composite variables for resources
module "label" {
  source     = "git::https://github.com/cloudposse/terraform-null-label.git?ref=tags/0.6.2"
  enabled    = "${var.enabled}"
  namespace  = "${var.namespace}"
  name       = "${var.name}"
  stage      = "${var.stage}"
  delimiter  = "${var.delimiter}"
  attributes = "${var.attributes}"
  tags       = "${var.tags}"
}

locals {
  name = "redis-${var.label_id == "true" ? module.label.name : module.label.id}"

  replication_group_id = "${coalesce(var.replication_group_id, local.name)}"
}

#
# Security Group Resources
#
resource "aws_security_group" "default" {
  count  = "${var.enabled == "true" ? 1 : 0}"
  vpc_id = "${var.vpc_id}"
  name   = "${local.name}"

  ingress {
    from_port       = "${var.port}"              # Redis
    to_port         = "${var.port}"
    protocol        = "tcp"
    security_groups = ["${var.security_groups}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = "${module.label.tags}"
}

resource "aws_elasticache_subnet_group" "default" {
  count      = "${var.enabled == "true" ? 1 : 0}"
  name       = "${local.name}"
  subnet_ids = ["${var.subnets}"]
}

resource "aws_elasticache_parameter_group" "default" {
  count     = "${var.enabled == "true" ? 1 : 0}"
  name      = "${local.name}"
  family    = "${var.family}"
  parameter = "${var.parameter}"
}

# workaround silly terraform bug, see issue #35 in upstream repo
resource "aws_elasticache_replication_group" "encrypt" {
  count = "${var.enabled == "true" && var.transit_encryption_enabled == "true" ? 1 : 0}"

  auth_token                    = "${var.auth_token}"
  replication_group_id          = "${local.replication_group_id}"
  replication_group_description = "${local.name}"
  node_type                     = "${var.instance_type}"
  number_cache_clusters         = "${var.cluster_size}"
  port                          = "${var.port}"
  parameter_group_name          = "${aws_elasticache_parameter_group.default.name}"
  availability_zones            = ["${slice(var.availability_zones, 0, var.cluster_size)}"]
  automatic_failover_enabled    = "${var.automatic_failover}"
  subnet_group_name             = "${aws_elasticache_subnet_group.default.name}"
  security_group_ids            = ["${aws_security_group.default.id}"]
  maintenance_window            = "${var.maintenance_window}"
  notification_topic_arn        = "${var.notification_topic_arn}"
  engine_version                = "${var.engine_version}"
  at_rest_encryption_enabled    = "${var.at_rest_encryption_enabled}"
  transit_encryption_enabled    = "${var.transit_encryption_enabled}"
  snapshot_window               = "${var.snapshot_window}"
  snapshot_retention_limit      = "${var.snapshot_retention_limit}"
  snapshot_arns                 = "${var.snapshot_arns}"
  snapshot_name                 = "${var.snapshot_name}"

  timeouts {
    create = "${var.create_timeouts}"
    delete = "${var.delete_timeouts}"
    update = "${var.update_timeouts}"
  }

  tags = "${module.label.tags}"
}

resource "aws_elasticache_replication_group" "default" {
  count = "${var.enabled == "true" && var.transit_encryption_enabled == "false" ? 1 : 0}"

  replication_group_id          = "${local.replication_group_id}"
  replication_group_description = "${local.name}"
  node_type                     = "${var.instance_type}"
  number_cache_clusters         = "${var.cluster_size}"
  port                          = "${var.port}"
  parameter_group_name          = "${aws_elasticache_parameter_group.default.name}"
  availability_zones            = ["${slice(var.availability_zones, 0, var.cluster_size)}"]
  automatic_failover_enabled    = "${var.automatic_failover}"
  subnet_group_name             = "${aws_elasticache_subnet_group.default.name}"
  security_group_ids            = ["${aws_security_group.default.id}"]
  maintenance_window            = "${var.maintenance_window}"
  notification_topic_arn        = "${var.notification_topic_arn}"
  engine_version                = "${var.engine_version}"
  at_rest_encryption_enabled    = "${var.at_rest_encryption_enabled}"
  transit_encryption_enabled    = "${var.transit_encryption_enabled}"
  snapshot_window               = "${var.snapshot_window}"
  snapshot_retention_limit      = "${var.snapshot_retention_limit}"
  snapshot_arns                 = "${var.snapshot_arns}"
  snapshot_name                 = "${var.snapshot_name}"

  timeouts {
    create = "${var.create_timeouts}"
    delete = "${var.delete_timeouts}"
    update = "${var.update_timeouts}"
  }

  tags = "${module.label.tags}"
}

#
# CloudWatch Resources
#
resource "aws_cloudwatch_metric_alarm" "cache_cpu" {
  count               = "${var.enabled == "true" ? 1 : 0}"
  alarm_name          = "${local.name}-cpu-utilization"
  alarm_description   = "Redis cluster CPU utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = "300"
  statistic           = "Average"

  threshold = "${var.alarm_cpu_threshold_percent}"

  dimensions {
    CacheClusterId = "${local.name}"
  }

  alarm_actions = ["${var.alarm_actions}"]
  ok_actions    = ["${var.ok_actions}"]
  depends_on    = ["aws_elasticache_replication_group.default"]
}

resource "aws_cloudwatch_metric_alarm" "cache_memory" {
  count               = "${var.enabled == "true" ? 1 : 0}"
  alarm_name          = "${local.name}-freeable-memory"
  alarm_description   = "Redis cluster freeable memory"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "FreeableMemory"
  namespace           = "AWS/ElastiCache"
  period              = "60"
  statistic           = "Average"

  threshold = "${var.alarm_memory_threshold_bytes}"

  dimensions {
    CacheClusterId = "${local.name}"
  }

  alarm_actions = ["${var.alarm_actions}"]
  ok_actions    = ["${var.ok_actions}"]
  depends_on    = ["aws_elasticache_replication_group.default"]
}

locals {
  dns_enabled    = "${var.enabled == "true" && var.transit_encryption_enabled == "false" && length(var.zone_id) > 0 ? "true" : "false"}"
  ro_record_base = "${local.dns_enabled == "true" ? replace(element(concat(aws_elasticache_replication_group.default.*.primary_endpoint_address, list("")), 0), ".ng.", ".") : ""}"
}

module "dns" {
  source    = "git::https://github.com/cloudposse/terraform-aws-route53-cluster-hostname.git?ref=tags/0.2.1"
  enabled   = "${local.dns_enabled}"
  namespace = "${var.namespace}"
  name      = "${local.name}"
  stage     = "${var.stage}"
  ttl       = 60
  zone_id   = "${var.zone_id}"
  records   = ["${aws_elasticache_replication_group.default.*.primary_endpoint_address}"]
}

resource "aws_route53_record" "dns_ro" {
  count = "${local.dns_enabled == "true" ? var.cluster_size : 0}"

  zone_id = "${var.zone_id}"
  name    = "${local.name}-ro-${count.index + 1}"
  type    = "CNAME"
  ttl     = 60
  records = ["${replace(local.ro_record_base, local.replication_group_id, element(flatten(aws_elasticache_replication_group.default.*.member_clusters), count.index))}"]
}

module "dns_encrypt" {
  source    = "git::https://github.com/cloudposse/terraform-aws-route53-cluster-hostname.git?ref=tags/0.2.1"
  enabled   = "${var.enabled == "true" && var.transit_encryption_enabled == "true" && length(var.zone_id) > 0 ? "true" : "false"}"
  namespace = "${var.namespace}"
  name      = "${local.name}"
  stage     = "${var.stage}"
  ttl       = 60
  zone_id   = "${var.zone_id}"
  records   = ["${aws_elasticache_replication_group.encrypt.*.primary_endpoint_address}"]
}
