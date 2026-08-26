# uno-infra-misp

Repositorio destinado a mantener la configuración y los componentes necesarios para la construcción y despliegue de **MISP (Malware Information Sharing Platform)** mediante contenedores Docker.

## Descripción

El repositorio contiene la configuración base para ejecutar MISP mediante **Docker Compose**, incluyendo los Dockerfiles, scripts y variables necesarias para parametrizar el despliegue.

## Componentes

El despliegue contempla los siguientes servicios:

- **MISP Core:** aplicación principal de MISP y su interfaz web/API.
- **MISP Modules:** módulos de expansión, enriquecimiento, importación y exportación.
- **MariaDB:** base de datos utilizada por MISP.
- **Redis/Valkey:** servicio utilizado para caché y procesamiento interno.
- **SMTP:** relay de correo utilizado para las funcionalidades de notificación.

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
  
## Estado actual

La solución fue validada localmente mediante **Docker Compose**, utilizando un clon limpio del repositorio y `template.env` como base para generar la configuración del ambiente.

Se validó correctamente el funcionamiento de:

- MISP Core.
- MISP Modules.
- MariaDB.
- Redis/Valkey.
- Interfaz web de MISP mediante HTTPS.

El componente SMTP se encuentra incluido en el stack y queda pendiente de validación con el relay de correo que sea definido para el ambiente corporativo.

## Pendientes

La infraestructura definitiva y sus parámetros de despliegue se encuentran en proceso de definición.

Entre los principales puntos pendientes se encuentran la infraestructura de cómputo, DNS/FQDN, certificados TLS, persistencia y respaldos, conectividad, relay SMTP, gestión de secretos y mecanismo de build/deploy.
