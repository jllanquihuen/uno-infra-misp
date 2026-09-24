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

La solución fue validada localmente de dos formas, usando un clon limpio del repositorio y `template.env` como base:

1. **Docker Compose** — arranque del stack completo con imágenes oficiales fijas.
2. **Podman rootless + `deploy.sh`** — validado de punta a punta en un sistema de archivos Linux nativo.

Se validó correctamente el funcionamiento de:

- MISP Core (interfaz web por HTTPS respondiendo, login OK).
- MISP Modules.
- MariaDB.
- Redis/Valkey.
- Arranque escalonado y healthchecks de todos los servicios.

El componente SMTP se encuentra incluido en el stack y queda pendiente de validación con el relay de correo que sea definido para el ambiente corporativo.

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

### Flujo resumido (AWS, Opción A)

1. `terraform apply` en `deploy/terraform/` crea la EC2 (Ubuntu 24.04) reutilizando una VPC/subnet existentes, con IAM role (ECR pull + Secrets Manager read + SSM), EBS cifrado y acceso por SSM.
2. En la VM: `deploy/podman/provision.sh` instala Podman y aplica los ajustes necesarios (una sola vez).
3. Se genera el `.env` (a futuro, hidratado desde Secrets Manager).
4. `deploy/podman/deploy.sh` levanta el stack.

La arquitectura completa, con diagramas del alcance de `deploy.sh` y del contexto AWS, está en [`deploy/podman/deploy.md`](deploy/podman/deploy.md).

## Infraestructura objetivo (Opción A: VM aislada)

Decisiones tomadas para el ambiente AWS de unoafp:

| Punto | Decisión | Estado |
|---|---|---|
| **Cómputo** | EC2 Ubuntu 24.04 (misma versión validada) | Definido |
| **Gestión de secretos** | AWS Secrets Manager + IAM role | Definido |
| **DNS / FQDN** | Nombre real por definir; `BASE_URL` parametrizable | Pendiente |
| **Certificados TLS** | ALB + ACM (propuesto; hoy autofirmado en local) | Por definir |
| **Persistencia / respaldos** | Volúmenes en EBS + `mariadb-dump` a S3 (propuesto) | Por definir |
| **Conectividad** | Entrada por ALB; salida por NAT; pull de ECR interno | Propuesto |
| **Relay SMTP** | SES o relay corporativo | Pendiente |
| **Build / deploy** | ECR + CodeBuild + `deploy.sh`/systemd | Propuesto |

## Pendientes

Piezas de la fase AWS que aún no están construidas:

- **`buildspec.yml` de CodeBuild** — construir la imagen de `misp-core` en la nube (elimina el bloqueo de red intermitente de los builds locales) y publicarla en ECR.
- **Hidratación del `.env` desde Secrets Manager** — script que, con el IAM role de la instancia, lee los secretos y genera el `.env` sin exponer valores en texto plano.
- **Definiciones abiertas** — FQDN/DNS, estrategia final de TLS, relay SMTP y política de respaldos.
