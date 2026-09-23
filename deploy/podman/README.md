# Despliegue de MISP en VM con Podman (Opción A)

Automatización para levantar MISP en una única VM Linux usando **Podman rootless + systemd**,
derivada del `docker-compose.yml` del repositorio. systemd actúa como supervisor del stack
(no se necesita un demonio externo de vigilancia).

## Arquitectura

- Una VM Linux corre los 5 servicios del `docker-compose.yml` (db, redis, mail, misp-modules, misp-core; guard opcional).
- **Podman rootless** ejecuta los contenedores sin daemon root.
- **`restart: always`** (ya en el compose) recupera contenedores caídos.
- **systemd** (unit `misp.service`) arranca el stack al bootear y lo reinicia si falla.

```
VM Linux
 └─ systemd (misp.service)  ── supervisa ──►  podman-compose
                                               ├─ db (MariaDB)      [volumen mysql_data]
                                               ├─ redis (Valkey)    [volumen cache_data]
                                               ├─ mail (SMTP relay)
                                               ├─ misp-modules
                                               └─ misp-core (80/443) [binds: configs, files, ssl, gnupg, logs]
```

Para producción real conviene externalizar db/redis a servicios gestionados y poner TLS/DNS
delante; esta opción es el despliegue mono-VM (piloto / entornos pequeños).

## Requisitos

- VM Linux **Debian/Ubuntu** o **RHEL/Fedora**, con `sudo`.
- Salida a internet para descargar imágenes (GHCR + Docker Hub).
- Recomendado: un usuario dedicado no-root para el stack.

## Archivos

| Archivo | Qué hace |
|---|---|
| `provision.sh` | Prepara la VM: instala podman/podman-compose y aplica los 3 ajustes de Podman. |
| `deploy.sh` | Despliega/actualiza el stack (idempotente), con arranque escalonado. |
| `misp.service` | Unit systemd que hace de supervisor del stack. |

## Ajustes de Podman incorporados

Detectados en pruebas de compatibilidad y aplicados automáticamente:

1. **Registros sin cualificar** — Podman no asume Docker Hub. `provision.sh` configura
   `unqualified-search-registries = ["docker.io"]` para que `mariadb:10.11` y `valkey/valkey:7.2` resuelvan.
2. **Puertos privilegiados en rootless** — `provision.sh` fija `net.ipv4.ip_unprivileged_port_start=80`
   para que core pueda exponer 80/443 sin root.
3. **Permisos de bind-mounts** — en un filesystem Linux nativo (ext4/xfs) funcionan sin ajuste
   (el "permission denied" solo ocurre bajo WSL sobre disco Windows). `deploy.sh` crea los directorios.

## Uso end-to-end

```bash
# 1. Clonar el repo en la VM (como el usuario del stack)
git clone https://github.com/unoafp/uno-infra-misp.git ~/uno-infra-misp
cd ~/uno-infra-misp

# 2. Configurar el entorno
cp template.env .env
#   editar .env: ADMIN_EMAIL, ADMIN_PASSWORD, GPG_PASSPHRASE, MYSQL_PASSWORD,
#   REDIS_PASSWORD, BASE_URL, y los *_RUNNING_TAG (imágenes oficiales) ya fijados.

# 3. Preparar la VM (una sola vez)
./deploy/podman/provision.sh

# 4. Desplegar el stack
./deploy/podman/deploy.sh
#   o con el proxy opcional:
#   ./deploy/podman/deploy.sh --with-guard

# 5. (Opcional) Dejarlo gestionado por systemd para que arranque al boot
mkdir -p ~/.config/systemd/user
cp deploy/podman/misp.service ~/.config/systemd/user/misp.service
#   editar WorkingDirectory en el archivo si el repo no está en ~/uno-infra-misp
systemctl --user daemon-reload
systemctl --user enable --now misp.service
```

## Operación

```bash
# Estado
podman ps --format 'table {{.Names}}\t{{.Status}}'

# Logs de core (la primera inicialización tarda varios minutos)
podman logs -f uno-infra-misp_misp-core_1

# Verificar que MISP responde (desde la VM)
podman exec uno-infra-misp_misp-core_1 curl -ks -o /dev/null -w '%{http_code}\n' https://localhost/users/heartbeat

# Actualizar a nuevas imágenes (tras cambiar *_RUNNING_TAG en .env)
./deploy/podman/deploy.sh

# Con systemd
systemctl --user status misp.service
systemctl --user restart misp.service
```

## Notas

- **Primer arranque de core**: sincroniza datos, genera GPG y config; `/users/heartbeat`
  puede tardar varios minutos en devolver 200. Es normal.
- **Backups**: respaldar el volumen `mysql_data` (MariaDB) y los directorios `configs/`, `gnupg/`, `ssl/`.
  En AWS, snapshot del disco EBS. Con Podman: `podman volume export`.
- **Puertos**: por defecto 80/443. Para cambiarlos, usar `CORE_HTTP_PORT`/`CORE_HTTPS_PORT` en `.env`
  (y actualizar `BASE_URL`).
- **Rootful vs rootless**: los scripts asumen rootless (más seguro). Para rootful, ver comentarios
  en `misp.service` y omitir `--user`.
