# ==============================
# 1. Provider 版本区间（自动适配可用版本）
# ==============================
terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = ">= 1.200.0, < 1.250.0"  # 适配该区间内所有版本
    }
    null = {
      source  = "hashicorp/null"
      version = "3.2.4"
    }
  }
}

# ==============================
# 2. 阿里云 Provider 配置
# ==============================
provider "alicloud" {
  region = "cn-beijing"  # 与已有资源同地域
  # access_key = "你的AK"（无环境变量则取消注释）
  # secret_key = "你的SK"（无环境变量则取消注释）
}

# ==============================
# 3. 自动查询过滤条件（替换为你资源的实际信息）
# ==============================
variable "resource_filters" {
  type = object({
    vpc_name_regex = string    # VPC 名称正则
    sg_name_regex  = string    # 安全组名称正则
    resource_tags  = map(string)  # ECS 标签（无则删除）
  })
  default = {
    # ########## 替换为你资源的实际过滤条件 ##########
    vpc_name_regex = "test-vpc"  # 你的 VPC 名称（支持模糊匹配）
    sg_name_regex  = "test-sg"   # 你的安全组名称（支持模糊匹配）
    resource_tags  = { Env = "test" }  # ECS 标签（无则删除此行）
    # #############################################
  }
}

# ==============================
# 4. 自动查询已有资源（仅查询 ECS、VPC、安全组）
# ==============================
# 4.1 查询 VPC（获取 ECS 所属 VPC ID，用于跨网络绑定）
data "alicloud_vpcs" "existing" {
  name_regex = var.resource_filters.vpc_name_regex
}

# 4.2 查询 ECS（属于目标 VPC + 标签过滤，需 ≥2 台）
data "alicloud_instances" "existing" {
  vpc_id = data.alicloud_vpcs.existing.ids[0]
  tags   = lookup(var.resource_filters, "resource_tags", {})  # 无标签不报错
  count  = length(data.alicloud_vpcs.existing.ids) > 0 ? 1 : 0
}

# 4.3 查询安全组（属于目标 VPC + 名称过滤）
data "alicloud_security_groups" "existing" {
  vpc_id     = data.alicloud_vpcs.existing.ids[0]
  name_regex = var.resource_filters.sg_name_regex
}

# ==============================
# 5. 资源提取与校验
# ==============================
locals {
  vpc_id           = data.alicloud_vpcs.existing.ids[0]
  ecs_ids          = length(data.alicloud_instances.existing) > 0 ? [for ecs in data.alicloud_instances.existing[0].instances : ecs.id] : []
  security_group_id = data.alicloud_security_groups.existing.ids[0]

  # 校验条件
  vpc_exists       = length(local.vpc_id) > 0
  ecs_count_ok     = length(local.ecs_ids) >= 2
  sg_exists        = length(local.security_group_id) > 0
}

# 校验失败报错
resource "null_resource" "resource_validation" {
  count = (local.vpc_exists && local.ecs_count_ok && local.sg_exists) ? 0 : 1

  provisioner "local-exec" {
    command = <<EOT
      echo "错误：资源查询结果不满足要求！"
      echo "VPC 存在：${local.vpc_exists}"
      echo "ECS 数量（需≥2）：${length(local.ecs_ids)}"
      echo "安全组存在：${local.sg_exists}"
      exit 1
    EOT
  }
}

# ==============================
# 6. 经典网络 CLB（无 VPC/子网参数，低版本兼容）
# ==============================
resource "alicloud_slb_load_balancer" "public_clb" {
  depends_on = [null_resource.resource_validation]

  load_balancer_name = "public-clb-auto"
  address_type       = "internet"  # 公网类型
  internet_charge_type = "paybytraffic"  # 按流量计费
  # 移除 vpc_id、vswitch_ids、internet_bandwidth（低版本不支持）
}

# ==============================
# 7. CLB 监听（低版本兼容语法）
# ==============================
resource "alicloud_slb_listener" "http_80" {
  load_balancer_id = alicloud_slb_load_balancer.public_clb.id
  port             = 80
  protocol         = "http"
  backend_port     = 80
  scheduler        = "rr"  # 低版本支持 rr（轮询），不支持 round_robin

  # 简化健康检查（低版本支持的基础配置）
  health_check     = "on"
  healthy_http_code = "200"
}

# ==============================
# 8. 绑定 ECS 到 CLB（跨网络绑定，低版本兼容）
# ==============================
resource "alicloud_slb_backend_server" "ecs_attach" {
  count             = length(local.ecs_ids)
  load_balancer_id  = alicloud_slb_load_balancer.public_clb.id
  server_id         = local.ecs_ids[count.index]  # 低版本用 server_id，不用 backend_server_id
  vpc_id            = local.vpc_id  # 关键：跨网络绑定 VPC ECS
}

# ==============================
# 9. 安全组规则（放行 80 端口）
# ==============================
resource "alicloud_security_group_rule" "allow_public_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "internet"
  policy            = "accept"
  port_range        = "80/80"
  priority          = 4
  security_group_id = local.security_group_id
  cidr_ip           = "0.0.0.0/0"
}

resource "alicloud_security_group_rule" "allow_intranet_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "80/80"
  priority          = 5
  security_group_id = local.security_group_id
  cidr_ip           = "0.0.0.0/0"
}

# ==============================
# 10. 输出信息
# ==============================
output "auto_query_result" {
  value = {
    vpc_id           = local.vpc_id
    ecs_ids          = local.ecs_ids
    security_group_id = local.security_group_id
    description      = "自动查询到的资源 ID"
  }
}

output "public_clb_info" {
  value = {
    public_ip        = alicloud_slb_load_balancer.public_clb.address  # 公网访问 IP
    access_url       = "http://${alicloud_slb_load_balancer.public_clb.address}:80"
    bound_ecs_count  = length(local.ecs_ids)
  }
  description = "CLB 访问信息"
}
