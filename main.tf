provider "alicloud" {
  region = "cn-beijing"
}

# 1. 获取已有 ECS 列表（按 VPC 或标签过滤）
data "alicloud_instances" "ecs_list" {
  vpc_id = "vpc-2zekt4tytvq1zinj3i2q3"  # 你的 VPC ID
  # tags = { "env" = "prod" } # 可选：按标签过滤
}

# 2. 获取 VSwitch 信息（用于 zone_mappings）
data "alicloud_vswitches" "vsw_list" {
  vpc_id = "vpc-2zekt4tytvq1zinj3i2q3"
}

# 3. 动态生成 ALB zone_mappings（去重）
locals {
  ecs_zones = distinct([
    for i in data.alicloud_instances.ecs_list.instances : {
      zone_id     = i.zone_id
      v_switch_id = lookup(
        { for vsw in data.alicloud_vswitches.vsw_list.vswitches : vsw.zone_id => vsw.id },
        i.zone_id,
        null
      )
    }
  ])
}

# 4. 创建 ALB 实例（自动匹配 ECS 所在区）
resource "alicloud_alb_load_balancer" "alb" {
  load_balancer_name    = "my-alb"
  address_type          = "Internet"
  load_balancer_edition = "Standard"
  vpc_id                = "vpc-2zekt4tytvq1zinj3i2q3"

  dynamic "zone_mappings" {
    for_each = local.ecs_zones
    content {
      zone_id     = zone_mappings.value.zone_id
      v_switch_id = zone_mappings.value.v_switch_id
    }
  }
}

# 5. 创建后端服务器组（直接在 servers 中绑定 ECS）
resource "alicloud_alb_server_group" "backend_group" {
  server_group_name = "ecs-backend-group"
  vpc_id            = "vpc-2zekt4tytvq1zinj3i2q3"
  protocol          = "HTTP"

  health_check_config {
    health_check_enabled  = true
    health_check_protocol = "HTTP"
    health_check_path     = "/"
  }

  dynamic "servers" {
    for_each = data.alicloud_instances.ecs_list.instances
    content {
      server_id   = servers.value.id
      server_type = "Ecs"
      port        = 80
      weight      = 100
    }
  }
}

# 6. 创建监听器
resource "alicloud_alb_listener" "http_listener" {
  listener_protocol = "HTTP"
  listener_port     = 80
  load_balancer_id  = alicloud_alb_load_balancer.alb.id

  default_actions {
    type = "ForwardGroup"
    forward_group_config {
      server_group_tuples {
        server_group_id = alicloud_alb_server_group.backend_group.id
      }
    }
  }
}
