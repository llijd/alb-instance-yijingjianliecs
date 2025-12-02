# ==============================
# 1. 固定稳定版 Provider（核心，避免兼容问题）
# ==============================
terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "1.280.0"  # 稳定版本，支持所有自动查询语法
    }
  }
}

# ==============================
# 2. 阿里云 Provider 配置
# ==============================
provider "alicloud" {
  region = "cn-beijing"  # 与已有资源同地域（必须正确！）
  # access_key = "你的AK"（无环境变量则取消注释填写）
  # secret_key = "你的SK"（无环境变量则取消注释填写）
}

# ==============================
# 3. 自动查询已有资源（按标签/名称过滤，零手动填 ID）
# ==============================
# 3.1 配置过滤条件（关键！替换为你资源的实际标签/名称）
variable "resource_filters" {
  type = object({
    vpc_name_regex = string    # VPC 名称正则（如 "test-vpc"）
    sg_name_regex  = string    # 安全组名称正则（如 "test-sg"）
    resource_tags  = map(string)  # 子网/ECS 的标签（如 {Env = "test"}）
  })
  default = {
    # ########## 替换为你资源的实际过滤条件 ##########
    vpc_name_regex = "test-vpc"  # 你的 VPC 名称（支持模糊匹配，如 "prod-*"）
    sg_name_regex  = "test-sg"   # 你的安全组名称（支持模糊匹配）
    resource_tags  = { Env = "test" }  # 你的子网/ECS 标签（无标签可删除此参数）
    # #############################################
  }
}

 #3.2 自动查询 VPC（按名称过滤）
data "alicloud_vpcs" "existing" {
  #name_regex = var.resource_filters.vpc_name_regex
}

# 3.3 自动查询子网（属于上述 VPC + 按标签过滤，确保双子网跨可用区）
data "alicloud_vswitches" "existing" {
  vpc_id = data.alicloud_vpcs.existing.ids[0]
  tags   = var.resource_filters.resource_tags  # 无标签则删除此行
  # 强制查询至少 2 个子网（跨可用区高可用）
  count  = length(data.alicloud_vpcs.existing.ids) > 0 ? 1 : 0
}

# 3.4 自动查询 ECS（属于上述 VPC + 按标签过滤，确保至少两台）
data "alicloud_instances" "existing" {
  vpc_id = data.alicloud_vpcs.existing.ids[0]
  tags   = var.resource_filters.resource_tags  # 无标签则删除此行
  count  = length(data.alicloud_vpcs.existing.ids) > 0 ? 1 : 0
}

# 3.5 自动查询安全组（属于上述 VPC + 按名称过滤）
data "alicloud_security_groups" "existing" {
  vpc_id     = data.alicloud_vpcs.existing.ids[0]
  name_regex = var.resource_filters.sg_name_regex
}

# ==============================
# 4. 资源合法性校验（避免查询结果不符合要求）
# ==============================
locals {
  # 提取查询结果（简化引用）
  vpc_id           = data.alicloud_vpcs.existing.ids[0]
  subnet_ids       = data.alicloud_vswitches.existing[0].ids
  ecs_ids          = [for ecs in data.alicloud_instances.existing[0].instances : ecs.id]
  security_group_id = data.alicloud_security_groups.existing.ids[0]

  # 校验条件
  vpc_exists       = length(local.vpc_id) > 0
  subnet_count_ok  = length(local.subnet_ids) >= 2
  ecs_count_ok     = length(local.ecs_ids) >= 2
  sg_exists        = length(local.security_group_id) > 0
}

# 若资源不满足要求，部署时直接报错（提前规避问题）
resource "null_resource" "resource_validation" {
  count = (local.vpc_exists && local.subnet_count_ok && local.ecs_count_ok && local.sg_exists) ? 0 : 1

  provisioner "local-exec" {
    command = <<EOT
      echo "错误：资源查询结果不满足要求！"
      echo "VPC 存在：${local.vpc_exists}"
      echo "子网数量（需≥2）：${length(local.subnet_ids)}"
      echo "ECS 数量（需≥2）：${length(local.ecs_ids)}"
      echo "安全组存在：${local.sg_exists}"
      exit 1
    EOT
  }
}

# ==============================
# 5. 公网 CLB 实例（VPC 内高可用）
# ==============================
resource "alicloud_slb_load_balancer" "public_clb" {
  # 依赖校验通过后再创建
  depends_on = [null_resource.resource_validation]

  load_balancer_name = "public-clb-auto"
  address_type       = "internet"  # 公网类型
  vpc_id             = local.vpc_id  # 自动关联查询到的 VPC
  vswitch_ids        = local.subnet_ids  # 自动绑定查询到的双子网
  internet_charge_type = "paybytraffic"  # 按流量计费
  internet_bandwidth = 5  # 公网带宽 5Mbps

  tags = {
    Name = "public-clb-auto"
    Env  = var.resource_filters.resource_tags.Env
  }
}

# ==============================
# 6. CLB 监听（80 端口 HTTP + 完整健康检查）
# ==============================
resource "alicloud_slb_listener" "http_80" {
  load_balancer_id = alicloud_slb_load_balancer.public_clb.id
  port             = 80
  protocol         = "http"
  backend_port     = 80  # 转发到 ECS 80 端口（Nginx）
  scheduler        = "round_robin"  # 轮询算法

  # 健康检查（自动检测 ECS 可用性）
  health_check {
    enabled             = true
    type                = "http"
    uri                 = "/"
    healthy_http_status = "http_2xx"
    interval            = 5
    timeout             = 3
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  sticky_session = "off"
}

# ==============================
# 7. 自动绑定所有查询到的 ECS 到 CLB
# ==============================
resource "alicloud_slb_backend_server" "ecs_attach" {
  count             = length(local.ecs_ids)
  load_balancer_id  = alicloud_slb_load_balancer.public_clb.id
  backend_server_id = local.ecs_ids[count.index]  # 自动获取 ECS ID
  weight            = 100
}

# ==============================
# 8. 自动添加安全组规则（放行 80 端口）
# ==============================
# 公网 80 端口（用户访问 CLB）
resource "alicloud_security_group_rule" "allow_public_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "internet"
  policy            = "accept"
  port_range        = "80/80"
  priority          = 4
  security_group_id = local.security_group_id  # 自动关联安全组
  cidr_ip           = "0.0.0.0/0"
}

# 内网 80 端口（CLB 访问 ECS）
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
# 9. 输出查询结果 + 公网访问信息
# ==============================
output "auto_query_result" {
  value = {
    vpc_id           = local.vpc_id
    subnet_ids       = local.subnet_ids
    ecs_ids          = local.ecs_ids
    security_group_id = local.security_group_id
    description      = "自动查询到的已有资源 ID"
  }
}

output "public_clb_info" {
  value = {
    clb_id           = alicloud_slb_load_balancer.public_clb.id
    public_ip        = alicloud_slb_load_balancer.public_clb.address  # 公网访问 IP
    access_url       = "http://${alicloud_slb_load_balancer.public_clb.address}:80"  # 直接访问
    bound_ecs_count  = length(local.ecs_ids)
    bandwidth        = alicloud_slb_load_balancer.public_clb.internet_bandwidth
  }
  description = "公网 CLB 配置信息及访问地址"
}
