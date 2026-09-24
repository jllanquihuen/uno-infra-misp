# Terraform — MISP host aislado (EC2 + Podman)

Terraform mínimo y **autocontenido** para levantar la VM que corre MISP como
sistema aislado (Opción A). Crea **solo** lo indispensable para un host único y
**reutiliza** la VPC/subnet existentes — no crea VPC, ALB, DNS ni nada compartido.

## Qué crea

- **EC2** Ubuntu 24.04 LTS (AMI de Canonical, resuelta dinámicamente).
- **Security group**: 443 entrante (y 80 opcional), todo saliente; SSH opcional.
- **IAM role + instance profile**: SSM Session Manager + pull de ECR (acotado) +
  lectura de Secrets Manager (acotada).
- **EBS**: volumen root gp3 cifrado + volumen de datos gp3 cifrado opcional
  (para datos persistentes de MISP: MariaDB, files, gnupg).
- **user-data**: instala prerequisitos, clona este repo y (si hay volumen de
  datos) lo formatea/monta en `/opt/misp/data`. **No** ejecuta el deploy de MISP.

Lo que **no** crea (a propósito, por ser un sistema aislado): VPC, subredes,
ALB, ACM, Route 53, ECR, Secrets Manager. Se asumen existentes o se gestionan
aparte.

## Requisitos

- Terraform >= 1.5 y AWS provider ~> 5.
- Credenciales AWS con permisos para EC2/IAM/EBS en la cuenta destino.
- Una VPC y subnet existentes (`vpc_id`, `subnet_id`).

## Uso

```bash
cd deploy/terraform
cp terraform.tfvars.example terraform.tfvars
# edita terraform.tfvars: vpc_id, subnet_id, allowed_https_cidrs, etc.

terraform init
terraform plan
terraform apply
```

### Conectarse al host (sin SSH, vía SSM)

```bash
# el comando exacto sale como output
aws ssm start-session --region <region> --target <instance_id>
```

### Desplegar MISP una vez dentro

El user-data deja el repo en `/opt/misp/uno-infra-misp`. Luego:

```bash
cd /opt/misp/uno-infra-misp
sudo ./deploy/podman/provision.sh     # una vez: podman, registries, puertos
cp template.env .env                   # configurar (o hidratar desde Secrets Manager)
./deploy/podman/deploy.sh              # levantar el stack
```

Ver la arquitectura completa en [`../podman/deploy.md`](../podman/deploy.md).

## Notas de seguridad

- **Acceso por SSM por defecto** (sin exponer SSH). Deja `enable_ssh = false`
  salvo que lo necesites; si lo activas, acota `ssh_ingress_cidrs` (nunca
  `0.0.0.0/0`).
- **Restringe `allowed_https_cidrs`** a rangos corporativos/VPN, o al CIDR del
  ALB/VPC si pones un ALB delante.
- **Acota `ecr_repository_arns` y `secrets_manager_arns`** en producción en vez
  de dejar `["*"]`.
- **IMDSv2 obligatorio** y **EBS cifrado** ya vienen activados.

## Variables principales

| Variable | Default | Descripción |
|---|---|---|
| `aws_region` | `us-east-1` | Región. |
| `vpc_id` / `subnet_id` | — (requeridas) | Red existente donde vive la instancia. |
| `assign_public_ip` | `false` | IP pública directa (usar subnet pública). |
| `instance_type` | `t3.xlarge` | 4 vCPU / 16 GB, acorde a lo validado. |
| `root_volume_size_gb` | `50` | Disco root (SO + imágenes). |
| `data_volume_size_gb` | `100` | Disco de datos (0 = deshabilita). |
| `enable_ssh` / `ssh_ingress_cidrs` | `false` / `[]` | SSH opcional acotado. |
| `allowed_https_cidrs` | `[]` | Orígenes permitidos a 443. |
| `enable_http` | `false` | Abrir 80 (redirect). |
| `ecr_repository_arns` | `["*"]` | Repos ECR permitidos (acotar en prod). |
| `secrets_manager_arns` | `["*"]` | Secretos permitidos (acotar en prod). |
