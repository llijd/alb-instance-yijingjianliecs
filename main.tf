# ==============================
# 1. Terraform 版本与 Provider 约束
# ==============================
terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = ">= 1.200.0"
    }
  }
}

# ==============================
# 2. 阿里云 Provider 配置（需与已有资源同地域）
# ==============================
provider "alicloud" {
  region = "cn-beijing"  # 必须与已有 VPC/ECS 同地域
  # 认证方式：环境变量（推荐）或直接配置（不推荐硬编码）
  # access_key = "你的AK"
  # secret_key = "你的SK"
}

# ==============================
# 3. 引用已有资源（通过数据源查询或手动指定）
# ==============================

# 方式2：通过数据源自动查询已有资源（无需手动填 ID，需资源有明确标签）
# （如果不想手动填 ID，取消下方注释并配置标签过滤，需确保已有资源有对应标签）
data "alicloud_vpcs" "existing" {
  name_regex = "test-vpc"  # 按 VPC 名称过滤（替换为你的 VPC 名称）
 }
 
 data "alicloud_vswitches" "existing" {
   vpc_id     = data.alicloud_vpcs.existing.ids[0]
   tags = {
     Env = "test"  # 按标签过滤子网（替换为你的子网标签）
   }
 }
 
 data "alicloud_instances" "existing" {
   vpc_id     = data.alicloud_vpcs.existing.ids[0]
   tags = {
     Env = "test"  # 按标签过滤 ECS（替换为你的 ECS 标签）
   }
 }
 
# data "alicloud_security_groups" "existing" {
   vpc_id     = data.alicloud_vpcs.existing.ids[0]
   name_regex = "test-sg"  # 按安全组名称过滤（替换为你的安全组名称）
 }

# ==============================
# 4. 公网 ALB 实例配置（核心资源）
# ==============================
resource "alicloud_alb_load_balancer" "public_alb" {
  # ALB 名称（自定义）
  load_balancer_name = "public-alb-test"
  # 类型：应用型 ALB
  load_balancer_type = "Application"
  # 关联已有 VPC（使用手动指定的 ID 或自动查询的 ID）
  vpc_id             = data.alicloud_vpcs.existing.ids[0] # 手动指定：var.existing_resources.vpc_id；自动查询：data.alicloud_vpcs.existing.ids[0]
  # 网络类型：公网（关键！支持外部访问）
  address_type       = "Internet"
  # 公网计费模式：按流量计费（适合测试）
  internet_charge_type = "PayByTraffic"
  # 公网带宽峰值（按需调整，最小 1 Mbps）
  internet_bandwidth = 5

  # 绑定已有双子网（跨可用区，确保高可用）
  zone_mappings = [
    for idx, subnet_id in var.existing_resources.subnet_ids : {
      zone_id    = data.alicloud_vswitches.subnet_zone[idx].zone_id  # 自动获取子网所在可用区
      vswitch_id = subnet_id
    }
  ]

  tags = {
    Name = "public-alb-test"
    Env  = "test"
  }
}

# 辅助数据源：获取子网对应的可用区（ALB 绑定子网需指定可用区）
data "alicloud_vswitches" "subnet_zone" {
  count = length(var.existing_resources.subnet_ids)
  ids   = [var.existing_resources.subnet_ids[count.index]]
}

# ==============================
# 5. ALB 监听（80 端口 HTTP 协议）
# ==============================
resource "alicloud_alb_listener" "http_80" {
  load_balancer_id = alicloud_alb_load_balancer.public_alb.id
  listener_name    = "http-80-public"
  port             = 80
  protocol         = "HTTP"

  # 前端配置（HTTP 协议，无需证书）
  frontend_config = {
    protocol = "HTTP"
    port     = 80
  }

  # 默认转发到目标组
  default_actions = [
    {
      type             = "ForwardGroup"
      forward_group_id = alicloud_alb_forward_group.ecs_target.id
    }
  ]

  # 健康检查（检测 ECS 上的 Nginx 状态）
  health_check_config = {
    enabled             = true
    protocol            = "HTTP"
    port                = 80  # ECS 上 Nginx 监听端口
    path                = "/"  # 健康检查路径（Nginx 首页）
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 3
    interval            = 5
    healthy_http_codes  = "200-299"  # 健康状态码
  }

  # 会话保持（测试环境关闭，生产环境按需启用）
  session_sticky_config = {
    enabled = false
  }
}

# ==============================
# 6. 目标组（管理已有 ECS 实例）
# ==============================
resource "alicloud_alb_forward_group" "ecs_target" {
  forward_group_name = "ecs-target-group-public"
  load_balancer_id   = alicloud_alb_load_balancer.public_alb.id
  target_type        = "Instance"  # 目标类型：ECS 实例
  scheduler          = "RoundRobin"  # 轮询算法
}

# ==============================
# 7. 绑定已有 ECS 到目标组
# ==============================
resource "alicloud_alb_forward_group_attachment" "ecs_attach" {
  count              = length(var.existing_resources.ecs_ids)
  forward_group_id   = alicloud_alb_forward_group.ecs_target.id
  target_id          = var.existing_resources.ecs_ids[count.index]  # 绑定已有 ECS ID
  port               = 80  # ECS 上 Nginx 端口
  weight             = 100  # 权重（两台 ECS 相同）
  zone_id            = data.alicloud_instances.ecs_zone[count.index].zone_id  # 自动获取 ECS 所在可用区
}

# 辅助数据源：获取 ECS 对应的可用区
data "alicloud_instances" "ecs_zone" {
  count = length(var.existing_resources.ecs_ids)
  ids   = [var.existing_resources.ecs_ids[count.index]]
}

# ==============================
# 8. 安全组规则（放行公网 80 端口访问 ALB）
# ==============================
# 注意：已有安全组需放行 ALB 转发到 ECS 的流量（VPC 内网 80 端口）
# 以下规则是放行公网用户访问 ALB 的 80 端口（ALB 自身的安全组，自动创建）
# （ALB 会自动创建安全组，无需手动配置，仅需确保 ECS 安全组放行内网 80 端口）

# ==============================
# 9. 输出公网 ALB 访问信息
# ==============================
output "public_alb_info" {
  value = {
    alb_id           = alicloud_alb_load_balancer.public_alb.id
    alb_name         = alicloud_alb_load_balancer.public_alb.load_balancer_name
    public_ip        = alicloud_alb_load_balancer.public_alb.address  # 公网访问 IP
    access_url       = "http://${alicloud_alb_load_balancer.public_alb.address}:80"  # 公网访问地址
    listener_port    = alicloud_alb_listener.http_80.port
    bound_ecs_ids    = var.existing_resources.ecs_ids  # 已绑定的 ECS ID
    bandwidth        = alicloud_alb_load_balancer.public_alb.internet_bandwidth  # 公网带宽
  }
  description = "公网 ALB 配置信息及访问地址"
}
