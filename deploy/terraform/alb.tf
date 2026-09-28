# -----------------------------------------------------------------------------
# Optional ALB + ACM TLS termination (production pattern).
# Users -> Route53 -> ALB (HTTPS/ACM) -> EC2 (443). Created only when
# enable_alb = true. The instance SG accepts 443 only from the ALB SG.
# -----------------------------------------------------------------------------

# --- ALB security group ------------------------------------------------------
resource "aws_security_group" "alb" {
  count = var.enable_alb ? 1 : 0

  name        = "${local.name_prefix}-alb-sg"
  description = "MISP ALB: HTTPS in from allowed CIDRs, forward to instance."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${local.name_prefix}-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = var.enable_alb ? toset(var.alb_ingress_cidrs) : toset([])

  security_group_id = aws_security_group.alb[0].id
  description       = "ALB HTTPS"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_instance" {
  count = var.enable_alb ? 1 : 0

  security_group_id            = aws_security_group.alb[0].id
  description                  = "ALB to MISP instance on 443"
  referenced_security_group_id = aws_security_group.misp.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

# --- Load balancer -----------------------------------------------------------
resource "aws_lb" "misp" {
  count = var.enable_alb ? 1 : 0

  name               = "${local.name_prefix}-alb"
  internal           = var.alb_internal
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = var.alb_subnet_ids

  lifecycle {
    precondition {
      condition     = length(var.alb_subnet_ids) >= 2
      error_message = "enable_alb = true requires at least two subnets in alb_subnet_ids (different AZs)."
    }
    precondition {
      condition     = var.acm_certificate_arn != ""
      error_message = "enable_alb = true requires acm_certificate_arn to be set."
    }
  }

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

# --- Target group (HTTPS to the instance) ------------------------------------
resource "aws_lb_target_group" "misp" {
  count = var.enable_alb ? 1 : 0

  name        = "${local.name_prefix}-tg"
  port        = 443
  protocol    = "HTTPS"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    protocol            = "HTTPS"
    path                = "/users/heartbeat"
    matcher             = "200-399"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${local.name_prefix}-tg"
  }
}

resource "aws_lb_target_group_attachment" "misp" {
  count = var.enable_alb ? 1 : 0

  target_group_arn = aws_lb_target_group.misp[0].arn
  target_id        = aws_instance.misp.id
  port             = 443
}

# --- HTTPS listener (ACM) ----------------------------------------------------
resource "aws_lb_listener" "https" {
  count = var.enable_alb ? 1 : 0

  load_balancer_arn = aws_lb.misp[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.misp[0].arn
  }
}
