# uno-infra-misp

Repositorio destinado a la definición, construcción y automatización de la infraestructura para el despliegue de **MISP (Malware Information Sharing Platform)** en contenedores.

## Objetivo

Definir la infraestructura necesaria para desplegar MISP, evaluando las alternativas disponibles desde el punto de vista técnico y de costos antes de establecer la arquitectura definitiva.

El trabajo contempla:

1. Evaluar alternativas para el despliegue de MISP en contenedores.
2. Revisar los costos de operación y cómputo de las alternativas evaluadas.
3. Definir la arquitectura de despliegue.
4. Construir la infraestructura mediante **Infraestructura como Código (IaC)**.
5. Automatizar el despliegue de la plataforma.

## Alternativas de despliegue

La arquitectura definitiva se encuentra **por definir**.

Inicialmente se consideran para evaluación las siguientes alternativas:

### Docker Compose sobre EC2

Despliegue de MISP mediante contenedores utilizando **Docker Compose sobre Amazon EC2**.

### Kubernetes

Despliegue de MISP mediante contenedores sobre un **clúster Kubernetes (K8s)**.

La selección de la alternativa deberá considerar principalmente los **costos de operación y cómputo**.

Como parte de la evaluación técnica también se recomienda considerar aspectos como:

* Complejidad operacional.
* Mantenibilidad.
* Disponibilidad.
* Escalabilidad.
* Administración y monitoreo de la plataforma.

> **Nota:** Estos puntos corresponden a criterios sugeridos para la evaluación y no representan decisiones de arquitectura.

## Infraestructura como Código

La infraestructura requerida para MISP será construida mediante **Infraestructura como Código (IaC)**.

La herramienta, estructura y componentes específicos se encuentran **por definir**.

Como alternativas técnicas se podrán evaluar herramientas compatibles con la infraestructura seleccionada, por ejemplo:

* **Terraform**.
* Otras herramientas de IaC disponibles o definidas por los estándares de infraestructura de la organización.

> **Nota:** Las tecnologías mencionadas son alternativas de evaluación y no representan una decisión definitiva.

## Automatización de despliegue

Se contempla automatizar el despliegue de la infraestructura y de MISP.

La herramienta y el flujo de automatización se encuentran **por definir**.

Dependiendo de la arquitectura seleccionada, se podrán evaluar mecanismos de CI/CD y automatización compatibles con las herramientas y estándares utilizados por la organización.

## Estructura del repositorio

La estructura definitiva del repositorio se encuentra **por definir** y dependerá de la arquitectura y tecnologías seleccionadas.

Como referencia, se podrán considerar directorios separados para:

* Infraestructura como Código.
* Configuración de contenedores.
* Automatización de despliegue.
* Documentación técnica.

La estructura será actualizada una vez definida la arquitectura objetivo.

## Seguridad

Los controles y mecanismos específicos de seguridad asociados al despliegue se encuentran **por definir** y deberán alinearse con los estándares de seguridad de la organización.

Como buenas prácticas para el manejo del repositorio se recomienda:

* No almacenar credenciales, contraseñas, API Keys, tokens o certificados privados directamente en el repositorio.
* Mantener los secretos fuera del control de versiones.
* Utilizar mecanismos seguros para proporcionar secretos y credenciales durante los procesos de despliegue.
* Revisar que archivos de configuración locales o sensibles sean excluidos mediante `.gitignore` cuando corresponda.
* Aplicar el principio de mínimo privilegio a los accesos utilizados por la infraestructura y los procesos de automatización.

> **Nota:** Estas medidas corresponden a buenas prácticas generales. Los controles definitivos deberán definirse de acuerdo con la arquitectura seleccionada y los estándares de seguridad aplicables.

## Estado

**En evaluación y diseño.**

### Confirmado

* MISP será desplegado mediante contenedores.
* Se evaluarán los costos de operación y cómputo.
* La infraestructura será construida como código.
* El despliegue será automatizado.

### Por definir

* Arquitectura definitiva de despliegue.
* Docker Compose sobre EC2 o Kubernetes.
* Herramienta de Infraestructura como Código.
* Recursos de infraestructura requeridos.
* Herramienta y flujo de automatización del despliegue.
* Estructura definitiva del repositorio.
* Configuración de los componentes de MISP.
* Controles y mecanismos específicos de seguridad.

## Próximos pasos

1. Evaluar los costos de **Docker Compose sobre EC2**.
2. Evaluar los costos asociados a una alternativa basada en **Kubernetes**.
3. Comparar las alternativas.
4. Definir la arquitectura a implementar.
5. Definir la herramienta de IaC.
6. Construir la infraestructura como código.
7. Definir e implementar la automatización del despliegue.
8. Documentar la arquitectura y configuración definitiva.
