# Despliegue de MISP en VM con Podman (Opción A)

Automatización para levantar MISP en una única VM Linux usando **Podman rootless + systemd**,
derivada del `docker-compose.yml` del repositorio. systemd actúa como supervisor del stack
(no se necesita un demonio externo de vigilancia).

## Arquitectura

- Una VM Linux corre los 5 servicios del `docker-compose.yml` (db, redis, mail, misp-modules, misp-core; guard opcional).
- **Podman rootless** ejecuta los contenedores sin daemon root.
- **`restart: always`** (ya en el compose) recupera contenedores caídos.
- **systemd** (unit `misp.service`) arranca el stack al bootear y lo reinicia si falla.
- **Todos los datos persistentes viven bajo `MISP_DATA_DIR`** (por defecto `.` en local;
  `/opt/misp/data` en AWS, sobre un EBS dedicado).

```
VM Linux
 └─ systemd (misp.service)  ── supervisa ──►  podman-compose
                                               ├─ db (MariaDB)      [${MISP_DATA_DIR}/mysql]
                                               ├─ redis (Valkey)    [${MISP_DATA_DIR}/redis]
                                               ├─ mail (SMTP relay)
                                               ├─ misp-modules
                                               └─ misp-core (443)   [${MISP_DATA_DIR}/{configs,files,ssl,gnupg,logs}]
```

Para producción conviene poner **TLS/DNS delante vía ALB + ACM** (ver `deploy/terraform/`),
hidratar secretos desde **Secrets Manager** y respaldar a **S3**. Esta opción es el
despliegue mono-VM aislado.

## Requisitos

- VM Linux **Debian/Ubuntu** o **RHEL/Fedora**, con `sudo`.
- Salida a internet para descargar imágenes (GHCR + Docker Hub, o ECR).
- Recomendado: un usuario dedicado no-root para el stack.
- Para secretos/backups: `aws` CLI v2 y `jq` (el `provision.sh`/AMI los provee).

## Archivos

| Archivo | Qué hace |
|---|---|
| `provision.sh` | Prepara la VM: instala podman/podman-compose y aplica los 3 ajustes de Podman. |
| `deploy.sh` | Despliega/actualiza el stack (idempotente), con arranque escalonado. Crea el árbol de datos bajo `MISP_DATA_DIR`. |
| `secrets-bootstrap.sh` | Hidrata el `.env` desde AWS Secrets Manager (secreto JSON → `.env` con chmod 600). |
| `backup.sh` | Backup lógico a S3: `mysqldump` + tar de `files`/`configs`/`gnupg`. |
| `misp.service` | Unit systemd que hace de supervisor del stack. |
| `misp-backup.service` / `misp-backup.timer` | Ejecutan `backup.sh` diariamente. |

## Persistencia de datos (`MISP_DATA_DIR`)

Todos los datos persistentes son bind-mounts bajo una única ruta base, de modo que puedan
vivir en un disco dedicado (EBS) y respaldarse/snapshotearse como una unidad:

```
${MISP_DATA_DIR}/
├── mysql/     # MariaDB
├── redis/     # Valkey (cache)
├── files/     # adjuntos y archivos de MISP
├── configs/   # configuración de MISP
├── gnupg/     # llavero GPG
├── logs/      # logs de la app
└── ssl/       # certificados (si se sirve TLS en el contenedor)
```

- **Local:** `MISP_DATA_DIR=.` (los datos quedan bajo el directorio del repo). Comportamiento de desarrollo.
- **AWS:** `MISP_DATA_DIR=/opt/misp/data` (el EBS de datos montado por Terraform/user-data).
  Así los datos **sobreviven a un reemplazo de la EC2** y se respaldan como unidad.

## Ajustes de Podman incorporados

Detectados en pruebas de compatibilidad y aplicados automáticamente por `provision.sh`:

1. **Registros sin cualificar** — `unqualified-search-registries = ["docker.io"]` para que
   `mariadb:10.11` y `valkey/valkey:7.2` resuelvan.
2. **Puertos privilegiados en rootless** — `net.ipv4.ip_unprivileged_port_start=80` para que
   core pueda exponer 80/443 sin root.
3. **Permisos de bind-mounts** — en un filesystem Linux nativo (ext4/xfs) funcionan sin ajuste;
   `deploy.sh` crea el árbol de directorios.

## Uso end-to-end

```bash
# 1. Clonar el repo en la VM (como el usuario del stack)
git clone https://github.com/unoafp/uno-infra-misp.git ~/uno-infra-misp
cd ~/uno-infra-misp

# 2. Configuración base
cp template.env .env

# 3. Secretos: en AWS, hidratar desde Secrets Manager (usa el IAM role de la VM)
MISP_SECRET_ID=prod/misp/app ./deploy/podman/secrets-bootstrap.sh
#   (en local, editar el .env a mano)

# 4. Persistencia: en AWS, apuntar al EBS de datos
echo MISP_DATA_DIR=/opt/misp/data >> .env

# 5. Preparar la VM (una sola vez)
./deploy/podman/provision.sh

# 6. Desplegar el stack
./deploy/podman/deploy.sh
#   o con el proxy opcional:
#   ./deploy/podman/deploy.sh --with-guard

# 7. (Opcional) Gestionado por systemd para que arranque al boot
mkdir -p ~/.config/systemd/user
cp deploy/podman/misp.service ~/.config/systemd/user/misp.service
#   editar WorkingDirectory en el archivo si el repo no está en ~/uno-infra-misp
systemctl --user daemon-reload
systemctl --user enable --now misp.service

# 8. (Opcional) Backups diarios a S3
cp deploy/podman/misp-backup.{service,timer} ~/.config/systemd/user/
#   editar BACKUP_S3_BUCKET (y WorkingDirectory) en misp-backup.service
systemctl --user daemon-reload
systemctl --user enable --now misp-backup.timer
```

## Operación

```bash
# Estado
podman ps --format 'table {{.Names}}\t{{.Status}}'

# Logs de core (la primera inicialización tarda varios minutos)
podman logs -f uno-infra-misp_misp-core_1

# Verificar que MISP responde (desde la VM)
podman exec uno-infra-misp_misp-core_1 curl -ks -o /dev/null -w '%{http_code}\n' https://localhost/users/heartbeat

# Backup manual a S3
BACKUP_S3_BUCKET=mi-bucket ./deploy/podman/backup.sh

# Actualizar a nuevas imágenes (tras cambiar *_RUNNING_TAG en .env)
./deploy/podman/deploy.sh
```

## Backups y recuperación

Dos niveles complementarios:

1. **Snapshot de EBS** del volumen `/opt/misp/data` — recuperación completa y rápida de todos los datos.
2. **Backup lógico (`backup.sh`)** — `mysqldump` de la BD + tar de `files`/`configs`/`gnupg`, subido a S3.
   Permite recuperación granular (p. ej. solo la base). Redis/Valkey es caché y no se prioriza.

Restauración (resumen): descomprimir el dump al contenedor de MariaDB (`zcat db.sql.gz | podman exec -i <db> mysql ...`)
y extraer el tar sobre `MISP_DATA_DIR`. El propio `backup.sh` imprime los comandos exactos al terminar.

## Nota sobre systemd

`misp.service` mantiene el proceso en primer plano con `podman-compose ... logs -f`, de modo que
systemd supervisa ese proceso (no el estado individual de cada contenedor). Es suficiente porque
cada contenedor tiene `restart: always`. Para una integración más idiomática a futuro, se puede
migrar a **unidades systemd generadas por Podman/Quadlet** (una unidad por servicio). No se hizo
en esta versión por estar ya validada end-to-end.

## Notas

- **Primer arranque de core**: sincroniza datos, genera GPG y config; `/users/heartbeat`
  puede tardar varios minutos en devolver 200. Es normal.
- **Puertos**: por defecto 80/443. Para cambiarlos, usar `CORE_HTTP_PORT`/`CORE_HTTPS_PORT` en `.env`
  (y actualizar `BASE_URL`). Con ALB delante, el contenedor puede quedar solo en 443 interno.
- **Rootful vs rootless**: los scripts asumen rootless (más seguro). Para rootful, ver comentarios
  en `misp.service` y omitir `--user`.
