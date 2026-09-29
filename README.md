# Proyecto de Base de Datos para un E-commerce

## Descripción breve
Base de datos relacional en **MySQL 8.0.19+** para una tienda en línea. Gestiona productos, categorías jerárquicas, proveedores, clientes, ventas y su detalle (con el **precio congelado** al momento de la compra), e incluye 20 consultas analíticas, 20 funciones, un esquema de seguridad con roles y usuarios, 20 triggers (más 5 complementarios), 20 eventos programados y 20 procedimientos almacenados.

## Integrantes
- _Nombre completo del integrante 1_
- _Nombre completo del integrante 2_
- _Nombre completo del integrante 3_

> Repositorio privado: `Proyecto_BD_Avanzada_[NombreEquipo]` (recuerde invitar al trainer como colaborador).

## Instrucciones de ejecución
Requisitos: MySQL 8.0.19 o superior y un usuario administrador (por ejemplo `root`). Ejecute los archivos **en este orden**:

```bash
mysql -u root -p < 01_Esquema_y_Datos.sql            # crea ecommerce_db, tablas y datos de ejemplo (recrea la BD desde cero)
mysql -u root -p < 02_Consultas_Avanzadas.sql        # 20 consultas de análisis
mysql -u root -p < 03_Funciones.sql                  # 20 funciones (UDF)
mysql -u root -p < 04_Seguridad.sql                  # roles, usuarios y permisos
mysql -u root -p < 05_Triggers.sql                   # tablas de auditoría + triggers
mysql -u root -p < 06_Eventos.sql                    # tablas de reporte + eventos (activa event_scheduler)
mysql -u root -p < 07_Procedimientos_Almacenados.sql # 20 procedimientos
```

También puede abrir cada archivo en MySQL Workbench y ejecutarlo completo (rayo con el icono "Execute script").

## Contenido de cada archivo
| Archivo | Contenido |
|---|---|
| `01_Esquema_y_Datos.sql` | `CREATE TABLE` (incluye tablas de apoyo: carritos, visitas, promociones, reseñas, pagos, devoluciones, sucursales) e `INSERT` de datos de ejemplo (45 clientes, 30 productos, 174 ventas, 340 líneas de detalle, 2024-2026). |
| `02_Consultas_Avanzadas.sql` | 20 consultas, cada una precedida por un comentario con la pregunta de negocio. |
| `03_Funciones.sql` | 20 sentencias `CREATE FUNCTION`. |
| `04_Seguridad.sql` | Roles, usuarios, `GRANT`/`REVOKE`, vistas seguras y políticas de contraseñas. |
| `05_Triggers.sql` | Tablas de auditoría (`log_cambios_precio`, etc.) y los triggers. |
| `06_Eventos.sql` | Tabla `reporte_ventas_semanales` (y demás tablas de resumen), `SET GLOBAL event_scheduler = ON` y los 20 `CREATE EVENT`. |
| `07_Procedimientos_Almacenados.sql` | 20 sentencias `CREATE PROCEDURE`. |

## Decisiones de diseño y notas
- **Campos adicionales** requeridos por consultas/triggers del enunciado: `productos.stock_minimo`, `peso_kg`, `ubicacion`, `fecha_modificacion`, `fecha_eliminacion`; `clientes.ciudad`, `region`, `fecha_nacimiento`, `total_gastado`, `fecha_ultimo_pedido`, `nivel_lealtad`, `referido_por`; `ventas.id_sucursal`, `direccion_envio`; `categorias.id_categoria_padre`, `total_productos`.
- **Estado de la venta**: `Pendiente de Pago`, `Pagado`, `Procesando`, `Enviado`, `Entregado`, `Cancelado` (se agregó `Pagado` porque `sp_ProcesarPago` lo requiere). Las ventas canceladas no cuentan como ingreso.
- **Nombres sin "ñ"**: `contrasena`, `fn_ValidarComplejidadContrasena` y `sp_AnadirResenaProducto` para evitar problemas de codificación.
- **Triggers**: MySQL solo admite un evento por trigger, por eso hay 5 triggers complementarios (marcados con `[+]`) para cubrir INSERT/UPDATE/DELETE en el recálculo del total, el contador por categoría y la validación de email. `trg_log_permission_changes` audita la tabla de aplicación `asignacion_roles` porque MySQL no permite triggers sobre `mysql.*`.
- **Tabla `log_cambios_precio`**: se crea en `01` (para poder conceder `SELECT` en `04`) y se declara de nuevo con `IF NOT EXISTS` en `05`, como pide el enunciado.
- **Seguridad**:
  - Los `GRANT EXECUTE` sobre procedimientos del script `04` apuntan a rutinas que se crean en `07`. Si su servidor rechaza conceder permisos sobre rutinas inexistentes, ejecute esas 4 líneas (sección "12") después del script `07`.
  - El filtro por sucursal se implementa con las vistas `v_ventas_sucursal` y `v_detalle_ventas_sucursal` y la tabla `usuario_sucursal` (MySQL no tiene seguridad por fila nativa).
  - La auditoría de inicios de sesión fallidos usa el log de errores (`log_error_verbosity=3`), Performance Schema y el bloqueo por `FAILED_LOGIN_ATTEMPTS`. Con MySQL Enterprise puede usarse `audit_log`.
  - Las contraseñas de los usuarios son de ejemplo; cámbielas en un entorno real.
- **Eventos**: MySQL no tiene vistas materializadas ni backup nativo desde SQL; se emulan con tablas (`mv_ventas_por_categoria`, `*_bkp`).
- **Usuarios de prueba** (host `localhost`): `admin_user`, `marketing_user`, `inventory_user`, `support_user`, y adicionalmente `analyst_user`, `auditor_user`, `visitor_user`.

## Pruebas rápidas
```sql
USE ecommerce_db;
CALL sp_RealizarNuevaVenta(1, 1, '[{"id_producto":1,"cantidad":1},{"id_producto":4,"cantidad":2}]', @id_venta);
SELECT @id_venta, fn_CalcularTotalVenta(@id_venta);
CALL sp_ProcesarPago(@id_venta, 'PSE');
CALL sp_CambiarEstadoPedido(@id_venta, 'Procesando');
SELECT * FROM log_estado_pedido ORDER BY id_log DESC LIMIT 3;
UPDATE productos SET precio = 950 WHERE id_producto = 1;  SELECT * FROM log_cambios_precio;
SHOW EVENTS FROM ecommerce_db;
```
