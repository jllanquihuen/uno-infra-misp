# uno-infra-misp

Repositorio destinado a mantener la configuración y los componentes necesarios para la construcción y despliegue de **MISP (Malware Information Sharing Platform)** mediante contenedores.

## Descripción

El repositorio contiene la configuración base para ejecutar MISP mediante **Docker Compose**, incluyendo los Dockerfiles, scripts y variables necesarias para parametrizar el despliegue. Adicionalmente incorpora automatización de despliegue para un **host aislado en AWS** (VM EC2 con Podman rootless + systemd) y el **Terraform** mínimo para aprovisionar esa VM.

MISP se despliega aquí como un **sistema aislado y autocontenido**, con su propio ciclo de vida, independiente de otras plataformas.

## Componentes

El despliegue contempla los siguientes servicios:

- **MISP Core:** aplicación principal de MISP y su interfaz web/API.
- **MISP Modules:** módulos de expansión, enriquecimiento, importación y exportación.
- **MariaDB:** base de datos utilizada por MISP.
- **Redis/Valkey:** servicio utilizado para caché y procesamiento interno.
- **SMTP:** relay de correo utilizado para las funcionalidades de notificación.
- **MISP Guard** (opcional): componente de filtrado, activable por perfil de compose.

## Configuración

La configuración de los ambientes se realiza mediante variables de entorno.

El archivo `template.env` contiene la referencia de las variables disponibles para configurar componentes como:

- MISP.
- MariaDB.
- Redis/Valkey.
- SMTP.
- OIDC / Microsoft Entra ID.
- LDAP.
- Proxy y S3.
- Nginx y PHP.

> Los finales de línea de scripts, Dockerfiles y archivos de configuración de contenedor se fuerzan a LF vía `.gitattributes`. Esto evita que finales de línea Windows (CRLF) rompan la shell dentro de los contenedores Linux.

## Estado actual

La solución fue validada en tres escenarios, usando un clon limpio del repositorio y `template.env` como base:

1. **Docker Compose (local)** — arranque del stack completo con imágenes oficiales fijas.
2. **Podman rootless + `deploy.sh` (local)** — validado de punta a punta en un sistema de archivos Linux nativo.
3. **AWS end-to-end** — desplegado en una EC2 real con el Terraform de este repo: `terraform apply` → user-data (clona el repo) → `provision.sh` (instala Podman) → `deploy.sh` (levanta el stack) → MISP respondiendo por HTTPS y login desde el navegador.

Se validó correctamente el funcionamiento de:

- MISP Core (interfaz web por HTTPS respondiendo, login OK).
- MISP Modules.
- MariaDB.
- Redis/Valkey.
- Arranque escalonado y healthchecks de todos los servicios.
- Acceso por **AWS SSM Session Manager** (sin exponer SSH) en el despliegue AWS.

El componente SMTP se encuentra incluido en el stack y queda pendiente de validación con el relay de correo que sea definido para el ambiente corporativo.

### Selección de imagen: usar `*_RUNNING_TAG` (no `latest`)

Un punto crítico detectado durante la validación: la imagen `misp-core:latest` publicada puede venir **sin el bloque `nginx`** en la configuración de supervisor, dejando el contenedor `unhealthy` y sin servir por HTTPS.

- `CORE_TAG` / `MODULES_TAG` definen la versión con la que se **construye** la imagen.
- `CORE_RUNNING_TAG` / `MODULES_RUNNING_TAG` definen la versión con la que se **ejecuta** (el `pull`). Si quedan sin definir, el compose cae al default `latest`.

Para desplegar imágenes oficiales estables, fijar los `*_RUNNING_TAG` a versiones conocidas (p. ej. `CORE_RUNNING_TAG=v2.5.44`, `MODULES_RUNNING_TAG=v3.0.9`). El `template.env` trae esos valores por defecto.

## Despliegue

La automatización de despliegue vive en `deploy/`:

```
deploy/
├── podman/          # Ejecutar MISP dentro de la VM (Podman rootless + systemd)
│   ├── provision.sh   # Prepara la VM (una vez): podman, registries, puertos, linger
│   ├── deploy.sh      # Despliega/actualiza el stack (idempotente, arranque escalonado)
│   ├── misp.service   # Unit systemd: systemd como supervisor del stack
│   ├── deploy.md      # Arquitectura + diagramas + decisiones AWS
│   └── README.md      # Uso operativo de los scripts
└── terraform/       # Aprovisionar la VM aislada en AWS
    ├── main.tf, variables.tf, outputs.tf, providers.tf, versions.tf
    ├── user-data.sh.tpl        # Bootstrap de la instancia
    ├── terraform.tfvars.example
    └── README.md
```

### Flujo resumido (AWS, Opción A) — validado end-to-end

1. `terraform apply` en `deploy/terraform/` crea la EC2 (Ubuntu 24.04) reutilizando una VPC/subnet existentes, con IAM role (ECR pull + Secrets Manager read + SSM), EBS cifrado y acceso por SSM.
2. El **user-data** hace el bootstrap: instala prerequisitos y clona el repo en `/opt/misp/uno-infra-misp`.
3. En la VM: `deploy/podman/provision.sh` instala Podman y aplica los ajustes necesarios (una sola vez).
4. Se genera el `.env` (a futuro, hidratado desde Secrets Manager). Fijar los `*_RUNNING_TAG` (ver arriba).
5. `deploy/podman/deploy.sh` levanta el stack.
6. Acceso a la VM por `aws ssm start-session` (sin SSH); MISP por HTTPS en la IP/FQDN de la instancia.

La arquitectura completa, con diagramas del alcance de `deploy.sh` y del contexto AWS, está en [`deploy/podman/deploy.md`](deploy/podman/deploy.md).

## Aprovisionamiento de la VM: qué viene instalado y con qué permisos

La instancia se aprovisiona automáticamente (Terraform → `user-data` → `provision.sh`), sin
pasos manuales de instalación. Al terminar el arranque, la VM cuenta con:

**Software instalado**

| Componente | Quién lo instala | Notas |
|---|---|---|
| **Runtime de contenedores** | `provision.sh` | **Podman rootless + podman-compose**. Corre el mismo `docker-compose.yml`; sin daemon root (menor superficie de ataque). Ver nota Docker abajo. |
| **AWS CLI v2** | `user-data` | Para leer Secrets Manager y subir backups a S3 desde la propia VM. |
| **jq** | `user-data` | Parseo del secreto JSON en `secrets-bootstrap.sh`. |
| **git, curl, unzip, ca-certificates** | `user-data` | Clonado del repo y utilidades base. |
| **nvme-cli** | `user-data` | Detección robusta del volumen de datos EBS. |
| **NTP (`systemd-timesyncd`)** | `user-data` | Sincronización horaria (guía ANCI). |

**Permisos AWS (IAM role adjunto a la instancia, sin credenciales en disco)**

| Servicio | Acciones | Para qué |
|---|---|---|
| **Secrets Manager** | `GetSecretValue`, `DescribeSecret` | Hidratar el `.env` con `secrets-bootstrap.sh` (DB/Redis/GPG/SMTP…). |
| **S3** | lectura/escritura del bucket de backups | `backup.sh` sube dumps + archivos. |
| **ECR** | pull de imágenes | Descargar la imagen de `misp-core`/`modules` (cuando se use ECR). |
| **SSM** | Session Manager | Acceso a la VM sin exponer SSH. |

Los permisos de ECR y Secrets Manager son **acotables** a recursos concretos (repos y
`prod/misp/*`) en producción; ver `deploy/terraform/terraform.tfvars.example`.

> **Nota sobre Docker:** por seguridad, la solución usa **Podman rootless** en lugar de Docker
> (equivalente funcional para este stack, sin daemon privilegiado). Si por política se requiere
> **Docker específicamente**, el mismo `docker-compose.yml` es compatible y puede adaptarse el
> aprovisionamiento; es un punto a confirmar con el equipo.

## Dimensionamiento de la instancia

El tamaño se elige según el patrón de uso, no según el tráfico web: en MISP el consumo de
recursos proviene del **volumen de datos y de los feeds sincronizados**, no de los requests
de usuarios.

**Default: `t3.large` (2 vCPU / 8 GB, ~$60/mes).** Es el tamaño adecuado para el caso de uso
previsto: un MISP orientado a **cumplimiento/auditoría** que se sincroniza con el **MISP central
de la ANCI** (modelo centralizado hub-and-spoke) conectándose a **un único feed**. La carga es
baja y predecible, y 8 GB dan holgura. Supera el mínimo ANCI (4 GB / 2 vCPU), por lo que es
defendible ante auditoría.

**Cuándo subir a `t3.xlarge` (4 vCPU / 16 GB, recomendado ANCI):** si la ANCI comparte un
volumen grande de indicadores, si se habilitan múltiples feeds adicionales, o si la base de
datos crece de forma sostenida. Escalar es cambiar `instance_type` y aplicar Terraform; **los
datos viven en un EBS separado y sobreviven al redimensionamiento**.

> Con 8 GB, el `template.env` fija `INNODB_BUFFER_POOL_SIZE=1024M` para que MariaDB no
> compita por memoria con core/modules/redis. En un nodo de 16 GB puede subirse a `2048M`.
>
> Supuesto a confirmar con la ANCI (misp@anci.gob.cl): que el modelo sea solo sincronización
> con su MISP central y no requiera habilitar feeds adicionales.

## Cumplimiento de requisitos ANCI

Requisitos de la Agencia Nacional de Ciberseguridad (ANCI) para MISP vs. la configuración por defecto de este repo:

| Recurso | ANCI mínimo | ANCI recomendado | Default (`t3.large` + EBS) | Cumple |
|---|---|---|---|---|
| RAM | 4 GB | 16 GB | 8 GB | Sobre el mínimo (16 GB con `t3.xlarge`) |
| vCPU | 2 | 4 | 2 | Cumple mínimo (4 con `t3.xlarge`) |
| Almacenamiento | 150 GB | 200 GB | 50 (root) + 150 (datos) = 200 GB | Recomendado |

Otros puntos operativos que menciona la ANCI:

- **Zona horaria / NTP**: el `user-data` habilita `systemd-timesyncd` (NTP) en la VM; los contenedores usan `TZ` (UTC por defecto).
- **Proxy de salida**: soportado vía variables `PROXY_*` en el `.env` para redes con proxy obligatorio.
- **Ejecución privilegiada**: en lugar de correr MISP como `root` de forma nativa, aquí corre en contenedores **Podman rootless** (mismo objetivo funcional, menor superficie de ataque).

## Infraestructura objetivo (Opción A: VM aislada)

Decisiones tomadas para el ambiente AWS de unoafp:

| Punto | Decisión | Estado |
|---|---|---|
| **Cómputo** | EC2 Ubuntu 24.04 (Terraform validado en AWS real) | Definido y validado |
| **Aprovisionamiento** | Terraform (`deploy/terraform/`) + `provision.sh`/`deploy.sh` | Definido y validado |
| **Acceso a la VM** | AWS SSM Session Manager (SSH opcional) | Definido y validado |
| **Persistencia** | EBS dedicado montado en `/opt/misp/data` (`MISP_DATA_DIR`); todos los datos como bind-mounts | Implementado |
| **Gestión de secretos** | AWS Secrets Manager + IAM role + `secrets-bootstrap.sh` (hidrata el `.env`) | Implementado |
| **Certificados TLS** | ALB + ACM (Terraform opcional, `enable_alb`); SG del EC2 acepta 443 solo desde el SG del ALB | Implementado |
| **Respaldos** | Snapshot EBS + `backup.sh` (`mysqldump` + files/configs/gnupg → S3) con timer systemd | Implementado |
| **IAM** | Acotable a repos ECR y secretos concretos (`prod/misp/*`) | Implementado |
| **DNS / FQDN** | Nombre real por definir; apuntar Route 53 al DNS del ALB | Pendiente (definición) |
| **Relay SMTP** | SES o relay corporativo (variables `SES_*` / `SMARTHOST_*`) | Pendiente (definición) |
| **Build / deploy** | ECR + CodeBuild + `deploy.sh`/systemd | Propuesto |

## Pendientes

- **`buildspec.yml` de CodeBuild** — construir la imagen de `misp-core` en la nube (elimina el bloqueo de red intermitente de los builds locales) y publicarla en ECR. Es la única pieza de automatización que falta construir.
- **Definiciones de negocio** — FQDN/DNS definitivo, elección de relay SMTP (SES vs corporativo), y los valores concretos (ARN del certificado ACM, nombre del secreto en Secrets Manager, bucket de backups) para poblar el `terraform.tfvars` y el `.env`.
- **Mejora futura (no bloqueante)** — migrar `misp.service` a unidades systemd generadas por Podman/Quadlet (una por servicio) para que systemd supervise cada contenedor en vez del proceso de logs.
